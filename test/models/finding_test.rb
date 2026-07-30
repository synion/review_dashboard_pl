require "test_helper"

class FindingTest < ActiveSupport::TestCase
  def location(file_location)
    finding = Finding.new(file_location: file_location)
    [ finding.location_path, finding.location_lines ]
  end

  test "ścieżka z pojedynczą linią" do
    assert_equal [ "app/models/invoice.rb", 214..214 ], location("app/models/invoice.rb:214")
  end

  test "zakres linii" do
    assert_equal [ "app/models/invoice.rb", 12..20 ], location("app/models/invoice.rb:12-20")
  end

  test "sama ścieżka bez linii" do
    assert_equal [ "app/models/invoice.rb", nil ], location("app/models/invoice.rb")
  end

  test "brak lokalizacji" do
    assert_equal [ nil, nil ], location(nil)
    assert_equal [ nil, nil ], location("  ")
  end

  # Model lubi dopisać „./" albo spacje wokół — GitHub oczekuje ścieżki od korzenia repo.
  test "obcina prefiks ./ i białe znaki" do
    assert_equal [ "app/models/invoice.rb", 8..8 ], location("  ./app/models/invoice.rb:8  ")
  end

  # Odwrócony zakres to błąd modelu, nie powód do wywalenia publikacji — bierzemy
  # samą pierwszą linię, bo GitHub wymaga start_line < line.
  test "odwrócony zakres degeneruje się do pierwszej linii" do
    assert_equal [ "app/x.rb", 20..20 ], location("app/x.rb:20-12")
  end

  test "ogon po numerze linii nie jest częścią ścieżki" do
    assert_equal [ "app/x.rb", 42..42 ], location("app/x.rb:42 (metoda #call)")
  end
end
