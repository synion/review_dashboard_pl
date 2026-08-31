require "test_helper"

class DiffParserTest < ActiveSupport::TestCase
  # Hunk z API GitHuba: linia 10 kontekst, 11 usunięta, po prawej 11-12 dodane,
  # dalej kontekst. Numery po obu stronach muszą się rozjechać dokładnie tak.
  PATCH = <<~PATCH.chomp
    @@ -10,4 +10,5 @@ class Invoice
       def total
    -    items.sum(&:price)
    +    return 0 if items.empty?
    +    items.sum(&:price)
       end
     end
  PATCH

  def hunk(patch = PATCH) = DiffParser.parse_patch(patch).sole

  test "numeruje linie osobno po lewej i po prawej stronie" do
    lines = hunk.lines
    assert_equal [ [ :context, 10, 10 ], [ :del, 11, nil ], [ :add, nil, 11 ], [ :add, nil, 12 ],
                   [ :context, 12, 13 ], [ :context, 13, 14 ] ],
                 lines.map { |l| [ l.kind, l.left, l.right ] }
  end

  test "treść linii zostaje bez znaku +/-" do
    assert_equal "    return 0 if items.empty?", hunk.lines[2].text
    assert_equal "  def total", hunk.lines.first.text
  end

  test "nagłówek hunka zostaje w całości — z nazwą sekcji" do
    assert_equal "@@ -10,4 +10,5 @@ class Invoice", hunk.header
  end

  test "nowy plik: hunk zaczyna się od linii 1 po prawej, lewa pusta" do
    patch = "@@ -0,0 +1,2 @@\n+class Nowy\n+end"
    assert_equal [ [ :add, nil, 1 ], [ :add, nil, 2 ] ],
                 hunk(patch).lines.map { |l| [ l.kind, l.left, l.right ] }
  end

  test "hunk bez liczby linii znaczy jedną linię" do
    patch = "@@ -5 +5 @@\n-a\n+b"
    assert_equal [ [ :del, 5, nil ], [ :add, nil, 5 ] ],
                 hunk(patch).lines.map { |l| [ l.kind, l.left, l.right ] }
  end

  test "„\\ No newline at end of file\" nie jest linią pliku" do
    patch = "@@ -1,1 +1,1 @@\n-a\n\\ No newline at end of file\n+b"
    assert_equal [ :del, :add ], hunk(patch).lines.map(&:kind)
  end

  test "kilka hunków w jednym patchu" do
    patch = "@@ -1,1 +1,1 @@\n-a\n+b\n@@ -10,1 +10,1 @@\n-c\n+d"
    hunks = DiffParser.parse_patch(patch)
    assert_equal 2, hunks.size
    assert_equal 10, hunks.last.lines.first.left
  end

  test "pusty patch nie daje hunków" do
    assert_empty DiffParser.parse_patch("")
    assert_empty DiffParser.parse_patch(nil)
  end

  # Usunięta linia „-- stary" ma w diffie postać „--- stary" i wygląda jak nagłówek
  # pliku. Licznik z nagłówka hunka pilnuje, żeby parser się na to nie nabrał.
  test "treść przypominająca nagłówek nie kończy hunka przedwcześnie" do
    diff = <<~DIFF
      diff --git a/app/x.rb b/app/x.rb
      --- a/app/x.rb
      +++ b/app/x.rb
      @@ -1,1 +1,1 @@
      --- stary komentarz
      +++ nowy komentarz
      diff --git a/app/y.rb b/app/y.rb
      --- a/app/y.rb
      +++ b/app/y.rb
      @@ -5,1 +5,1 @@
      -a
      +b
    DIFF
    files = DiffParser.parse(diff)
    assert_equal [ "app/x.rb", "app/y.rb" ], files.keys
    assert_equal [ "-- stary komentarz", "++ nowy komentarz" ], files["app/x.rb"].sole.lines.map(&:text)
    assert_equal 5, files["app/y.rb"].sole.lines.first.left
  end

  test "usunięty plik wypada z mapy pełnego diffu" do
    diff = <<~DIFF
      diff --git a/app/stary.rb b/app/stary.rb
      deleted file mode 100644
      --- a/app/stary.rb
      +++ /dev/null
      @@ -1,2 +0,0 @@
      -class Stary
      -end
    DIFF
    assert_empty DiffParser.parse(diff)
  end

  # Zmiana samych uprawnień albo czysty rename nie mają hunków, ale plik w diffie
  # jest — PrDiffMap rozwiązuje po nim ścieżkę, więc nie może zniknąć.
  test "plik bez hunków zostaje w mapie z pustą listą" do
    diff = <<~DIFF
      diff --git a/bin/setup b/bin/setup
      old mode 100644
      new mode 100755
      --- a/bin/setup
      +++ b/bin/setup
    DIFF
    assert_equal({ "bin/setup" => [] }, DiffParser.parse(diff))
  end

  test "pusty diff nie ma plików" do
    assert_empty DiffParser.parse("")
  end
end
