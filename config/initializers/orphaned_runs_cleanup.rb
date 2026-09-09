# Po restarcie apki oznaczamy runy z martwymi procesami jako przerwane —
# user widzi „Ponów" zamiast wiecznego spinnera. Logika w OrphanedRunsCleanup.
Rails.application.config.after_initialize do
  next if Rails.env.test?
  # Tylko proces serwera. `bin/rails runner` i konsola też bootują apkę, a review
  # w fazie tworzenia worktree (status describing, sesja Claude jeszcze nie istnieje)
  # wygląda dla sprzątania jak sierota po restarcie i dostawał „kliknij Ponów”
  # od zwykłego odczytu stanu z runnera.
  next unless defined?(Rails::Server)

  begin
    OrphanedRunsCleanup.call
  rescue StandardError => e
    # Sprzątanie to higiena, nie warunek startu — niezmigrowana baza albo błąd
    # renderu broadcastu nie mogą blokować boota aplikacji.
    Rails.logger.warn("OrphanedRunsCleanup przy boocie nie powiódł się: #{e.class}: #{e.message}")
  end
end
