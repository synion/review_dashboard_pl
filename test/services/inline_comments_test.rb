require "test_helper"

class InlineCommentsTest < ActiveSupport::TestCase
  # Nowy plik o 20 liniach — wszystkie komentowalne. Prawdziwa mapa zamiast stuba,
  # bo to właśnie na styku „co model podał" ↔ „co jest w diffie" rodzą się błędy.
  DIFF = <<~HEAD + (1..20).map { |i| "+linia #{i}" }.join("\n") + "\n"
    diff --git a/app/models/invoice.rb b/app/models/invoice.rb
    --- /dev/null
    +++ b/app/models/invoice.rb
    @@ -0,0 +1,20 @@
  HEAD

  def diff_map = PrDiffMap.parse(DIFF)

  def finding(priority: "critical", title: "Nil w kalkulacji VAT", body: "**Problem:** nil", file: "app/models/invoice.rb:5")
    Finding.new(priority: priority, title: title, body: body, file_location: file)
  end

  def build(*findings) = InlineComments.build(findings, diff_map)

  test "znalezisko z linią w diffie dostaje komentarz przypięty do linii" do
    assert_equal [ { path: "app/models/invoice.rb", line: 5, side: "RIGHT",
                     body: "🔴 **Krytyczne — Nil w kalkulacji VAT**\n\n**Problem:** nil" } ],
                 build(finding)
  end

  test "zakres linii daje komentarz wielolinijkowy" do
    comment = build(finding(file: "app/models/invoice.rb:5-9")).sole
    assert_equal({ start_line: 5, start_side: "RIGHT", line: 9, side: "RIGHT" },
                 comment.slice(:start_line, :start_side, :line, :side))
  end

  # Diff z dziurą: komentowalne 1-3 i 21-22, między nimi nic.
  GAPPED = <<~DIFF
    diff --git a/app/x.rb b/app/x.rb
    --- a/app/x.rb
    +++ b/app/x.rb
    @@ -1,2 +1,3 @@
     a
     b
    +c
    @@ -20,2 +21,2 @@
     t
     u
  DIFF

  test "zakres z dziurą w diffie zwija się do jednej pinezki na ostatniej linii" do
    comment = InlineComments.build([ finding(file: "app/x.rb:1-21") ], PrDiffMap.parse(GAPPED)).sole
    assert_equal 21, comment[:line]
    assert_nil comment[:start_line]
  end

  # Nie zgadujemy, którą linię autor miał na myśli — pinezka spada, treść zostaje
  # w liście zbiorczej. Zmyślony kotwiczny numer myliłby bardziej niż jego brak.
  test "zakres kończący się poza diffem nie dostaje pinezki" do
    assert_empty build(finding(file: "app/models/invoice.rb:18-25"))
  end

  test "ścieżka podana skrótowo trafia do payloadu w pełnej postaci z diffu" do
    assert_equal "app/models/invoice.rb", build(finding(file: "models/invoice.rb:5")).sole[:path]
  end

  test "nagłówek komentarza niesie priorytet" do
    bodies = %w[critical important minor].map { |p| build(finding(priority: p)).sole[:body].lines.first.chomp }
    assert_equal [ "🔴 **Krytyczne — Nil w kalkulacji VAT**",
                   "🟠 **Ważne — Nil w kalkulacji VAT**",
                   "⚪ **Drobne — Nil w kalkulacji VAT**" ], bodies
  end

  test "pomija znalezisko bez lokalizacji" do
    assert_empty build(finding(file: nil))
    assert_empty build(finding(file: "app/models/invoice.rb"))
  end

  test "pomija linię spoza diffu i nieznany plik" do
    assert_empty build(finding(file: "app/models/invoice.rb:99"))
    assert_empty build(finding(file: "app/models/user.rb:5"))
  end

  test "przepuszcza to, co da się przypiąć, i milczy o reszcie" do
    comments = build(finding(file: "app/models/invoice.rb:5"), finding(file: "app/models/user.rb:5"))
    assert_equal [ 5 ], comments.map { |c| c[:line] }
  end
end
