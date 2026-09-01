ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"

# Zaślepki dzielone przez kilka testów (np. FakeGithubClient) — Rails nie autoloaduje
# katalogu testowego, więc wciągamy je raz tutaj.
Dir[Rails.root.join("test/support/**/*.rb")].each { |path| require path }

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
