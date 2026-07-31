require "test_helper"

class FindingVerificationImporterTest < ActiveSupport::TestCase
  setup do
    @review = reviews(:pr_review)
    @review.update!(status: "reviewed", branch: "sl-fix-vat")
    @first = @review.findings.create!(priority: "critical", title: "nil w kalkulacji", body: "x")
    @second = @review.findings.create!(priority: "minor", title: "literówka", body: "y")
    FileUtils.mkdir_p(@review.artifacts_dir)
  end

  teardown { FileUtils.rm_rf(@review.artifacts_dir) }

  def write_verdicts(verdicts)
    @review.artifacts_dir.join("verdicts.json").write({ verdicts: verdicts }.to_json)
  end

  test "should assign the verdicts to their findings and stamp the verification" do
    write_verdicts([ { id: @first.id, verdict: "refuted", note: "guard w invoice.rb:80 to łapie" },
                     { id: @second.id, verdict: "confirmed", note: "literówka faktycznie jest" } ])

    FindingVerificationImporter.call(@review)

    assert_equal [ "refuted", "guard w invoice.rb:80 to łapie" ], [ @first.reload.verdict, @first.verdict_note ]
    assert_equal "confirmed", @second.reload.verdict
    assert @review.reload.findings_verified_at.present?
  end

  # Fałszywe „obalone" jest groźniejsze niż brak werdyktu — wpisy nie do przypisania
  # wypadają zamiast trafiać w losowe znalezisko.
  test "should ignore verdicts for findings that do not exist" do
    write_verdicts([ { id: 999_999, verdict: "refuted", note: "nie ma takiego" },
                     { id: @first.id, verdict: "disputed", note: "kwestia gustu" } ])

    FindingVerificationImporter.call(@review)

    assert_equal "disputed", @first.reload.verdict
    assert_nil @second.reload.verdict
  end

  test "should ignore verdicts outside the allowed values" do
    write_verdicts([ { id: @first.id, verdict: "chyba_ok", note: "?" } ])

    FindingVerificationImporter.call(@review)

    assert_nil @first.reload.verdict
  end

  test "should raise when the session wrote no result file" do
    error = assert_raises(FindingVerificationImporter::Missing) { FindingVerificationImporter.call(@review) }
    assert_includes error.message, "verdicts.json"
  end

  # Werdykt z drugiego przebiegu zastępuje poprzedni — kod mógł się zmienić
  # od pierwszej weryfikacji.
  test "should overwrite an earlier verdict" do
    write_verdicts([ { id: @first.id, verdict: "disputed", note: "nie wiem" } ])
    FindingVerificationImporter.call(@review)

    write_verdicts([ { id: @first.id, verdict: "confirmed", note: "jednak jest" } ])
    FindingVerificationImporter.call(@review)

    assert_equal "confirmed", @first.reload.verdict
  end
end
