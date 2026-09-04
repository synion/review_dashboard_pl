require "test_helper"

class WorktreeHealthTest < ActiveSupport::TestCase
  # Podstawiamy klasę HTTP zamiast prawdziwego Net::HTTP — sprawdzamy tłumaczenie
  # odpowiedzi na komunikat dla człowieka, nie działanie biblioteki.
  class FakeHttp
    attr_accessor :use_ssl, :verify_mode, :open_timeout, :read_timeout

    class << self
      attr_accessor :response, :error
      attr_reader :host, :port, :requested_path

      def new(host, port)
        @host = host
        @port = port
        allocate.tap { |instance| instance.send(:initialize) }
      end

      def record_path(path) = @requested_path = path
    end

    def request(req)
      self.class.record_path(req.path)
      raise self.class.error if self.class.error

      self.class.response
    end
  end

  def response(code)
    Net::HTTPResponse.new("1.1", code.to_s, "")
  end

  setup do
    FakeHttp.response = nil
    FakeHttp.error = nil
  end

  test "odpowiedź 200 znaczy, że środowisko wstaje" do
    FakeHttp.response = response(200)

    assert_nil WorktreeHealth.check("https://sl-fix-vat.dev.example.test/", http_class: FakeHttp)
    assert_equal "sl-fix-vat.dev.example.test", FakeHttp.host
    assert_equal 443, FakeHttp.port
  end

  # Apka pod „/" potrafi przekierować na logowanie, a część środowisk nie ma
  # tam żadnej trasy — jedno i drugie znaczy „wstała i odpowiada".
  test "przekierowanie i 404 nie są awarią środowiska" do
    FakeHttp.response = response(302)
    assert_nil WorktreeHealth.check("https://x.dev.example.test/", http_class: FakeHttp)

    FakeHttp.response = response(404)
    assert_nil WorktreeHealth.check("https://x.dev.example.test/", http_class: FakeHttp)
  end

  test "piątka wraca jako powód do pokazania w panelu" do
    FakeHttp.response = response(500)

    assert_equal "HTTP 500", WorktreeHealth.check("https://x.dev.example.test/", http_class: FakeHttp)
  end

  # Brak odpowiedzi znaczy dla człowieka to samo co piątka: nie da się tam wejść.
  test "błąd połączenia wraca jako klasa i treść wyjątku" do
    FakeHttp.error = Errno::ECONNREFUSED.new("nikt nie słucha")

    result = WorktreeHealth.check("https://x.dev.example.test/", http_class: FakeHttp)

    assert_match(/ECONNREFUSED/, result)
  end

  # Adres bez ścieżki („https://host") daje puste request_uri — bez fallbacku
  # Net::HTTP::Get dostałby pusty string i wywalił się na każdym takim wzorcu.
  test "adres bez ścieżki pyta o /" do
    FakeHttp.response = response(200)

    WorktreeHealth.check("https://x.dev.example.test", http_class: FakeHttp)

    assert_equal "/", FakeHttp.requested_path
  end
end
