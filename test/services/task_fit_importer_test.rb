require "test_helper"

class TaskFitImporterTest < ActiveSupport::TestCase
  setup do
    @review = reviews(:pr_review)
    @review.update!(task_criteria: {
      "criteria" => [ { "id" => "ac1", "text" => "Kod 2FA przez SMS dochodzi do klienta" },
                      { "id" => "ac2", "text" => "count: 0 traktowane jako porażka" } ],
      "traps" => [ { "id" => "t1", "text" => "Czy autor odczytał log produkcyjny, czy wdrożył hipotezę" } ],
      "process" => [ { "id" => "p1", "text" => "Link do Figmy dla nowego ekranu" } ]
    })
    @mine = @review.findings.create!(priority: "minor", title: "Literówka", body: "x")
    FileUtils.rm_rf(@review.artifacts_dir)
    FileUtils.mkdir_p(@review.artifacts_dir)
  end

  teardown { FileUtils.rm_rf(@review.artifacts_dir) }

  def data(criteria: {}, traps: {}, process: {}, evidence_found: true)
    { "symptom" => "SMS nie dochodzi", "assumed_cause" => "SMSAPI odrzuca", "evidence" => "log z 21.08",
      "evidence_found" => evidence_found,
      "criteria" => { "ac1" => "met", "ac2" => "met" }.merge(criteria).map { |id, st| { "id" => id, "status" => st, "note" => "n-#{id}", "needed_evidence" => "dowód-#{id}" } },
      "traps" => { "t1" => "addressed" }.merge(traps).map { |id, st| { "id" => id, "status" => st, "note" => "n-#{id}" } },
      "process" => { "p1" => "present" }.merge(process).map { |id, st| { "id" => id, "status" => st, "note" => "n-#{id}" } } }
  end

  def import(**opts)
    TaskFitImporter.import(@review, data(**opts))
    @review.reload
  end

  test "wszystko spełnione daje fits bez znalezisk bramki" do
    import
    assert_equal "fits", @review.task_fit["verdict"]
    assert_equal "ready", @review.task_fit_status
    assert_not_nil @review.task_fit_checked_at
    assert_empty @review.findings.from_task_fit
    assert_equal [ @mine ], @review.findings.to_a
  end

  test "niespełnione AC daje misses i znalezisko critical" do
    import(criteria: { "ac1" => "unmet" })
    assert_equal "misses", @review.task_fit["verdict"]
    finding = @review.findings.from_task_fit.sole
    assert_equal [ "critical", "AC niespełnione: Kod 2FA przez SMS dochodzi do klienta", "task_fit" ],
                 [ finding.priority, finding.title, finding.source ]
    assert_includes finding.body, "**Problem:** n-ac1"
    assert_includes finding.body, "**Co się stanie:**"
    assert_includes finding.body, "**Jak naprawić:**"
    assert_equal "unmet", @review.task_fit["criteria"].first["status"]
    assert_equal "Kod 2FA przez SMS dochodzi do klienta", @review.task_fit["criteria"].first["text"]
  end

  test "niesprawdzalne AC bez innych braków daje partial i important z dowodem do dostarczenia" do
    import(criteria: { "ac1" => "unverifiable" })
    assert_equal "partial", @review.task_fit["verdict"]
    finding = @review.findings.from_task_fit.sole
    assert_equal [ "important", "Niesprawdzalne z kodu: Kod 2FA przez SMS dochodzi do klienta" ], [ finding.priority, finding.title ]
    assert_includes finding.body, "dowód-ac1"
  end

  test "otwarta pułapka daje misses" do
    import(traps: { "t1" => "open" })
    assert_equal "misses", @review.task_fit["verdict"]
    assert_equal "Pułapka z zadania otwarta: Czy autor odczytał log produkcyjny, czy wdrożył hipotezę",
                 @review.findings.from_task_fit.sole.title
  end

  test "brakujący wymóg procesu daje misses, n/a nie" do
    import(process: { "p1" => "missing" })
    assert_equal "misses", @review.task_fit["verdict"]
    assert_equal "Brak w procesie: Link do Figmy dla nowego ekranu", @review.findings.from_task_fit.sole.title

    import(process: { "p1" => "n/a" })
    assert_equal "fits", @review.task_fit["verdict"]
  end

  test "premisa bez dowodu daje misses i znalezisko o hipotezie" do
    import(evidence_found: false)
    assert_equal "misses", @review.task_fit["verdict"]
    finding = @review.findings.from_task_fit.sole
    assert_equal "Przyczyna z PR-a jest hipotezą bez dowodu", finding.title
    assert_includes finding.body, "SMSAPI odrzuca"
  end

  test "brak odpowiedzi na punkt jest czerwony, nieznane id pomijane" do
    payload = data
    payload["criteria"] = [ { "id" => "ac2", "status" => "met" }, { "id" => "zmyslone", "status" => "met" } ]
    payload["traps"] = []
    TaskFitImporter.import(@review, payload)
    @review.reload
    ac1 = @review.task_fit["criteria"].find { |c| c["id"] == "ac1" }
    assert_equal "unverifiable", ac1["status"]
    assert_includes ac1["note"], "nie odpowiedziała"
    assert_equal "open", @review.task_fit["traps"].sole["status"]
    assert_equal "misses", @review.task_fit["verdict"]
    assert_nil @review.task_fit["criteria"].find { |c| c["id"] == "zmyslone" }
  end

  test "status spoza słownika traktowany jak brak odpowiedzi" do
    import(criteria: { "ac1" => "chyba_ok" })
    assert_equal "unverifiable", @review.task_fit["criteria"].first["status"]
  end

  test "ponowny import kasuje stare znaleziska bramki, review nietknięte" do
    import(criteria: { "ac1" => "unmet" })
    import
    assert_empty @review.findings.from_task_fit
    assert_equal [ @mine ], @review.findings.to_a
  end

  test "call czyta task_fit.json, bez pliku rzuca Missing" do
    assert_raises(TaskFitImporter::Missing) { TaskFitImporter.call(@review) }
    File.write(@review.artifacts_dir.join("task_fit.json"), data(criteria: { "ac1" => "unmet" }).to_json)
    TaskFitImporter.call(@review)
    assert_equal "misses", @review.reload.task_fit["verdict"]
  end

  test "manual_checks zbiera punkty do ręcznego sprawdzenia" do
    import(criteria: { "ac1" => "unverifiable" })
    assert_equal [ { "id" => "ac1", "text" => "Kod 2FA przez SMS dochodzi do klienta", "needed_evidence" => "dowód-ac1" } ],
                 @review.task_fit_manual_checks
  end
end
