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

  test "bez bramki i znalezisk: nagłówek z werdyktem, „Krótko” i zdanie otwierające werdyktu" do
    drafts = DecisionDraft.new(@review).all
    assert_equal "## ✅ Approve\n\nZmiana wygląda dobrze.\n\n**Zatwierdzam - nie wstrzymuję merge'a.**\n", drafts["approve"]
    assert_equal "## ❌ Reject - wymagane zmiany\n\nZmiana wygląda dobrze.\n\n**Proszę o zmiany przed merge'em.**\n", drafts["reject"]
    assert_match(/\A## 💬 Comment - pytania przed decyzją\n\nZmiana wygląda dobrze.\n\n\*\*Bez werdyktu/, drafts["comment"])
    assert_equal "approve", DecisionDraft.new(@review).suggested_verdict
  end

  test "długie podsumowanie: „Krótko” na górze, reszta zwinięta na końcu, po sekcjach werdyktu" do
    @review.update!(summary: "**Krótko:** Nie approve'uj.\n\n**Co sprawdziłem**\n- migracje\n\n**Najważniejsze**\n- limit firm")
    @review.findings.create!(priority: "critical", title: "Nil w VAT", body: "x")
    reject = DecisionDraft.new(@review).for("reject")
    assert_equal <<~MD, reject
      ## ❌ Reject - wymagane zmiany

      **Krótko:** Nie approve'uj.

      **Proszę o zmiany przed merge'em.**

      **Do poprawy:**
      - **[critical]** Nil w VAT

      <details><summary>Pełne podsumowanie review</summary>

      **Krótko:** Nie approve'uj.

      **Co sprawdziłem**
      - migracje

      **Najważniejsze**
      - limit firm

      </details>
    MD
  end

  test "misses: reject wylicza niespełnione punkty, approve bierze je na siebie, comment pyta o zakres" do
    gate!("misses", criteria_status: "unmet", trap_status: "open")
    drafts = DecisionDraft.new(@review).all
    assert_match(/\*\*Niespełnione punkty z zadania:\*\*\n- Kod dochodzi \(brak logu\)\n- Log odczytany\? \(komentarz 3\)/, drafts["reject"])
    assert_match(/\*\*Świadomie mimo niespełnionych punktów z zadania:\*\*\n- Kod dochodzi \(brak logu\)/, drafts["approve"])
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


  # ---- Szablony per projekt.

  test "własny szablon projektu zastępuje domyślny, a puste bloki znikają z nagłówkiem" do
    @review.findings.create!(priority: "minor", title: "Literówka", body: "x", file_location: "a.rb:1")
    @review.project.update!(templates: { "decision" => { "reject" => <<~M } })
      Cześć! {{summary}}
      {{#blocking_list}}
      Brakuje:
      {{blocking_list}}
      {{/blocking_list}}
      {{#minor_findings_list}}
      Drobiazgi:
      {{minor_findings_list}}
      {{/minor_findings_list}}
      PR: {{pr_title}} / {{branch}}
    M
    @review.update!(pr_title: "Fix & VAT", branch: "b")
    drafts = DecisionDraft.new(@review).all
    assert_equal "Cześć! Zmiana wygląda dobrze.\nDrobiazgi:\n- **[minor]** Literówka (a.rb:1)\nPR: Fix & VAT / b\n", drafts["reject"]
    assert_match(/\A## ✅ Approve\n\nZmiana wygląda dobrze.\n/, drafts["approve"], "approve zostaje domyślny")
  end

  test "każda nazwa z podpowiedzi formularza ma wartość w kontekście i odwrotnie" do
    assert_equal DecisionDraft::PLACEHOLDERS.keys, DecisionDraft.new(@review).placeholders.keys.map(&:to_s)
  end

  test "szablon nie escapuje markdownu i nie czyta partiali z dysku" do
    @review.project.update!(templates: { "decision" => { "comment" => "{{summary}} & {{> Gemfile}}<b>" } })
    @review.update!(summary: "a > b")
    assert_equal "a > b & <b>\n", DecisionDraft.new(@review).for("comment")
  end

  test "zepsuty szablon zapisany poza walidacją degraduje do domyślnego" do
    @review.project.update_columns(templates: { "decision" => { "approve" => "{{#otwarty}} bez końca" } })
    assert_equal "## ✅ Approve\n\nZmiana wygląda dobrze.\n\n**Zatwierdzam - nie wstrzymuję merge'a.**\n", DecisionDraft.new(@review).for("approve")
  end
end
