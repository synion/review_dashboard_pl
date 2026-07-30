# PR czekający na MOJE review — pozycja kolejki odtwarzanej z GitHuba. Nie ma nic
# wspólnego z Review: wpis istnieje także (a właściwie głównie) dla PR-ów, których
# w dashboardzie nikt jeszcze nie tknął.
class InboxItem < ApplicationRecord
  # Dwa jedyne powody, dla których PR trafia do kolejki. Oba znaczą „piłka u mnie":
  # GitHub poprosił mnie o review albo ktoś odezwał się po moim review.
  REASONS = %w[requested commented].freeze
  REASON_LABELS = { "requested" => "Prosi o Twoje review", "commented" => "Odezwał się po Twoim review" }.freeze

  belongs_to :project

  validates :pr_number, :url, presence: true
  validates :reason, inclusion: { in: REASONS }

  # Najpilniejsze na górze: najpierw prośby o review (tam nikt nie zna jeszcze mojego
  # zdania), w grupie — czekające najdłużej. Kolejność alfabetyczna reason dałaby
  # odwrotnie, stąd jawny CASE.
  scope :by_urgency, -> { order(Arel.sql("CASE reason WHEN 'requested' THEN 0 ELSE 1 END"), :signal_at) }

  def label = REASON_LABELS.fetch(reason, reason)
end
