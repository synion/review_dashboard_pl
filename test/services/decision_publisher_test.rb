require "test_helper"

class DecisionPublisherTest < ActiveSupport::TestCase
  DIFF = <<~HEAD + (1..20).map { |i| "+linia #{i}" }.join("\n") + "\n"
    diff --git a/app/models/invoice.rb b/app/models/invoice.rb
    --- /dev/null
    +++ b/app/models/invoice.rb
    @@ -0,0 +1,20 @@
  HEAD

  class FakeClient
    attr_reader :submitted, :diff_calls

    def initialize(diff: DIFF, diff_error: nil, submit_errors: [])
      @diff = diff
      @diff_error = diff_error
      @submit_errors = submit_errors
      @submitted = []
      @diff_calls = 0
    end

    def pr_diff(_url, repo_dir:)
      @diff_calls += 1
      raise GithubClient::Error, @diff_error if @diff_error

      @diff
    end

    def submit_review(_url, verdict:, body:, repo_dir:, comments: [])
      @submitted << { verdict: verdict, body: body, comments: comments }
      error = @submit_errors.shift
      raise GithubClient::Error, error if error
    end
  end

  setup do
    @review = reviews(:pr_review)
    @review.update!(status: "reviewed", worktree_path: "/wt")
    @review.findings.create!(priority: "critical", title: "Nil w VAT", body: "**Problem:** nil", file_location: "app/models/invoice.rb:5")
    @review.findings.create!(priority: "minor", title: "Nazwa zmiennej", body: "**Problem:** x", file_location: "app/models/invoice.rb:9")
    @review.findings.create!(priority: "important", title: "Brak testu", body: "**Problem:** brak", file_location: nil)
  end

  def publish(inline:, client:)
    DecisionPublisher.call(@review, verdict: "approve", body: "LGTM", inline: inline, client: client)
  end

  test "inline wyłączone: jeden komentarz zbiorczy, diffu nawet nie pobieramy" do
    client = FakeClient.new
    notice = publish(inline: false, client: client)

    assert_equal 0, client.diff_calls
    assert_equal [ [] ], client.submitted.map { |s| s[:comments] }
    assert_equal "Decyzja approve wysłana na GitHub", notice
  end

  test "inline włączone: przypinalne idą do gh api, reszta zostaje w treści" do
    client = FakeClient.new
    notice = publish(inline: true, client: client)

    assert_equal [ 5, 9 ], client.submitted.sole[:comments].map { |c| c[:line] }.sort
    assert_equal "Decyzja approve wysłana na GitHub — 2 uwagi przy liniach, 1 bez linii (w treści zbiorczej)", notice
  end

  # Polska odmiana: 1 uwaga, 2-4 uwagi, 5+ uwag. „5 uwagi" w komunikacie kłuje w oczy.
  test "licznik uwag odmienia się poprawnie" do
    @review.findings.destroy_all
    counts_to_text = { 1 => "1 uwaga przy liniach", 2 => "2 uwagi przy liniach", 5 => "5 uwag przy liniach" }
    counts_to_text.each do |count, expected|
      @review.findings.destroy_all
      count.times { |i| @review.findings.create!(priority: "minor", title: "T#{i}", body: "b", file_location: "app/models/invoice.rb:#{i + 1}") }
      assert_includes publish(inline: true, client: FakeClient.new), expected
    end
  end

  test "żadna uwaga nie pasuje do diffu: publikacja idzie dalej, notice to mówi" do
    @review.findings.update_all(file_location: "app/models/user.rb:5")
    client = FakeClient.new
    notice = publish(inline: true, client: client)

    assert_empty client.submitted.sole[:comments]
    assert_includes notice, "żadnej uwagi nie dało się przypiąć"
  end

  test "review bez znalezisk nie pyta o diff" do
    @review.findings.destroy_all
    client = FakeClient.new
    assert_equal "Decyzja approve wysłana na GitHub", publish(inline: true, client: client)
    assert_equal 0, client.diff_calls
  end

  # Decyzja jest ważniejsza niż jej forma — nieudany `gh pr diff` nie może jej zablokować.
  test "nieudany gh pr diff: decyzja ląduje bez pinezek, notice podaje powód" do
    client = FakeClient.new(diff_error: "could not find pull request")
    notice = publish(inline: true, client: client)

    assert_empty client.submitted.sole[:comments]
    assert_includes notice, "nie udało się pobrać diffu"
    assert_includes notice, "could not find pull request"
  end

  test "GitHub odrzuca pinezki: drugi strzał bez nich, decyzja ląduje" do
    client = FakeClient.new(submit_errors: [ "line must be part of the diff" ])
    notice = publish(inline: true, client: client)

    assert_equal [ 2, 0 ], client.submitted.map { |s| s[:comments].size }
    assert_includes notice, "GitHub odrzucił komentarze przy liniach"
    assert_includes notice, "line must be part of the diff"
  end

  test "gdy i publikacja bez pinezek pada, błąd leci do kontrolera" do
    client = FakeClient.new(submit_errors: [ "422", "Can not approve your own pull request" ])
    error = assert_raises(GithubClient::Error) { publish(inline: true, client: client) }
    assert_includes error.message, "your own pull request"
  end
end
