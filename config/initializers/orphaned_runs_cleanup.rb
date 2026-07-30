# Po restarcie apki oznaczamy runy z martwymi procesami jako przerwane —
# user widzi „Ponów" zamiast wiecznego spinnera. Logika w OrphanedRunsCleanup.
Rails.application.config.after_initialize do
  next if Rails.env.test?

  begin
    OrphanedRunsCleanup.call
  rescue StandardError => e
    # Sprzątanie to higiena, nie warunek startu — niezmigrowana baza albo błąd
    # renderu broadcastu nie mogą blokować boota aplikacji.
    Rails.logger.warn("OrphanedRunsCleanup przy boocie nie powiódł się: #{e.class}: #{e.message}")
  end
end
