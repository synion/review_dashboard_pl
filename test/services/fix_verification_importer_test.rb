require "test_helper"

class FixVerificationImporterTest < ActiveSupport::TestCase
  setup do
    @review = reviews(:pr_review)
    @review.update!(status: "decided", decision: "comment", decision_head_sha: "aaa1111")
    @first = @review.findings.create!(priority: "critical", title: "nil w kalkulacji", body: "x")
    @second = @review.findings.create!(priority: "minor", title: "literówka", body: "y")
    FileUtils.mkdir_p(@review.artifacts_dir)
  end

  teardown { FileUtils.rm_rf(@review.artifacts_dir) }

  def write_fixes(fixes)
    @review.artifacts_dir.join("fixes.json").write({ fixes: fixes }.to_json)
  end

  test "should assign the verdicts to their findings and stamp the check" do
    write_fixes([ { id: @first.id, status: "implemented", note: "guard w invoice.rb:212" },
                  { id: @second.id, status: "ignored", note: "nazwa bez zmian" } ])

    FixVerificationImporter.call(@review)

    assert_equal [ "implemented", "guard w invoice.rb:212" ], [ @first.reload.fix_status, @first.fix_note ]
    assert_equal "ignored", @second.reload.fix_status
    assert @review.reload.fixes_checked_at.present?
  end

  # Fałszywe „wdrożone" jest groźniejsze niż brak werdyktu, więc wpisy, których nie da
  # się jednoznacznie przypisać, wypadają zamiast trafiać w losowe znalezisko.
  test "should ignore verdicts for findings that do not exist" do
    write_fixes([ { id: 999_999, status: "implemented", note: "nie ma takiego" },
                  { id: @first.id, status: "unclear", note: "diff nie pokazuje" } ])

    FixVerificationImporter.call(@review)

    assert_equal "unclear", @first.reload.fix_status
    assert_nil @second.reload.fix_status
  end

  test "should ignore verdicts outside the allowed statuses" do
    write_fixes([ { id: @first.id, status: "chyba_ok", note: "?" } ])

    FixVerificationImporter.call(@review)

    assert_nil @first.reload.fix_status
  end

  test "should raise when the session wrote no result file" do
    error = assert_raises(FixVerificationImporter::Missing) { FixVerificationImporter.call(@review) }
    assert_includes error.message, "fixes.json"
  end

  # Werdykt z drugiego przebiegu ma zastąpić poprzedni — autor mógł w międzyczasie
  # dowieźć to, co pierwszy raz zignorował.
  test "should overwrite an earlier verdict" do
    write_fixes([ { id: @first.id, status: "ignored", note: "brak" } ])
    FixVerificationImporter.call(@review)

    write_fixes([ { id: @first.id, status: "implemented", note: "dowiezione" } ])
    FixVerificationImporter.call(@review)

    assert_equal "implemented", @first.reload.fix_status
  end
end
