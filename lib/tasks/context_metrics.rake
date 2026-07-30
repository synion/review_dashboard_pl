namespace :context_metrics do
  desc "Uzupełnia metryki kontekstu sesji sprzed ich wprowadzenia (czyta logi z storage/reviews)"
  task backfill: :environment do
    filled = ContextMetricsBackfill.call
    puts "Uzupełniono metryki dla #{filled} sesji."
  end
end
