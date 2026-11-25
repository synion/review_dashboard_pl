require "test_helper"

class ReconcileResultImporterTest < ActiveSupport::TestCase
  setup do
    @review = reviews(:pr_review)
    @review.update!(
      summary: "stare", raw_result: '{"raw":true}',
      task_criteria: { "criteria" => [ { "id" => "ac1", "text" => "Kod 2FA dochodzi do klienta" },
                                       { "id" => "ac2", "text" => "count: 0 to porażka" } ],
                       "traps" => [], "process" => [] }
    )
    @refuted = @review.findings.create!(priority: "important", title: "F1", body: "x", verdict: "refuted", verdict_note: "nie")
    @confirmed = @review.findings.create!(priority: "important", title: "F2", body: "x", verdict: "confirmed")
    @important = @review.findings.create!(priority: "important", title: "F", body: "x", verdict: "disputed")
    @minor = @review.findings.create!(priority: "minor", title: "G", body: "x", verdict: "disputed")
    TaskFitImporter.import(@review, "symptom" => "s", "assumed_cause" => "c", "evidence" => "e", "evidence_found" => true,
                                    "criteria" => [ { "id" => "ac1", "status" => "unmet", "note" => "brak" },
                                                    { "id" => "ac2", "status" => "met", "note" => "ok" } ])
    @review.reload
    FileUtils.rm_rf(@review.artifacts_dir)
    FileUtils.mkdir_p(@review.artifacts_dir)
  end

  teardown { FileUtils.rm_rf(@review.artifacts_dir) }

  # summary jest obowiązkowe (bez niego zostałoby stare, z usuniętymi znaleziskami),
  # więc testy, które sprawdzają co innego, dostają je z automatu.
  def import(data)
    ReconcileResultImporter.import(@review, { "summary" => "nowe" }.merge(data))
    @review.reload
  end

  test "rozstrzygnięcia trafiają tylko do obalonych i spornych, werdykty zostają" do
    count = @review.findings.count
    import("findings" => [ { "id" => @refuted.id, "resolution" => "dropped", "note" => "weryfikator ma rację" },
                           { "id" => @confirmed.id, "resolution" => "dropped", "note" => "x" } ])
    @refuted.reload
    assert_equal [ "dropped", "weryfikator ma rację", "refuted", "nie" ],
                 [ @refuted.resolution, @refuted.resolution_note, @refuted.verdict, @refuted.verdict_note ]
    assert_nil @confirmed.reload.resolution
    assert_equal count, @review.findings.count
  end

  test "downgraded obniża priorytet, ale nigdy go nie podnosi" do
    import("findings" => [ { "id" => @important.id, "resolution" => "downgraded", "priority" => "minor", "note" => "a" },
                           { "id" => @minor.id, "resolution" => "downgraded", "priority" => "critical", "note" => "b" } ])
    assert_equal [ "minor", "downgraded" ], [ @important.reload.priority, @important.resolution ]
    assert_equal [ "minor", "downgraded", "b" ], [ @minor.reload.priority, @minor.resolution, @minor.resolution_note ]
  end

  test "nieznane id i resolution spoza słownika są pomijane" do
    import("findings" => [ { "id" => 0, "resolution" => "dropped", "note" => "x" },
                           { "id" => @refuted.id, "resolution" => "whatever", "note" => "x" } ])
    assert_nil @refuted.reload.resolution
    assert_nil @review.task_fit_reconciliation
  end

  test "zmiana punktu z dowodem przelicza werdykt i znaleziska zgodności, oryginał nietknięty" do
    assert_equal "misses", @review.task_fit_verdict
    assert @review.findings.from_task_fit.exists?
    import("task_fit_changes" => [ { "id" => "ac1", "status" => "met", "note" => "app/x.rb:40" } ])
    assert_equal "fits", @review.task_fit_verdict
    assert_equal "misses", @review.task_fit["verdict"]
    assert_equal({ "from" => "unmet", "to" => "met", "note" => "app/x.rb:40" }, @review.task_fit_reconciliation["changes"]["ac1"])
    assert_equal "fits", @review.task_fit_reconciliation["verdict"]
    assert_not @review.findings.from_task_fit.any? { |f| f.title.start_with?("AC niespełnione") }
  end

  test "kolejne uzgodnienie bez zmian przywraca oryginalne znaleziska zgodności" do
    import("task_fit_changes" => [ { "id" => "ac1", "status" => "met", "note" => "app/x.rb:40" } ])
    assert_not @review.findings.from_task_fit.any? { |f| f.title.start_with?("AC niespełnione") }
    import({})
    assert_nil @review.task_fit_reconciliation
    assert_equal "misses", @review.task_fit_verdict
    assert @review.findings.from_task_fit.any? { |f| f.title.start_with?("AC niespełnione") }
  end

  test "evidence_found z notatką zmienia werdykt i znaleziska przesłanki" do
    @review.update!(task_fit: @review.task_fit.merge("evidence_found" => false))
    TaskFitImporter.import(@review, "symptom" => "s", "assumed_cause" => "c", "evidence" => "e", "evidence_found" => false,
                                    "criteria" => [ { "id" => "ac1", "status" => "met", "note" => "." },
                                                    { "id" => "ac2", "status" => "met", "note" => "." } ])
    @review.reload
    assert_equal "misses", @review.task_fit_verdict
    assert @review.findings.from_task_fit.exists?
    import("evidence_found" => { "value" => true, "note" => "log z 21.08" })
    assert_equal({ "from" => false, "to" => true, "note" => "log z 21.08" }, @review.task_fit_reconciliation["evidence_found"])
    assert_equal "fits", @review.task_fit_verdict
    assert_not @review.findings.from_task_fit.exists?
  end

  test "zmiana punktu bez note albo z niedozwolonym statusem jest pomijana" do
    import("task_fit_changes" => [ { "id" => "ac1", "status" => "met", "note" => " " },
                                   { "id" => "ac1", "status" => "addressed", "note" => "dowód" },
                                   { "id" => "ac2", "status" => "met", "note" => "to samo" } ],
           "evidence_found" => { "value" => true, "note" => "to samo" })
    assert_nil @review.task_fit_reconciliation
    assert_equal "misses", @review.task_fit_verdict
    assert @review.findings.from_task_fit.exists?
  end

  test "summary nadpisane, raw_result bez zmian" do
    import("summary" => "nowe")
    assert_equal "nowe", @review.summary
    assert_equal '{"raw":true}', @review.raw_result
  end

  # Stare summary dalej wymienia znaleziska, które uzgodnienie właśnie usunęło.
  test "brak albo puste summary to Missing i niczego nie zmienia" do
    [ {}, { "summary" => " " } ].each do |data|
      assert_raises(ReconcileResultImporter::Missing) do
        ReconcileResultImporter.import(@review, data.merge("findings" => [ { "id" => @refuted.id, "resolution" => "dropped", "note" => "x" } ]))
      end
    end
    assert_equal "stare", @review.reload.summary
    assert_nil @refuted.reload.resolution
  end

  test "JSON spoza obiektu to Missing" do
    assert_raises(ReconcileResultImporter::Missing) { ReconcileResultImporter.import(@review, [ { "summary" => "x" } ]) }
  end

  test "id znaleziska jako string też wiąże, wpisy spoza obiektów są pomijane" do
    import("findings" => [ "dropped", nil, { "id" => [ 1 ], "resolution" => "dropped" }, { "id" => @refuted.id.to_s, "resolution" => "dropped", "note" => "racja" } ],
           "task_fit_changes" => [ 1, "ac1", { "id" => "ac1", "status" => "met", "note" => "app/x.rb:40" } ])
    assert_equal "dropped", @refuted.reload.resolution
    assert_equal "fits", @review.task_fit_verdict
  end

  # Przebudowa znalezisk zgodności nie może kasować tego, co o nich ustaliła weryfikacja
  # i weryfikacja poprawek - uzgodnienie nie zmienia verdict*/fix_*.
  test "znalezisko zgodności zachowuje werdykt i ocenę poprawki przez uzgodnienie bez zmian" do
    finding = @review.findings.from_task_fit.sole
    finding.update!(verdict: "confirmed", verdict_note: "potwierdzam", fix_status: "ignored", fix_note: "dalej brak")
    import("findings" => [ { "id" => @refuted.id, "resolution" => "kept", "note" => "x" } ])
    rebuilt = @review.findings.from_task_fit.sole
    assert_equal [ finding.title, "confirmed", "potwierdzam", "ignored", "dalej brak" ],
                 [ rebuilt.title, rebuilt.verdict, rebuilt.verdict_note, rebuilt.fix_status, rebuilt.fix_note ]
  end

  # needed_evidence opisuje, czego brakuje do rozstrzygnięcia - po rozstrzygnięciu nieaktualne.
  test "rozstrzygnięty punkt niesprawdzalny gubi needed_evidence" do
    TaskFitImporter.import(@review, "symptom" => "s", "assumed_cause" => "c", "evidence" => "e", "evidence_found" => true,
                                    "criteria" => [ { "id" => "ac1", "status" => "unverifiable", "note" => "?", "needed_evidence" => "log z produkcji" },
                                                    { "id" => "ac2", "status" => "met", "note" => "ok" } ])
    @review.reload
    import("task_fit_changes" => [ { "id" => "ac1", "status" => "unmet", "note" => "app/x.rb:40 nie wysyła" } ])
    item = @review.task_fit_items.find { |i| i["id"] == "ac1" }
    assert_nil item["needed_evidence"]
    assert_includes @review.findings.from_task_fit.sole.body, TaskFitImporter::TEMPLATES["unmet"][:fix]
    assert_equal "log z produkcji", @review.task_fit_original_items.find { |i| i["id"] == "ac1" }["needed_evidence"]
  end

  test "call czyta reconcile.json" do
    File.write(@review.artifacts_dir.join("reconcile.json"), { summary: "z pliku" }.to_json)
    ReconcileResultImporter.call(@review, written_after: 1.minute.ago)
    assert_equal "z pliku", @review.reload.summary
  end

  test "brak pliku i stary plik dają Missing" do
    assert_raises(ReconcileResultImporter::Missing) { ReconcileResultImporter.call(@review) }
    path = @review.artifacts_dir.join("reconcile.json")
    File.write(path, "{}")
    File.utime(1.hour.ago.to_time, 1.hour.ago.to_time, path)
    assert_raises(ReconcileResultImporter::Missing) { ReconcileResultImporter.call(@review, written_after: Time.current) }
  end
end
