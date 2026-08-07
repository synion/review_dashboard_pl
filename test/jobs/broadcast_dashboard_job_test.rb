require "test_helper"

class BroadcastDashboardJobTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  setup do
    @project = projects(:webapp)
    @project.make_main!
  end

  # Kolejki i piguły liczą to samo — bez drugiego broadcastu licznik „czeka"
  # kłamałby aż do przeładowania strony.
  test "rozgłasza kolejki i piguły na wspólny strumień strony wejściowej" do
    BroadcastDashboardJob.perform_now

    assert_match %r{target="queues"}, stream.join
    assert_match %r{target="summary"}, stream.join
  end

  # Morph rusza tylko te kafle, które faktycznie się zmieniły. Bez tego cała lista
  # powstawałaby od nowa przy każdym sygnale — i animacja wejścia odpalałaby się
  # na wszystkim naraz.
  test "podmiana idzie morphem" do
    BroadcastDashboardJob.perform_now

    assert stream.all? { |message| message.include?('method="morph"') }, stream.inspect
  end

  test "kolejka niesie kafel review czekającego na moją decyzję" do
    review = reviews(:pr_review)
    review.update!(status: "reviewed")

    BroadcastDashboardJob.perform_now

    assert_match %r{id="review_queue_#{review.id}"}, stream.join
  end

  # Broadcast to kosmetyka — jego błąd nie może wywracać kolejki jobów, bo przechodzi
  # przez nią każdy zapis review i każdy run.
  test "błąd renderu nie wywraca joba" do
    Dashboard.stub :new, ->(*) { raise "render boom" } do
      assert_nothing_raised { BroadcastDashboardJob.perform_now }
    end
  end

  private

  # ActionCable trzyma na szynie zakodowane wiadomości — bez dekodowania każdy
  # znak `<` byłby w teście `<` i żaden asert na HTML by nie trafił.
  def stream
    broadcasts(BroadcastDashboardJob::STREAM.to_s).map { |message| ActiveSupport::JSON.decode(message) }
  end
end
