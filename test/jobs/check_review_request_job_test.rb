require "test_helper"

class CheckReviewRequestJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

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

  # Akcja „reviewer" po decyzji potrafi dodać własny login (znacznik „PR czeka na
  # moje kolejne review" na GitHubie). Taki request wisi w reviewRequests od chwili
  # decyzji aż do następnego review — jego obecność nie mówi NIC o autorze. Bez
  # wyjątku dashboard pół godziny po decyzji kłamał „Czeka ponowne review".
  test "request wysłany przez dashboard na własny login nie udaje re-requesta" do
    @review.update!(followup_reviewer_login: "synion", followup_reviewer_status: "sent")
    github = FakeGithub.new({ "reviewRequests" => [ { "login" => "synion" } ], "state" => "OPEN" })
    CheckReviewRequestJob.perform_now(@review, github: github)
    assert_equal "decided", @review.reload.status
    assert_not_nil @review.github_checked_at
  end

  # Reviewer dodany przez dashboard to ktoś inny — własny login na liście może
  # pochodzić tylko od autora, więc to prawdziwy re-request.
  test "request na własny login liczy się, gdy dashboard dodawał kogoś innego" do
    @review.update!(followup_reviewer_login: "inny_reviewer", followup_reviewer_status: "sent")
    github = FakeGithub.new({ "reviewRequests" => [ { "login" => "synion" } ], "state" => "OPEN" })
    CheckReviewRequestJob.perform_now(@review, github: github)
    assert_equal "waiting_review", @review.reload.status
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

  # „Ruch na PR" na liście bierze się stąd — data ma się zapisać także wtedy,
  # gdy status review się nie zmienia (gałąź update_columns).
  test "updatedAt z GitHuba ląduje w pr_activity_at przy rutynowym sprawdzeniu" do
    github = FakeGithub.new({ "reviewRequests" => [], "state" => "OPEN",
                              "updatedAt" => "2026-08-04T10:00:00Z" })
    CheckReviewRequestJob.perform_now(@review, github: github)
    assert_equal Time.utc(2026, 8, 4, 10), @review.reload.pr_activity_at
  end

  test "pr_activity_at zapisuje się też przy zmianie statusu (merge)" do
    github = FakeGithub.new({ "reviewRequests" => [], "state" => "MERGED",
                              "updatedAt" => "2026-08-04T10:00:00Z" })
    CheckReviewRequestJob.perform_now(@review, github: github)
    assert_equal Time.utc(2026, 8, 4, 10), @review.reload.pr_activity_at
  end

  # Stara data to więcej niż żadna — padnięty gh (puste info) nie może wyzerować
  # ostatniej znanej aktywności.
  test "błąd gh nie kasuje wcześniej zapisanego pr_activity_at" do
    @review.update!(pr_activity_at: Time.utc(2026, 8, 1))
    github = FakeGithub.new(error: GithubClient::Error.new("rate limit"))
    CheckReviewRequestJob.perform_now(@review, github: github)
    assert_equal Time.utc(2026, 8, 1), @review.reload.pr_activity_at
  end

  # Login bierze się z GitHuba (gh api user), a nie z configu — ręcznie wpisany
  # potrafił się rozjechać z kontem, do którego rozwiązuje się `@me`.
  test "login reviewera bierze się z zalogowanego konta gh" do
    github = FakeGithub.new({ "reviewRequests" => [ { "login" => "inny_login" } ], "state" => "OPEN" },
                            login: "inny_login")
    CheckReviewRequestJob.perform_now(@review, github: github)
    assert_equal "waiting_review", @review.reload.status
  end

  # „PR wrócił po poprawkach" to dokładnie ten re-request — jedyny moment, w którym
  # automat drugiego przełącznika ma prawo odpalić sesję.
  test "włączony automat po poprawkach odpala followup zaraz po wykryciu re-requesta" do
    # Przez @review.project, nie projects(:webapp): asocjacja jest już wczytana
    # z setupu, a AutoReview pyta o ustawienie właśnie ją.
    @review.project.update!(auto_review_returned: true)
    github = FakeGithub.new({ "reviewRequests" => [ { "login" => "synion" } ], "state" => "OPEN" })

    assert_enqueued_with job: FollowupReviewJob, args: [ @review, AutoReview::RETURNED_MESSAGE ] do
      CheckReviewRequestJob.perform_now(@review, github: github)
    end
    assert_equal "reviewing", @review.reload.status
  end

  test "wyłączony automat zostawia re-request do kliknięcia" do
    assert_no_enqueued_jobs only: FollowupReviewJob do
      CheckReviewRequestJob.perform_now(@review, github: FakeGithub.new({ "reviewRequests" => [ { "login" => "synion" } ], "state" => "OPEN" }))
    end
    assert_equal "waiting_review", @review.reload.status
  end
end
