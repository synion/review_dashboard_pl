require "test_helper"

class GithubInboxTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  # Fake GithubClient: oddaje przygotowane wyniki `gh search` i szczegóły PR-ów,
  # zapisując o co pytaliśmy (liczba zapytań o szczegóły jest częścią kontraktu).
  class FakeGithub
    attr_reader :searches, :activity_calls, :body_calls

    def initialize(requested: [], reviewed: [], activity: {}, bodies: {}, raise_on: nil)
      @requested = requested
      @reviewed = reviewed
      @activity = activity
      @raise_on = raise_on
      @bodies = bodies
      @searches = []
      @activity_calls = []
      @body_calls = []
    end

    def pr_body(pr_url, repo_dir:)
      @body_calls << pr_url
      raise GithubClient::Error, "PR zniknął" if @raise_on == pr_url

      @bodies[pr_url]
    end

    def search_prs(repo:, role:, repo_dir:, limit: 40)
      @searches << { repo: repo, role: role }
      raise GithubClient::Error, "gh padł" if @raise_on == role

      role == "review-requested" ? @requested : @reviewed
    end

    def pr_activity(pr_url, repo_dir:)
      @activity_calls << pr_url
      raise GithubClient::Error, "PR zniknął" if @raise_on == pr_url

      @activity.fetch(pr_url)
    end
  end

  def pr(number, author:, title: "PR #{number}", updated_at: "2026-07-30T08:00:00Z")
    { "number" => number, "title" => title, "author" => { "login" => author },
      "updatedAt" => updated_at, "url" => "https://github.com/acme/webapp/pull/#{number}" }
  end

  def review_event(login, at) = { "author" => { "login" => login }, "submittedAt" => at, "state" => "COMMENTED" }
  def comment_event(login, at) = { "author" => { "login" => login }, "createdAt" => at }

  setup do
    @project = projects(:webapp)
    @project.update_columns(repo_url: "https://github.com/acme/webapp",
                            task_url_prefix: "https://tracker.example.com/organize/tasks/")
  end

  def refresh(github) = GithubInbox.new(github: github, login: "ja").refresh(@project)

  test "should queue PRs where GitHub asks for my review" do
    refresh(FakeGithub.new(requested: [ pr(10, author: "kolega") ]))

    item = @project.inbox_items.sole
    assert_equal [ 10, "requested", "kolega" ], [ item.pr_number, item.reason, item.author ]
    assert_equal Time.utc(2026, 7, 30, 8), item.signal_at
  end

  # Sedno zmiany semantyki: to jest dashboard do recenzowania CUDZEGO kodu.
  test "should never queue my own pull requests" do
    refresh(FakeGithub.new(requested: [ pr(11, author: "ja") ], reviewed: [ pr(12, author: "ja") ]))

    assert_empty @project.inbox_items
  end

  test "should queue a reviewed PR only when someone else spoke after my review" do
    github = FakeGithub.new(reviewed: [ pr(20, author: "kolega"), pr(21, author: "kolega") ], activity: {
      "https://github.com/acme/webapp/pull/20" => {
        "reviews" => [ review_event("ja", "2026-07-28T10:00:00Z") ],
        "comments" => [ comment_event("kolega", "2026-07-29T11:00:00Z") ]
      },
      # Po moim review odezwałem się tylko ja — piłka została u autora.
      "https://github.com/acme/webapp/pull/21" => {
        "reviews" => [ review_event("ja", "2026-07-28T10:00:00Z") ],
        "comments" => [ comment_event("ja", "2026-07-29T12:00:00Z") ]
      }
    })

    refresh(github)

    item = @project.inbox_items.sole
    assert_equal [ 20, "commented", "kolega" ], [ item.pr_number, item.reason, item.actor ]
    assert_equal Time.utc(2026, 7, 29, 11), item.signal_at, "sygnałem jest cudzy ruch, nie updatedAt PR-a"
  end

  test "should skip a reviewed PR when nobody commented at all" do
    github = FakeGithub.new(reviewed: [ pr(22, author: "kolega") ], activity: {
      "https://github.com/acme/webapp/pull/22" => {
        "reviews" => [ review_event("ja", "2026-07-28T10:00:00Z") ], "comments" => []
      }
    })

    refresh(github)

    assert_empty @project.inbox_items
  end

  # Prośba o review niesie mocniejszy sygnał niż komentarz, a dublet w kolejce
  # wyglądałby jak dwie różne rzeczy do zrobienia.
  test "should keep one entry per PR and prefer the review request" do
    github = FakeGithub.new(requested: [ pr(30, author: "kolega") ], reviewed: [ pr(30, author: "kolega") ])

    refresh(github)

    assert_equal [ "requested" ], @project.inbox_items.map(&:reason)
    assert_empty github.activity_calls, "PR z prośbą o review nie potrzebuje dopytywania o komentarze"
  end

  # Konwencja zespołu: zadanie jest podlinkowane w opisie PR-a, więc kafel może
  # od razu prowadzić do formularza z wypełnionym linkiem.
  test "should carry the task link from the PR description" do
    url = "https://github.com/acme/webapp/pull/33"
    github = FakeGithub.new(requested: [ pr(33, author: "kolega") ],
                            bodies: { url => "Zadanie: https://tracker.example.com/organize/tasks/32586\n\nOpis" })

    refresh(github)

    assert_equal "https://tracker.example.com/organize/tasks/32586", @project.inbox_items.sole.task_url
    assert_equal [ url ], github.body_calls
  end

  test "should not ask for PR descriptions when the project has no tracker prefix" do
    @project.update_columns(task_url_prefix: nil)
    github = FakeGithub.new(requested: [ pr(34, author: "kolega") ])

    refresh(github)

    assert_nil @project.inbox_items.sole.task_url
    assert_empty github.body_calls, "bez prefiksu nie ma z opisu czego wyciągać"
  end

  test "should reuse the activity call for the description of a commented PR" do
    url = "https://github.com/acme/webapp/pull/35"
    github = FakeGithub.new(reviewed: [ pr(35, author: "kolega") ], activity: {
      url => { "reviews" => [ review_event("ja", "2026-07-28T10:00:00Z") ],
               "comments" => [ comment_event("kolega", "2026-07-29T10:00:00Z") ],
               "body" => "Fix do [#999](https://tracker.example.com/organize/tasks/999)" }
    })

    refresh(github)

    assert_equal "https://tracker.example.com/organize/tasks/999", @project.inbox_items.sole.task_url
    assert_empty github.body_calls, "opis przyszedł razem z aktywnością"
  end

  test "should replace the whole queue on refresh so handled PRs disappear" do
    refresh(FakeGithub.new(requested: [ pr(40, author: "kolega"), pr(41, author: "kolega") ]))
    assert_equal [ 40, 41 ], @project.inbox_items.order(:pr_number).map(&:pr_number)

    refresh(FakeGithub.new(requested: [ pr(41, author: "kolega") ]))

    assert_equal [ 41 ], @project.inbox_items.map(&:pr_number)
  end

  # Kolejkę przepisuje delete_all + upserty, więc callbacki InboxItem nie zobaczyłyby
  # usunięć — bez tego broadcastu PR obsłużony na GitHubie znikałby z kafli dopiero
  # po F5.
  test "should refresh the dashboard queues after rewriting the inbox" do
    assert_enqueued_with job: BroadcastDashboardJob do
      refresh(FakeGithub.new(requested: [ pr(45, author: "kolega") ]))
    end
  end

  test "should stamp the check time so the page knows how fresh the queue is" do
    assert_nil @project.inbox_checked_at
    refresh(FakeGithub.new(requested: [ pr(50, author: "kolega") ]))
    assert @project.reload.inbox_checked_at.present?
  end

  test "should do nothing for a project without a GitHub repo url" do
    @project.update_columns(repo_url: nil)
    github = FakeGithub.new(requested: [ pr(60, author: "kolega") ])

    assert_nil refresh(github)
    assert_empty github.searches
  end

  # Padnięty gh nie może kasować kolejki ani wywalać strony — to jedyne miejsce,
  # gdzie widać, że ktoś czeka na moje review.
  test "should keep the previous queue when a GitHub search fails" do
    refresh(FakeGithub.new(requested: [ pr(70, author: "kolega") ]))

    refresh(FakeGithub.new(raise_on: "review-requested"))

    assert_equal [ 70 ], @project.inbox_items.map(&:pr_number)
  end

  test "should survive one unreadable PR among many" do
    github = FakeGithub.new(reviewed: [ pr(80, author: "kolega"), pr(81, author: "kolega") ], activity: {
      "https://github.com/acme/webapp/pull/81" => {
        "reviews" => [ review_event("ja", "2026-07-28T10:00:00Z") ],
        "comments" => [ comment_event("kolega", "2026-07-29T10:00:00Z") ]
      }
    }, raise_on: "https://github.com/acme/webapp/pull/80")

    refresh(github)

    assert_equal [ 81 ], @project.inbox_items.map(&:pr_number)
  end
end
