# Kolejki strony wejściowej muszą zmieniać się same: PR-y wpadają do „Czeka na
# Twoje review" z odświeżenia GitHuba w tle, a review przechodzą do „W toku"
# z jobów — obie zmiany dzieją się bez żadnego kliknięcia w tej karcie.
#
# method: :morph, nie zwykły replace: morph rusza tylko te kafle, które faktycznie
# się zmieniły. Dzięki temu (a) nie mruga cała lista przy każdym sygnale,
# (b) animacja wejścia odpala się WYŁĄCZNIE na nowych kaflach, bo tylko one są
# nowymi węzłami DOM — patrz queue_animation_controller.js.
class BroadcastDashboardJob < ApplicationJob
  # Zbiorczy strumień strony wejściowej — kolejki pokazują projekt główny, który
  # jest ustawieniem globalnym, więc każdy otwarty dashboard chce tego samego.
  STREAM = :dashboard

  def perform
    dashboard = Dashboard.new
    replace("queues", "projects/queues", dashboard)
    # Piguły u góry liczą to samo co kolejki — bez nich licznik „4 czeka" kłamałby
    # do pierwszego przeładowania strony.
    replace("summary", "projects/summary", dashboard)
  rescue StandardError => e
    # Broadcast to kosmetyka (odświeżenie strony pokaże stan) — jego błąd nie może
    # wywracać kolejki jobów ani powtarzać się w nieskończoność.
    Rails.logger.warn("BroadcastDashboardJob nie powiódł się: #{e.class}: #{e.message}")
  end

  private

  def replace(target, partial, dashboard)
    Turbo::StreamsChannel.broadcast_replace_to(STREAM, target: target, partial: partial,
                                               locals: { dashboard: dashboard },
                                               attributes: { method: :morph })
  end
end
