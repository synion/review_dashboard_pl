class ApplicationJob < ActiveJob::Base
  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError

  # Domyślna fabryka sesji Claude — wspólna dla jobów odpalających ClaudeSessionRunner,
  # testy podmieniają ją przez keyword argument session_factory:.
  def default_session_factory
    ->(run) { ClaudeSessionRunner.new(run) }
  end
end
