require "test_helper"

class CheckReviewRequestJobTest < ActiveSupport::TestCase
  class FakeGithub
    attr_reader :calls

    def initialize(response = nil, error: nil, login: "synion")
      @response = response
      @error = error
      @login = login
      @calls = []
    end

    def viewer_login(repo_dir:) = @login

    def pr_review_state(pr_url, repo_dir:)
      @calls << { pr_url: pr_url, repo_dir: repo_dir }
      raise @error if @error

      @response
    end
  end

  setup do
    @review = reviews(:pr_review)
    @review.update!(status: "decided", decision: "comment")
  end

  test "re-request na otwartym PR przestawia na waiting_review" do
    github = FakeGithub.new({ "reviewRequests" => [ { "login" => "synion" } ], "state" => "OPEN" })
    CheckReviewRequestJob.perform_now(@review, github: github)
    assert_equal "waiting_review", @review.reload.status
    assert_not_nil @review.github_checked_at
  end

  test "brak loginu na liście nie zmienia statusu, ale zapisuje sprawdzenie" do
    github = FakeGithub.new({ "reviewRequests" => [ { "login" => "ktos_inny" } ], "state" => "OPEN" })
    CheckReviewRequestJob.perform_now(@review, github: github)
    assert_equal "decided", @review.reload.status
    assert_not_nil @review.github_checked_at
  end

  # Zmergowany PR wygrywa nad re-requestem: skoro wjechał, prośba o poprawki
  # jest już nieaktualna, a review nie ma czego sprawdzać.
  test "zmergowany PR kończy review na stałe mimo re-requesta" do
    github = FakeGithub.new({ "reviewRequests" => [ { "login" => "synion" } ], "state" => "MERGED" })
    CheckReviewRequestJob.perform_now(@review, github: github)
    assert_equal "merged", @review.reload.status
  end

  test "PR zamknięty bez merge'a kończy review na stałe" do
    github = FakeGithub.new({ "reviewRequests" => [], "state" => "CLOSED" })
    CheckReviewRequestJob.perform_now(@review, github: github)
    assert_equal "closed", @review.reload.status
  end

  # Bez tego review, którego PR wjechał już po prośbie o poprawki, wisiałby
  # w „czeka ponowne review" bez żadnego sposobu, by samo zgasło.
  test "review w waiting_review też wypada z gry, gdy PR wjedzie" do
    @review.update!(status: "waiting_review")
    github = FakeGithub.new({ "reviewRequests" => [ { "login" => "synion" } ], "state" => "MERGED" })
    CheckReviewRequestJob.perform_now(@review, github: github)
    assert_equal "merged", @review.reload.status
  end

  test "waiting_review na otwartym PR zostaje bez zmian, tylko ze stemplem" do
    @review.update!(status: "waiting_review")
    github = FakeGithub.new({ "reviewRequests" => [ { "login" => "synion" } ], "state" => "OPEN" })
    CheckReviewRequestJob.perform_now(@review, github: github)
    assert_equal "waiting_review", @review.reload.status
    assert_not_nil @review.github_checked_at
  end

  # Najczęstszy przypadek w praktyce: autor merguje, zanim zdążę wysłać decyzję.
  # Bez tego review zostaje na „Review zakończony / wyślij decyzję" na zawsze,
  # bo nikt już nie pyta GitHuba o ten PR.
  test "review bez wysłanej decyzji też gaśnie, gdy PR wjedzie" do
    @review.update!(status: "reviewed", decision: nil)
    github = FakeGithub.new({ "reviewRequests" => [], "state" => "MERGED" })
    CheckReviewRequestJob.perform_now(@review, github: github)
    assert_equal "merged", @review.reload.status
  end

  # Prośba o ponowne review dotyczy tylko review PO decyzji — na „reviewed" własne
  # nazwisko na liście reviewRequests to zwykłe „ktoś mnie poprosił", czyli stan
  # wyjściowy, a nie sygnał do followupu.
  test "reviewed na otwartym PR zostaje reviewed, mimo prośby o review" do
    @review.update!(status: "reviewed", decision: nil)
    github = FakeGithub.new({ "reviewRequests" => [ { "login" => "synion" } ], "state" => "OPEN" })
    CheckReviewRequestJob.perform_now(@review, github: github)
    assert_equal "reviewed", @review.reload.status
    assert_not_nil @review.github_checked_at
  end

  # Zmergowanego PR-a nie ma po co review'ować ani ponawiać po padniętej sesji.
  test "ready i failed z zmergowanym PR-em też kończą się na merged" do
    %w[ready failed].each do |status|
      @review.update!(status: status)
      github = FakeGithub.new({ "reviewRequests" => [], "state" => "MERGED" })
      CheckReviewRequestJob.perform_now(@review, github: github)
      assert_equal "merged", @review.reload.status, "status #{status} nie zgasł po merge'u"
    end
  end

  test "status końcowy wypada ze scope'a — dashboard nie pyta o niego więcej" do
    @review.update!(status: "merged", github_checked_at: 2.hours.ago)
    assert_not_includes Review.due_for_github_check, @review
  end

  test "review, który nie jest już do sprawdzenia, nie jest ruszany ani odpytywany" do
    @review.update!(status: "reviewing")
    github = FakeGithub.new
    CheckReviewRequestJob.perform_now(@review, github: github)
    assert_empty github.calls
    assert_nil @review.reload.github_checked_at
  end

  # Padający gh nie może udawać zamkniętego PR-a — status musi zostać nietknięty.
  test "błąd gh nie wywraca joba, nie kończy review i zapisuje sprawdzenie" do
    github = FakeGithub.new(error: GithubClient::Error.new("rate limit"))
    CheckReviewRequestJob.perform_now(@review, github: github)
    assert_equal "decided", @review.reload.status
    assert_not_nil @review.github_checked_at
  end

  # Login bierze się z GitHuba (gh api user), a nie z configu — ręcznie wpisany
  # potrafił się rozjechać z kontem, do którego rozwiązuje się `@me`.
  test "login reviewera bierze się z zalogowanego konta gh" do
    github = FakeGithub.new({ "reviewRequests" => [ { "login" => "inny_login" } ], "state" => "OPEN" },
                            login: "inny_login")
    CheckReviewRequestJob.perform_now(@review, github: github)
    assert_equal "waiting_review", @review.reload.status
  end
end
