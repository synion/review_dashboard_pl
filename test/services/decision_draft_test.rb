require "test_helper"

class DecisionDraftTest < ActiveSupport::TestCase
  setup do
    @review = reviews(:pr_review)
    @review.update!(status: "reviewed", summary: "Zmiana wygląda dobrze.")
  end

  def gate!(verdict, criteria_status:, trap_status:)
    @review.update!(
      task_criteria: { "criteria" => [ { "id" => "ac1", "text" => "Kod dochodzi" } ],
                       "traps" => [ { "id" => "t1", "text" => "Log odczytany?" } ] },
      task_fit_status: "ready",
      task_fit: { "verdict" => verdict, "evidence_found" => true,
                  "criteria" => [ { "id" => "ac1", "text" => "Kod dochodzi", "kind" => "criterion", "status" => criteria_status,
                                    "note" => "brak logu", "needed_evidence" => "log z SMSAPI" } ],
                  "traps" => [ { "id" => "t1", "text" => "Log odczytany?", "kind" => "trap", "status" => trap_status, "note" => "komentarz 3" } ] }
    )
  end

  test "bez bramki i znalezisk: nagłówek z podsumowaniem i zdanie otwierające werdyktu" do
    drafts = DecisionDraft.new(@review).all
    assert_equal "## Review\n\nZmiana wygląda dobrze.\n", drafts["approve"]
    assert_equal "## Review\n\nZmiana wygląda dobrze.\n\n**Proszę o zmiany przed merge'em.**\n", drafts["reject"]
    assert_match(/\A## Review\n\nZmiana wygląda dobrze.\n\n\*\*Bez werdyktu/, drafts["comment"])
    assert_equal "approve", DecisionDraft.new(@review).suggested_verdict
  end

  test "misses: reject wylicza niespełnione punkty, approve bierze je na siebie, comment pyta o zakres" do
    gate!("misses", criteria_status: "unmet", trap_status: "open")
    drafts = DecisionDraft.new(@review).all
    assert_match(/\*\*Niespełnione punkty z zadania:\*\*\n- Kod dochodzi \(brak logu\)\n- Log odczytany\? \(komentarz 3\)/, drafts["reject"])
    assert_match(/\*\*Zatwierdzam mimo niespełnionych punktów z zadania\*\* \(świadoma decyzja\):\n- Kod dochodzi \(brak logu\)/, drafts["approve"])
    assert_match(/\*\*Do wyjaśnienia:\*\*\n- Kod dochodzi - czy to świadomie poza zakresem tego PR-a\? \(brak logu\)/, drafts["comment"])
    assert_equal "reject", DecisionDraft.new(@review).suggested_verdict
  end

  test "partial: niesprawdzalny punkt staje się pytaniem w comment i dowodem do zdobycia w reject" do
    gate!("partial", criteria_status: "unverifiable", trap_status: "addressed")
    drafts = DecisionDraft.new(@review).all
    assert_match(/\*\*Pytania do autora:\*\*\n- Kod dochodzi - jak to sprawdzić\? Potrzebne: log z SMSAPI/, drafts["comment"])
    assert_match(/\*\*Do wykazania\*\* \(kod tego nie rozstrzyga\):\n- Kod dochodzi - potrzebne: log z SMSAPI/, drafts["reject"])
    assert_match(/\*\*Niesprawdzone z kodu\*\* \(do potwierdzenia poza PR-em\):\n- Kod dochodzi - potrzebne: log z SMSAPI/, drafts["approve"])
    assert_no_match(/Log odczytany/, drafts["reject"])
    assert_equal "comment", DecisionDraft.new(@review).suggested_verdict
  end

  test "znaleziska z kodu: reject dzieli na blokujące i drobne, approve ma je jako nieblokujące, bramkowe pomija" do
    @review.findings.create!(priority: "minor", title: "Literówka", body: "x", file_location: "a.rb:1")
    @review.findings.create!(priority: "critical", title: "Nil w VAT", body: "x", file_location: "b.rb:2")
    @review.findings.create!(priority: "important", title: "Bez testu", body: "x")
    @review.findings.create!(priority: "critical", title: "AC niespełnione: Kod dochodzi", body: "x", source: "task_fit")
    drafts = DecisionDraft.new(@review).all
    assert_match(/\*\*Do poprawy:\*\*\n- \*\*\[critical\]\*\* Nil w VAT \(b.rb:2\)\n- \*\*\[important\]\*\* Bez testu\n\n\*\*Drobne\*\* \(opcjonalnie\):\n- \*\*\[minor\]\*\* Literówka \(a.rb:1\)/, drafts["reject"])
    assert_match(/\*\*Uwagi nieblokujące\*\* \(nie wstrzymują merge'a\):\n- \*\*\[critical\]\*\* Nil w VAT/, drafts["approve"])
    assert_match(/\*\*Uwagi do przemyślenia:\*\*\n- \*\*\[critical\]\*\* Nil w VAT/, drafts["comment"])
    drafts.each_value { |draft| assert_no_match(/AC niespełnione/, draft) }
    assert_equal "reject", DecisionDraft.new(@review).suggested_verdict
  end
end
