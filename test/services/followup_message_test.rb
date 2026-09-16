require "test_helper"

class FollowupMessageTest < ActiveSupport::TestCase
  setup do
    @review = reviews(:pr_review)
    @review.update!(status: "decided", summary: "OK", decided_at: Time.zone.parse("2026-09-03 13:51"))
    @review.findings.create!(priority: "critical", title: "Nil w VAT", body: "x", file_location: "a.rb:1")
    @review.findings.create!(priority: "minor", title: "Literówka", body: "x")
  end

  test "ponowne sprawdzenie po reject wylicza wymagane zmiany, po approve uwagi nieblokujące, po comment pytania" do
    @review.update!(decision: "reject")
    reject = FollowupMessage.new(@review).check_fixes
    assert_match(/\APo moim reject \(2026-09-03 13:51\)/, reject)
    assert_match(/Wymagane zmiany:\n- \*\*\[critical\]\*\* Nil w VAT \(a.rb:1\)\n\nDrobne \(opcjonalne\):\n- \*\*\[minor\]\*\* Literówka\z/, reject)

    @review.update!(decision: "approve")
    approve = FollowupMessage.new(@review).check_fixes
    assert_match(/\AZatwierdziłem PR \(2026-09-03 13:51\)/, approve)
    assert_match(/Uwagi nieblokujące z mojego review.*\n- \*\*\[critical\]\*\* Nil w VAT/, approve)

    @review.update!(decision: "comment")
    assert_match(/\AZadałem pytania bez werdyktu.*\n\nUwagi do przemyślenia:\n- \*\*\[critical\]\*\* Nil w VAT/m, FollowupMessage.new(@review).check_fixes)
  end

  test "podważenie: zdanie o źródle plus konfrontacja zależna od werdyktu" do
    @review.update!(decision: "approve", challenge: { "source" => "pr", "by" => "tomek" })
    pr = FollowupMessage.new(@review).challenge
    assert_match(/\AInny reviewer \(tomek\) zażądał zmian.*Cudze review pod PR-em”\. Skonfrontuj to z moim approve \(2026-09-03 13:51\)/, pr)
    assert_includes pr, "czy PR w ogóle rozwiązuje zgłoszenie"

    @review.update!(decision: "reject", task_url: "https://tasks.example.com/5", challenge: { "source" => "task", "count" => 5 })
    task = FollowupMessage.new(@review).challenge
    assert_match(/\AW zadaniu https:\/\/tasks.example.com\/5 pojawiły się nowe komentarze.*po 2026-09-03 13:51\. Skonfrontuj to z moimi wymaganiami zmian/, task)
    assert_match(/Moje wymagania:\n- \*\*\[critical\]\*\* Nil w VAT/, task)
  end

  test "własny szablon projektu i brak decyzji (traktowany jak reject)" do
    @review.update!(decision: nil)
    @review.project.update!(templates: { "followup" => { "reject" => "Sprawdź od nowa: {{findings_list}}" } })
    assert_equal "Sprawdź od nowa: - **[critical]** Nil w VAT (a.rb:1)\n- **[minor]** Literówka", FollowupMessage.new(@review).check_fixes
  end
end
