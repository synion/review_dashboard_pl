require "test_helper"

class PrDiffMapTest < ActiveSupport::TestCase
  # Hunk: linia 10 kontekst, 11 usunięta (bez numeru po prawej), 11-12 dodane,
  # 13-14 kontekst. Po prawej stronie komentowalne są 10..14.
  DIFF = <<~DIFF
    diff --git a/app/models/invoice.rb b/app/models/invoice.rb
    index 1111111..2222222 100644
    --- a/app/models/invoice.rb
    +++ b/app/models/invoice.rb
    @@ -10,4 +10,5 @@ class Invoice
       def total
    -    items.sum(&:price)
    +    return 0 if items.empty?
    +    items.sum(&:price)
       end
     end
  DIFF

  def map(diff = DIFF) = PrDiffMap.parse(diff)

  test "linie kontekstowe i dodane są komentowalne" do
    assert map.commentable?("app/models/invoice.rb", 10)
    assert map.commentable?("app/models/invoice.rb", 12)
    assert map.commentable?("app/models/invoice.rb", 14)
  end

  test "linie spoza hunka nie są komentowalne" do
    assert_not map.commentable?("app/models/invoice.rb", 9)
    assert_not map.commentable?("app/models/invoice.rb", 15)
  end

  test "plik spoza diffu nie jest komentowalny" do
    assert_not map.commentable?("app/models/user.rb", 10)
    assert_nil map.resolve("app/models/user.rb")
  end

  test "ścieżka rozpoznawana po unikalnym sufiksie" do
    assert_equal "app/models/invoice.rb", map.resolve("models/invoice.rb")
    assert_equal "app/models/invoice.rb", map.resolve("invoice.rb")
  end

  test "sufiks pasujący do wielu plików jest odrzucany" do
    diff = <<~DIFF
      diff --git a/app/a/x.rb b/app/a/x.rb
      --- a/app/a/x.rb
      +++ b/app/a/x.rb
      @@ -1 +1 @@
      -stare
      +nowe
      diff --git a/app/b/x.rb b/app/b/x.rb
      --- a/app/b/x.rb
      +++ b/app/b/x.rb
      @@ -1 +1 @@
      -stare
      +nowe
    DIFF
    assert_nil map(diff).resolve("x.rb")
    assert_equal "app/a/x.rb", map(diff).resolve("app/a/x.rb")
  end

  test "nowy plik: wszystkie linie komentowalne" do
    diff = <<~DIFF
      diff --git a/app/services/nowy.rb b/app/services/nowy.rb
      new file mode 100644
      --- /dev/null
      +++ b/app/services/nowy.rb
      @@ -0,0 +1,3 @@
      +class Nowy
      +end
      +# koniec
    DIFF
    assert map(diff).commentable?("app/services/nowy.rb", 1)
    assert map(diff).commentable?("app/services/nowy.rb", 3)
    assert_not map(diff).commentable?("app/services/nowy.rb", 4)
  end

  test "usunięty plik wypada z mapy" do
    diff = <<~DIFF
      diff --git a/app/stary.rb b/app/stary.rb
      deleted file mode 100644
      --- a/app/stary.rb
      +++ /dev/null
      @@ -1,2 +0,0 @@
      -class Stary
      -end
    DIFF
    assert_nil map(diff).resolve("app/stary.rb")
  end

  # Treść usuniętej linii zaczynającej się od „--" wygląda jak nagłówek diffu.
  # Parser liczy linie z hunk headera, więc nie daje się na to nabrać.
  test "treść przypominająca nagłówek nie rozwala parsowania" do
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
    assert map(diff).commentable?("app/x.rb", 1)
    assert map(diff).commentable?("app/y.rb", 5)
    assert_not map(diff).commentable?("app/y.rb", 1)
  end

  test "pusty diff nie ma nic komentowalnego" do
    assert_not map("").commentable?("app/x.rb", 1)
  end
end
