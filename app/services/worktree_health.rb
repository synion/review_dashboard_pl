require "net/http"

# Puka do środowiska dev postawionego dla worktree i mówi jednym zdaniem, czy da się
# tam wejść. Skrypt worktree potrafi zakończyć się sukcesem, a mimo to zostawić
# niedziałającą apkę (urwany seed bazy, pełny wolumen kontenera) — a tego dysk hosta
# nie widzi, więc jedyną pewną kontrolą jest zwykłe żądanie HTTP.
class WorktreeHealth
  # Zimny boot apki dev (puma-dev startuje ją dopiero pierwszym żądaniem) bywa długi —
  # krótszy limit dawałby fałszywe „nie wstaje" dla środowiska, które się rozgrzewa.
  OPEN_TIMEOUT = 15
  READ_TIMEOUT = 120

  # nil = środowisko odpowiada. String = powód, który zobaczy człowiek w panelu.
  def self.check(url, http_class: Net::HTTP)
    new(url, http_class: http_class).check
  end

  def initialize(url, http_class: Net::HTTP)
    @url = url
    @http_class = http_class
  end

  def check
    code = get.code.to_i
    # Tylko 5xx: 404 znaczy, że apka wstała i odpowiada — brak trasy pod „/" nie jest
    # awarią środowiska, a przekierowanie na logowanie to normalny stan tej apki.
    return if code < 500

    "HTTP #{code}"
  rescue StandardError => e
    # Cokolwiek poszło nie tak (DNS, TLS, timeout, odmowa połączenia) znaczy dla
    # człowieka to samo: nie da się tam wejść. Klasa wyjątku to cała diagnoza, jaką mamy.
    "#{e.class}: #{e.message}"
  end

  private

  def get
    uri = URI.parse(@url)
    http = @http_class.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    # Środowiska dev stoją na certyfikacie lokalnego CA (puma-dev), którego proces
    # Railsów nie zna. Weryfikacja odrzucałaby każdy adres, zamiast go sprawdzić.
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = READ_TIMEOUT

    http.request(Net::HTTP::Get.new(uri.request_uri.presence || "/"))
  end
end
