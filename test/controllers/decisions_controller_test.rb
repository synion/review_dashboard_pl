require "test_helper"

class DecisionsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @review = reviews(:pr_review)
    @review.update!(status: "reviewed", worktree_path: "/wt", summary: "OK")
  end

  # Diff PR-a: nowy plik o 5 liniach, wszystkie komentowalne.
  DIFF = <<~HEAD + (1..5).map { |i| "+linia #{i}" }.join("\n") + "\n"
    diff --git a/app/models/invoice.rb b/app/models/invoice.rb
    --- /dev/null
    +++ b/app/models/invoice.rb
    @@ -0,0 +1,5 @@
  HEAD

  def fake_client(submitted, diff: DIFF, head_sha: "aaa1111")
    Object.new.tap do |o|
      o.define_singleton_method(:pr_diff) { |_url, repo_dir:| diff }
      # Stan kodu w chwili decyzji — punkt odniesienia późniejszej weryfikacji poprawek.
      o.define_singleton_method(:pr_head_sha) { |_url, repo_dir:| head_sha }
      o.define_singleton_method(:submit_review) do |url, verdict:, body:, repo_dir:, comments: []|
        submitted << { url: url, verdict: verdict, body: body, repo_dir: repo_dir, comments: comments }
      end
    end
  end

  test "sukces: wysyła review i ustawia decided" do
    submitted = []
    GithubClient.stub :new, fake_client(submitted) do
      post review_decision_path(@review), params: { verdict: "approve", body: "LGTM" }
    end
    @review.reload
    assert_equal [ { url: @review.pr_url, verdict: "approve", body: "LGTM", repo_dir: "/wt", comments: [] } ], submitted
    assert_equal({ status: "decided", decision: "approve", decision_body: "LGTM" },
                 { status: @review.status, decision: @review.decision, decision_body: @review.decision_body })
    assert_not_nil @review.decided_at
    assert_equal "aaa1111", @review.decision_head_sha
    assert_redirected_to review_path(@review)
  end

  test "po decyzji panel pokazuje wyrenderowaną treść decyzji" do
    @review.update!(status: "decided", decision: "approve", decision_body: "**Zatwierdzam** bez uwag", decided_at: Time.current)
    get review_path(@review)
    assert_select ".md strong", text: "Zatwierdzam"
  end

  test "zaznaczony checkbox inline: znaleziska idą jako komentarze przy liniach" do
    @review.findings.create!(priority: "critical", title: "Nil w VAT", body: "**Problem:** nil", file_location: "app/models/invoice.rb:3")
    @review.findings.create!(priority: "minor", title: "Uwaga ogólna", body: "**Problem:** x", file_location: nil)
    submitted = []
    GithubClient.stub :new, fake_client(submitted) do
      post review_decision_path(@review), params: { verdict: "reject", body: "Uwagi", inline_comments: "1" }
    end

    comments = submitted.sole[:comments]
    assert_equal [ { path: "app/models/invoice.rb", line: 3, side: "RIGHT",
                     body: "🔴 **Krytyczne — Nil w VAT**\n\n**Problem:** nil" } ], comments
    assert_equal "decided", @review.reload.status
    assert_equal "Decyzja reject wysłana na GitHub — 1 uwaga przy liniach, 1 bez linii (w treści zbiorczej)", flash[:notice]
  end

  test "odznaczony checkbox inline: sama treść zbiorcza" do
    @review.findings.create!(priority: "critical", title: "Nil w VAT", body: "x", file_location: "app/models/invoice.rb:3")
    submitted = []
    GithubClient.stub :new, fake_client(submitted) do
      post review_decision_path(@review), params: { verdict: "approve", body: "LGTM" }
    end
    assert_empty submitted.sole[:comments]
  end

  test "błąd gh: nie zmienia statusu, pokazuje komunikat i zachowuje treść" do
    failing = Object.new.tap { |o| o.define_singleton_method(:submit_review) { |*_a, **_kw| raise GithubClient::Error, "Can not approve your own pull request" } }
    GithubClient.stub :new, failing do
      post review_decision_path(@review), params: { verdict: "approve", body: "MOJA TREŚĆ" }
    end
    assert_response :unprocessable_entity
    assert_equal "reviewed", @review.reload.status
    assert_select ".flash-error", text: /approve your own/
    assert_select "textarea[name=body]", text: /MOJA TREŚĆ/
  end

  test "formularz decyzji dziedziczy wybór inline ze startu review" do
    get review_path(@review)
    assert_select "input[name=inline_comments][checked]"

    @review.update!(scope: { "inline_comments" => false })
    get review_path(@review)
    assert_select "input[name=inline_comments]"
    assert_select "input[name=inline_comments][checked]", false
  end

  test "checkbox komentarza do zadania: kolejkuje job, mrozi instrukcję, status queued" do
    @review.update!(task_url: "https://tasks.example.com/777")
    GithubClient.stub :new, fake_client([]) do
      assert_enqueued_with(job: CommentTaskJob, args: [ @review ]) do
        post review_decision_path(@review),
             params: { verdict: "approve", body: "LGTM", task_comment: "1",
                       task_comment_instructions: "Krótko, po polsku" }
      end
    end
    @review.reload
    assert_equal "queued", @review.task_comment_status
    assert_equal "Krótko, po polsku", @review.task_comment_instructions
    assert_match(/Komentarz do zadania w kolejce/, flash[:notice])
  end

  test "bez checkboxa komentarz do zadania zostaje skipped" do
    @review.update!(task_url: "https://tasks.example.com/777")
    GithubClient.stub :new, fake_client([]) do
      assert_no_enqueued_jobs only: CommentTaskJob do
        post review_decision_path(@review), params: { verdict: "approve", body: "LGTM" }
      end
    end
    assert_equal "skipped", @review.reload.task_comment_status
  end

  test "spreparowany checkbox bez task_url nie kolejkuje joba" do
    GithubClient.stub :new, fake_client([]) do
      assert_no_enqueued_jobs only: CommentTaskJob do
        post review_decision_path(@review), params: { verdict: "approve", body: "LGTM", task_comment: "1" }
      end
    end
    assert_equal "skipped", @review.reload.task_comment_status
  end

  test "błąd gh nie kolejkuje komentarza do zadania" do
    @review.update!(task_url: "https://tasks.example.com/777")
    failing = Object.new.tap { |o| o.define_singleton_method(:submit_review) { |*_a, **_kw| raise GithubClient::Error, "boom" } }
    GithubClient.stub :new, failing do
      assert_no_enqueued_jobs only: CommentTaskJob do
        post review_decision_path(@review), params: { verdict: "approve", body: "x", task_comment: "1" }
      end
    end
    assert_equal "skipped", @review.reload.task_comment_status
  end

  test "formularz decyzji pokazuje checkbox komentarza tylko przy task_url" do
    get review_path(@review)
    assert_select "input[name=task_comment]", false

    @review.update!(task_url: "https://tasks.example.com/777")
    @review.project.update!(task_comment_instructions: "INSTRUKCJA Z PROJEKTU")
    get review_path(@review)
    assert_select "input[name=task_comment]"
    assert_select "input[name=task_comment][checked]", false
    assert_select "textarea[name=task_comment_instructions]", text: /INSTRUKCJA Z PROJEKTU/
  end

  test "odrzuca nieznany verdict" do
    post review_decision_path(@review), params: { verdict: "hack", body: "x" }
    assert_response :unprocessable_entity
  end

  test "review bez PR-a (tylko link do zadania) nie wysyła nic do gh" do
    review = reviews(:task_only)
    review.update!(status: "reviewed", summary: "OK")
    post review_decision_path(review), params: { verdict: "approve", body: "x" }
    assert_response :unprocessable_entity
    assert_select ".flash-error", text: /nie ma powiązanego PR-a/
  end

  test "wybrany reviewer i label zamrażają się na review ze statusem queued i kolejkują job" do
    GithubClient.stub :new, fake_client([]) do
      assert_enqueued_with(job: FollowupActionsJob) do
        post review_decision_path(@review), params: { verdict: "approve", body: "LGTM",
                                                      followup_reviewer: "anna", followup_label: "after-review" }
      end
    end

    @review.reload
    assert_equal "decided", @review.status
    assert_equal %w[anna queued], [ @review.followup_reviewer_login, @review.followup_reviewer_status ]
    assert_equal %w[after-review queued], [ @review.followup_label_name, @review.followup_label_status ]
  end

  test "puste comboboxy akcji nie kolejkują joba" do
    GithubClient.stub :new, fake_client([]) do
      assert_no_enqueued_jobs(only: FollowupActionsJob) do
        post review_decision_path(@review), params: { verdict: "approve", body: "LGTM",
                                                      followup_reviewer: "", followup_label: "" }
      end
    end

    assert_nil @review.reload.followup_reviewer_status
  end

  test "ponowienie: failed wraca do queued i job jest kolejkowany" do
    @review.update!(status: "decided", decision: "approve",
                    followup_reviewer_login: "anna", followup_reviewer_status: "failed",
                    followup_reviewer_error: "chwilowo padło")

    assert_enqueued_with(job: FollowupActionsJob) do
      post review_followup_actions_path(@review)
    end

    assert_equal "queued", @review.reload.followup_reviewer_status
  end

  test "wybrana osoba drugiego sprawdzenia mrozi się na review z nazwą z cache" do
    @review.update!(task_url: "https://tracker.example.com/organize/tasks/123")
    DirectoryEntry.replace!(@review.project, "intum_user", [ { external_id: "55", name: "Anna Kowalska" } ])

    GithubClient.stub :new, fake_client([]) do
      post review_decision_path(@review), params: { verdict: "approve", body: "LGTM", task_comment: "1",
                                                    task_comment_responsible_id: "55" }
    end

    @review.reload
    assert_equal %w[55 Anna\ Kowalska],
                 [ @review.task_comment_responsible_id, @review.task_comment_responsible_name ]
    assert_equal "queued", @review.task_comment_status
  end

  test "ponowienie bez porażek nic nie kolejkuje" do
    @review.update!(status: "decided", decision: "approve",
                    followup_reviewer_login: "anna", followup_reviewer_status: "sent")

    assert_no_enqueued_jobs(only: FollowupActionsJob) do
      post review_followup_actions_path(@review)
    end
  end
end
