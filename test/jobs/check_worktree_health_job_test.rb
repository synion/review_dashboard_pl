require "test_helper"

class CheckWorktreeHealthJobTest < ActiveSupport::TestCase
  # Zaślepka WorktreeHealth: test nie może zależeć od tego, czy ktoś ma postawione
  # środowisko dev o tej nazwie.
  FakeHealth = Struct.new(:result, :urls) do
    def check(url)
      urls << url
      result
    end
  end

  setup do
    @review = reviews(:pr_review)
    @review.project.update!(worktree_url_template: "https://%{branch}.dev.example.test/")
    @review.update!(branch: "sl-fix-vat", worktree_path: Dir.tmpdir)
  end

  test "działające środowisko oznacza review jako ok" do
    health = FakeHealth.new(nil, [])

    CheckWorktreeHealthJob.perform_now(@review, health: health)

    assert_equal [ "https://sl-fix-vat.dev.example.test/" ], health.urls
    assert_equal "ok", @review.reload.worktree_health_status
    assert_nil @review.worktree_health_error
    assert @review.worktree_health_checked_at
  end

  # Ten przypadek jest powodem istnienia joba: skrypt worktree wyszedł z zerem,
  # a apka nie wstaje (urwany seed bazy, pełny wolumen kontenera).
  test "niedziałające środowisko ląduje jako ostrzeżenie w panelu" do
    CheckWorktreeHealthJob.perform_now(@review, health: FakeHealth.new("HTTP 500", []))

    assert_equal "failed", @review.reload.worktree_health_status
    assert_match(/HTTP 500/, @review.worktree_health_error)
    assert @review.worktree_health_failed?
  end

  # Review bez własnego worktree albo projekt bez wzorca adresu nie ma czego sprawdzać —
  # job ma wtedy milczeć, a nie zapisywać „failed".
  test "bez adresu środowiska job nic nie zapisuje" do
    @review.project.update!(worktree_url_template: nil)
    health = FakeHealth.new("nie powinno się wydarzyć", [])

    CheckWorktreeHealthJob.perform_now(@review, health: health)

    assert_empty health.urls
    assert_nil @review.reload.worktree_health_status
  end

  # Ostrzeżenie ma znikać razem z worktree: po jego usunięciu nie ma czego naprawiać.
  test "ostrzeżenie gaśnie, gdy katalog worktree zniknął" do
    @review.record_worktree_health("HTTP 500")
    assert @review.worktree_health_failed?

    @review.update!(worktree_path: File.join(Dir.tmpdir, "nie-ma-mnie-#{@review.id}"))

    assert_not @review.worktree_health_failed?
  end
end
