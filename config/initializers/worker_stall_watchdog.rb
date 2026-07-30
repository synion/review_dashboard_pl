# Tylko worker wykonuje joby, więc tylko on ma co zaciąć — dispatcher i supervisor
# pomijamy. Hook rejestruje się przy boocie, a odpala w procesie workera po jego starcie.
SolidQueue.on_worker_start { WorkerStallWatchdog.start } if Rails.env.development?
