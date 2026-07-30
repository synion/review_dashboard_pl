require "test_helper"

class ReviewResultImporterTest < ActiveSupport::TestCase
  setup do
    @review = reviews(:pr_review)
    FileUtils.rm_rf(@review.artifacts_dir)
    FileUtils.mkdir_p(@review.artifacts_dir)
  end

  # Bez tego ostatni test zostawia result.json na wspólnej ścieżce fixture'a,
  # a OrphanedRunsCleanup traktuje go jako wynik do odzyskania i wywraca cudzy test.
  teardown do
    FileUtils.rm_rf(@review.artifacts_dir)
  end

  test "importuje findings, summary i playwright" do
    File.write(@review.artifacts_dir.join("result.json"), {
      summary: "Ogólnie OK",
      findings: [
        { priority: "critical", title: "Nil na kwocie", body: "Napraw X", file: "app/models/invoice.rb:10" },
        { priority: "minor", title: "Literówka", body: "Y", file: "app/views/a.erb:1" }
      ],
      playwright: { test_path: "tmp/rev.spec.js", command: "npx playwright test tmp/rev.spec.js" }
    }.to_json)

    ReviewResultImporter.call(@review)
    @review.reload
    assert_equal(
      { summary: "Ogólnie OK", playwright_test_path: "tmp/rev.spec.js", playwright_command: "npx playwright test tmp/rev.spec.js" },
      { summary: @review.summary, playwright_test_path: @review.playwright_test_path, playwright_command: @review.playwright_command }
    )
    assert_equal [
      { priority: "critical", title: "Nil na kwocie", body: "Napraw X", file_location: "app/models/invoice.rb:10" },
      { priority: "minor", title: "Literówka", body: "Y", file_location: "app/views/a.erb:1" }
    ], @review.findings.order(:id).map { |f| { priority: f.priority, title: f.title, body: f.body, file_location: f.file_location } }
  end

  test "surowy JSON ląduje w raw_result (kopia w bazie)" do
    payload = { summary: "OK", findings: [], playwright: nil }.to_json
    File.write(@review.artifacts_dir.join("result.json"), payload)
    ReviewResultImporter.call(@review)
    assert_equal payload, @review.reload.raw_result
  end

  test "from_raw_result odtwarza wynik z bazy bez pliku" do
    @review.update!(raw_result: { summary: "Z bazy", findings: [ { priority: "minor", title: "B", body: "", file: "" } ], playwright: nil }.to_json)
    ReviewResultImporter.from_raw_result(@review)
    assert_equal({ summary: "Z bazy", findings: [ "B" ] },
                 { summary: @review.reload.summary, findings: @review.findings.map(&:title) })
  end

  test "playwright null zostawia puste kolumny" do
    File.write(@review.artifacts_dir.join("result.json"), { summary: "OK", findings: [], playwright: nil }.to_json)
    ReviewResultImporter.call(@review)
    assert_nil @review.reload.playwright_command
  end

  test "brak pliku rzuca Missing" do
    assert_raises(ReviewResultImporter::Missing) { ReviewResultImporter.call(@review) }
  end

  test "ponowny import nadpisuje stare findings" do
    File.write(@review.artifacts_dir.join("result.json"), { summary: "OK", findings: [ { priority: "minor", title: "A", body: "", file: "" } ], playwright: nil }.to_json)
    ReviewResultImporter.call(@review)
    ReviewResultImporter.call(@review)
    assert_equal [ "A" ], @review.findings.map(&:title)
  end
end
