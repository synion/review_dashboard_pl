require "test_helper"

class RefreshAllInboxesJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @with_repo = projects(:webapp)
    @without_repo = projects(:dashboard)
    @without_repo.update_columns(repo_url: nil)
  end

  test "should queue a refresh for every stale project with a repo" do
    Project.update_all(inbox_checked_at: nil)

    assert_enqueued_with job: RefreshInboxJob, args: [ @with_repo ] do
      RefreshAllInboxesJob.perform_now
    end
    assert_enqueued_jobs 1, only: RefreshInboxJob
  end

  # Wejście na stronę odświeża po swojemu, więc tik minutę później nie ma o co pytać
  # GitHuba drugi raz.
  test "should leave a freshly checked queue alone" do
    Project.update_all(inbox_checked_at: Time.current)

    assert_no_enqueued_jobs only: RefreshInboxJob do
      RefreshAllInboxesJob.perform_now
    end
  end

  # Harmonogram tika równo co STALE_AFTER, a fetch kończy się kilka sekund po tiku —
  # bez marginesu następny tik uznawałby kolejkę za świeżą i pytał dopiero za 20 minut.
  test "should refresh a queue checked just under the interval" do
    Project.update_all(inbox_checked_at: (GithubInbox::STALE_AFTER - 30.seconds).ago)

    assert_enqueued_with job: RefreshInboxJob, args: [ @with_repo ] do
      RefreshAllInboxesJob.perform_now
    end
  end

  test "should skip archived projects" do
    @with_repo.update!(archived_at: Time.current, inbox_checked_at: nil)

    assert_no_enqueued_jobs only: RefreshInboxJob do
      RefreshAllInboxesJob.perform_now
    end
  end

  # Harmonogram jest kontraktem z Solid Queue, nie komentarzem: literówka w nazwie
  # klasy albo brak wpisu dla środowiska znaczy, że kolejka po cichu przestaje się
  # odświeżać bez wchodzenia na stronę.
  test "should be scheduled outside the test environment" do
    schedule = YAML.load_file(Rails.root.join("config", "recurring.yml"), aliases: true)

    [ "development", "production" ].each do |env|
      task = schedule.fetch(env).fetch("refresh_review_inbox")
      assert_equal "RefreshAllInboxesJob", task["class"], "#{env}: zła klasa joba"
      assert_equal "every 10 minutes", task["schedule"],
                   "interwał harmonogramu ma trzymać się GithubInbox::STALE_AFTER"
    end
    assert_nil schedule["test"], "harmonogram w testach dorzucałby joby w tle"
  end
end
