require "test_helper"

class AutostartAgentTest < ActiveSupport::TestCase
  def agent(**overrides)
    AutostartAgent.new(**{ root: "/repo/review_dashboard", port: 3020,
                           ruby_bin_dir: "/Users/dev/.rbenv/shims" }.merge(overrides))
  end

  # Najczęstsza przyczyna agenta, który wstaje i natychmiast umiera: `bin/rails` nie
  # znajduje ruby, bo launchd startuje z gołym PATH-em.
  test "should put the ruby of this installation first in PATH" do
    assert_match(%r{\A/Users/dev/\.rbenv/shims:}, agent.env["PATH"])
  end

  # bin/dev ustawia SOLID_QUEUE_IN_PUMA samo, a launchd startuje bin/rails server
  # wprost — bez tej zmiennej apka wstaje bez workerów i żadne review nie startuje.
  test "should always run the job workers in Puma" do
    assert_equal "1", agent.env["SOLID_QUEUE_IN_PUMA"]
  end

  test "should carry the port into the environment and the plist" do
    assert_equal "3020", agent.env["PORT"]
    assert_includes agent.plist, "<string>3020</string>"
  end

  # Odświeżanie kolejki w tle jest opcją instalacji, nie wartością domyślną.
  test "should leave the inbox schedule off unless asked for it" do
    assert_nil agent.env["INBOX_SCHEDULE"]
    assert_equal "1", agent(inbox_schedule: true).env["INBOX_SCHEDULE"]
  end

  test "should skip the reviewer login when gh knows nothing" do
    assert_nil agent(reviewer_login: "").env["GITHUB_REVIEWER_LOGIN"]
    assert_equal "kolega", agent(reviewer_login: "kolega").env["GITHUB_REVIEWER_LOGIN"]
  end

  test "should start the app from the repo it was installed from" do
    plist = agent.plist

    assert_includes plist, "<string>/repo/review_dashboard/bin/rails</string>"
    assert_includes plist, "<key>WorkingDirectory</key>\n\t<string>/repo/review_dashboard</string>"
    assert_includes plist, "/repo/review_dashboard/log/autostart.err.log"
  end

  test "should keep the app alive and start it at login" do
    assert_includes agent.plist, "<key>RunAtLoad</key>\n\t<true/>"
    assert_includes agent.plist, "<key>KeepAlive</key>\n\t<true/>"
  end

  test "should live in the user LaunchAgents directory" do
    assert_equal File.join(Dir.home, "Library/LaunchAgents/com.review-dashboard.plist"),
                 agent.plist_path
  end
end
