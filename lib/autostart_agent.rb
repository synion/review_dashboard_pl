# Generuje definicję agenta launchd, który trzyma dashboard uruchomiony w tle.
# Osobna klasa, a nie heredoc w skrypcie: to jedyna część autostartu, którą da się
# przetestować bez ruszania launchctl na maszynie CI.
#
# Wszystkie ścieżki i wartości są WYLICZANE ze środowiska instalacji (katalog repo,
# `ruby` z PATH, login z `gh`), bo plist z cudzej maszyny to najczęstsza przyczyna
# agenta, który wstaje i natychmiast umiera.
class AutostartAgent
  LABEL = "com.review-dashboard"

  def initialize(root:, port:, ruby_bin_dir:, reviewer_login: nil, inbox_schedule: false)
    @root = root
    @port = port
    @ruby_bin_dir = ruby_bin_dir
    @reviewer_login = reviewer_login
    @inbox_schedule = inbox_schedule
  end

  def plist_path = File.join(Dir.home, "Library", "LaunchAgents", "#{LABEL}.plist")

  # SOLID_QUEUE_IN_PUMA=1 jest tu obowiązkowe: `bin/dev` ustawia je samo, a launchd
  # startuje `bin/rails server` wprost — bez tego apka wstaje BEZ workerów i żadne
  # review nigdy nie startuje (najczęstszy błąd z sekcji „Problemy" w README).
  def env
    {
      "HOME" => Dir.home,
      "PATH" => [ @ruby_bin_dir, "/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin" ].compact.join(":"),
      "PORT" => @port.to_s,
      "SOLID_QUEUE_IN_PUMA" => "1",
      "RAILS_ENV" => "development"
    }.merge(@reviewer_login.to_s.empty? ? {} : { "GITHUB_REVIEWER_LOGIN" => @reviewer_login })
     .merge(@inbox_schedule ? { "INBOX_SCHEDULE" => "1" } : {})
  end

  def plist
    <<~PLIST
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
      \t<key>Label</key>
      \t<string>#{LABEL}</string>
      \t<key>EnvironmentVariables</key>
      \t<dict>
      #{env.map { |key, value| "\t\t<key>#{key}</key>\n\t\t<string>#{value}</string>" }.join("\n")}
      \t</dict>
      \t<key>ProgramArguments</key>
      \t<array>
      \t\t<string>#{File.join(@root, "bin", "rails")}</string>
      \t\t<string>server</string>
      \t\t<string>-b</string>
      \t\t<string>127.0.0.1</string>
      \t</array>
      \t<key>WorkingDirectory</key>
      \t<string>#{@root}</string>
      \t<key>RunAtLoad</key>
      \t<true/>
      \t<key>KeepAlive</key>
      \t<true/>
      \t<key>StandardOutPath</key>
      \t<string>#{File.join(@root, "log", "autostart.out.log")}</string>
      \t<key>StandardErrorPath</key>
      \t<string>#{File.join(@root, "log", "autostart.err.log")}</string>
      </dict>
      </plist>
    PLIST
  end
end
