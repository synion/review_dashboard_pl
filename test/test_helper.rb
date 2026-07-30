ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"

module ActiveSupport
  class TestCase
    # Bez równoległości: testy piszą do wspólnego storage/reviews/<fixture_id>
    # i równoległe workery kasowałyby sobie nawzajem artefakty.
    parallelize(workers: 1)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Podmiana repo_path na tmpdir unieważnia komendy worktree z fixture —
    # skrypt nie istnieje w nowym katalogu, więc walidacja istnienia pliku
    # wykonywalnego odrzuciłaby zapis. Helper ustawia komendy przechodzące.
    def relocate_repo!(project, dir)
      project.update!(repo_path: dir,
                      worktree_command: "git worktree add ../%{branch} %{branch}",
                      worktree_delete_command: nil)
    end
  end
end
