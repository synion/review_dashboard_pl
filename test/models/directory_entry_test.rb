require "test_helper"

class DirectoryEntryTest < ActiveSupport::TestCase
  setup do
    @project = projects(:webapp)
  end

  test "replace! wstawia nowe wpisy z refreshed_at" do
    DirectoryEntry.replace!(@project, "gh_label", [ { external_id: "bug", name: "bug" },
                                                    { external_id: "wip", name: "wip" } ])

    entries = @project.directory_entries.where(kind: "gh_label")
    assert_equal %w[bug wip], entries.order(:name).pluck(:name)
    assert entries.all? { |e| e.refreshed_at.present? }
  end

  test "replace! aktualizuje nazwę po external_id i kasuje zniknięte" do
    DirectoryEntry.replace!(@project, "intum_user", [ { external_id: "7", name: "Stare Nazwisko" },
                                                      { external_id: "8", name: "Znika" } ])
    DirectoryEntry.replace!(@project, "intum_user", [ { external_id: "7", name: "Nowe Nazwisko" } ])

    entries = @project.directory_entries.where(kind: "intum_user")
    assert_equal [ %w[7 Nowe\ Nazwisko] ], entries.pluck(:external_id, :name)
  end

  test "replace! nie tyka wpisów innego kind ani innego projektu" do
    other = projects(:dashboard)
    DirectoryEntry.replace!(@project, "gh_label", [ { external_id: "bug", name: "bug" } ])
    DirectoryEntry.replace!(other, "gh_label", [ { external_id: "cudzy", name: "cudzy" } ])

    DirectoryEntry.replace!(@project, "gh_collaborator", [ { external_id: "anna", name: "anna" } ])

    assert_equal 1, @project.directory_entries.where(kind: "gh_label").count
    assert_equal 1, other.directory_entries.where(kind: "gh_label").count
  end

  test "search filtruje po fragmencie nazwy bez rozróżniania wielkości liter" do
    DirectoryEntry.replace!(@project, "intum_user", [ { external_id: "1", name: "Anna Kowalska" },
                                                      { external_id: "2", name: "Jan Nowak" } ])

    assert_equal [ "Anna Kowalska" ], DirectoryEntry.search(@project, "intum_user", "kowal").pluck(:name)
    assert_equal [ "Anna Kowalska" ], DirectoryEntry.search(@project, "intum_user", "ANNA").pluck(:name)
    assert_equal [ "Anna Kowalska", "Jan Nowak" ], DirectoryEntry.search(@project, "intum_user", "").pluck(:name)
  end

  test "kind? rozpoznaje znane kindy" do
    assert DirectoryEntry.kind?("gh_label")
    assert_not DirectoryEntry.kind?("wrong")
  end
end
