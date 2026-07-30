require "test_helper"

class WorkerStallWatchdogTest < ActiveSupport::TestCase
  setup do
    @out = StringIO.new
    @watchdog = WorkerStallWatchdog.new(logger: Logger.new(@out), interval: 30)
  end

  test "tik raportuje obciążenie pul połączeń" do
    @watchdog.tick(lag: 0.0)
    assert_match(/primary=\d+\/\d+ czeka=\d+/, @out.string)
    assert_match(/queue=\d+\/\d+ czeka=\d+/, @out.string)
  end

  test "tik raportuje liczbę żywych wątków procesu" do
    @watchdog.tick(lag: 0.0)
    assert_match(/wątki=#{Thread.list.count(&:alive?)}/, @out.string)
  end

  test "tik spóźniony ponad własny interwał to zamrożenie procesu — zrzuca stosy wątków" do
    @watchdog.tick(lag: 45.0)
    assert_match(/ZAMROŻENIE/, @out.string)
    # Zrzut musi pokazywać, gdzie tkwiły wątki — inaczej nie odpowiada na „dlaczego".
    assert_match(/worker_stall_watchdog_test\.rb/, @out.string)
  end

  test "tik na czas nie zrzuca stosów" do
    @watchdog.tick(lag: 1.5)
    assert_no_match(/ZAMROŻENIE/, @out.string)
    assert_no_match(/worker_stall_watchdog_test\.rb/, @out.string)
  end
end
