require "test_helper"

class DescribeTaskJobTest < ActiveSupport::TestCase
  class FakeSession
    def initialize(text) = @text = text
    def call(_prompt) = @text
  end

  def run_with(review, text)
    DescribeTaskJob.perform_now(review, session_factory: ->(_run) { FakeSession.new(text) })
    review.reload
  end

  test "zapisuje opis bez linii TASK_URL i status ready" do
    review = run_with(reviews(:task_only), "TASK_URL: https://tasks.example.com/555\n\n**Cel** — działa.")
    assert_equal "ready", review.task_description_status
    assert_equal "**Cel** — działa.", review.task_description
    assert_equal [ "describe_task" ], review.claude_runs.map(&:kind)
  end

  test "uzupełnia pusty task_url adresem znalezionym w PR" do
    review = run_with(reviews(:pr_review), "TASK_URL: https://tasks.example.com/999\n\n**Cel** — x.")
    assert_equal "https://tasks.example.com/999", review.task_url
  end

  test "nie nadpisuje istniejącego task_url" do
    review = run_with(reviews(:task_only), "TASK_URL: https://tasks.example.com/INNE\n\n**Cel** — x.")
    assert_equal "https://tasks.example.com/555", review.task_url
  end

  test "TASK_URL: none zostawia task_url pusty, opis zapisany" do
    review = run_with(reviews(:pr_review), "TASK_URL: none\n\nNie znaleziono linku do zadania w opisie PR.")
    assert_nil review.task_url
    assert_includes review.task_description, "Nie znaleziono"
    assert_equal "ready", review.task_description_status
  end

  test "sukces to jeden zapis — bez pośredniego broadcastu z samym task_url" do
    review = reviews(:pr_review)
    updates = 0
    callback = ->(*) { updates += 1 }
    Review.set_callback(:update, :after, callback)
    begin
      run_with(review, "TASK_URL: https://tasks.example.com/999\n\n**Cel** — x.")
    ensure
      Review.skip_callback(:update, :after, callback)
    end
    # running + finalny zapis (opis + url razem) — nie trzy.
    assert_equal 2, updates
  end

  test "brak linii TASK_URL: cała odpowiedź jako opis (miękka degradacja)" do
    review = run_with(reviews(:task_only), "**Cel** — bez nagłówka kontraktu.")
    assert_equal "**Cel** — bez nagłówka kontraktu.", review.task_description
    assert_equal "ready", review.task_description_status
  end

  test "błąd sesji: status failed, stary opis nietknięty, review.status nietknięty" do
    review = reviews(:task_only)
    review.update!(task_description: "DOBRY STARY OPIS", task_description_status: "ready")
    failing = ->(_run) { raise ClaudeSessionRunner::Failed, "sesja padła" }
    DescribeTaskJob.perform_now(review, session_factory: failing)
    review.reload
    assert_equal "failed", review.task_description_status
    assert_equal "DOBRY STARY OPIS", review.task_description, "błąd odświeżania nie może zamazać dobrego opisu"
    assert_equal "created", review.status
  end

  # Sesja pisze plik obok odpowiedzi tekstowej - lista AC ma być danymi, nie prozą.
  test "czyta task_criteria.json i zapisuje listę AC razem z opisem" do
    review = reviews(:task_only)
    FileUtils.mkdir_p(review.artifacts_dir)
    writing = ->(_run) {
      Object.new.tap do |session|
        session.define_singleton_method(:call) do |_prompt|
          review.artifacts_dir.join("task_criteria.json").write(
            { criteria: [ { id: "ac1", text: "Kod dochodzi" } ], traps: [ { id: "t1", text: "Log?" } ],
              process: [ { id: "p1", text: "Figma" } ] }.to_json
          )
          "TASK_URL: https://tasks.example.com/555\n\n**Cel** — x."
        end
      end
    }
    DescribeTaskJob.perform_now(review, session_factory: writing)
    review.reload
    assert_equal "**Cel** — x.", review.task_description
    assert_equal [ "ac1", "t1", "p1" ], review.task_criteria_list.map { |c| c["id"] }
    assert_equal %w[criterion trap process], review.task_criteria_list.map { |c| c["kind"] }
  ensure
    FileUtils.rm_rf(review.artifacts_dir)
  end

  test "brak task_criteria.json zostawia listę AC pustą (miękka degradacja)" do
    review = run_with(reviews(:task_only), "TASK_URL: none\n\n**Cel** — x.")
    assert_nil review.task_criteria
    assert_equal "ready", review.task_description_status
  end

  # Nowa lista AC unieważnia stary werdykt: statusy odnosiły się do innych id.
  test "zmieniona lista AC zeruje wynik zgodności z zadaniem" do
    review = reviews(:task_only)
    review.update!(task_criteria: { "criteria" => [ { "id" => "ac1", "text" => "stare" } ] },
                   task_fit: { "verdict" => "fits" }, task_fit_status: "ready")
    FileUtils.mkdir_p(review.artifacts_dir)
    review.artifacts_dir.join("task_criteria.json").write({ criteria: [ { id: "ac1", text: "nowe" } ], traps: [], process: [] }.to_json)
    run_with(review, "TASK_URL: none\n\n**Cel** — x.")
    assert_nil review.task_fit
    assert_equal "skipped", review.task_fit_status
  ensure
    FileUtils.rm_rf(review.artifacts_dir)
  end

  test "zepsuty task_criteria.json nie wywraca opisu" do
    review = reviews(:task_only)
    FileUtils.mkdir_p(review.artifacts_dir)
    review.artifacts_dir.join("task_criteria.json").write("{ nie json")
    run_with(review, "TASK_URL: none\n\n**Cel** — x.")
    assert_equal "ready", review.task_description_status
    assert_nil review.task_criteria
  ensure
    FileUtils.rm_rf(review.artifacts_dir)
  end
end
