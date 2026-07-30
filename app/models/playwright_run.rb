class PlaywrightRun < ApplicationRecord
  MODES = %w[headed headless].freeze
  STATUSES = %w[running passed failed].freeze

  belongs_to :review

  validates :mode, inclusion: { in: MODES }
  validates :status, inclusion: { in: STATUSES }
end
