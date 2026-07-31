require "net/http"

# Cienki klient API trackera (Intum/Sugester) — token per projekt, autoryzacja
# przez ?api_token=. Tracker odrzuca requesty bez przeglądarkowego User-Agenta
# (403 bez treści), stąd wymuszony UA. Zapisy (komentarz) nie wymagają CSRF —
# w przeciwieństwie do ścieżki cookie, którą ten klient zastępuje.
class IntumClient
  Error = Class.new(StandardError)

  USER_AGENT = "Mozilla/5.0 (Macintosh) AppleWebKit/537.36".freeze
  USERS_PER_PAGE_LIMIT = 30 # bezpiecznik pętli paginacji (30 × 500 osób)

  def initialize(base_url:, token:, transport: nil)
    @base_url = base_url
    @token = token
    @transport = transport || HttpTransport.new(base_url)
  end

  # Zespół do comboboxa drugiego sprawdzenia. Konto trackera ma tysiące gości
  # (klientów) — zostają aktywni nie-goście. Ról nie whitelistujemy: bywają
  # numerycznymi ID custom ról jako stringi (np. "1089").
  def users
    (1..USERS_PER_PAGE_LIMIT).each_with_object([]) do |page, acc|
      users = parse(@transport.get("/account/users.json", { page: page, api_token: @token }))
      break acc if users.empty?

      acc.concat(users.select { |u| u["active"] && u["role"] != "guest" }
                      .map { |u| { "id" => u["user_id"].to_s, "name" => u["get_name"] } })
    end
  end

  # Zadanie po numerze z URL-a (scoped_id). Zwraca m.in. "id" — PK, którego
  # wymagają zapisy (komentarze chodzą po PK, nie po numerze z URL-a).
  def task(scoped_id)
    parse(@transport.get("/organize/tasks/#{scoped_id}.json", { api_token: @token }))
  end

  def post_comment(task_pk, content, responsible_id: nil)
    form = { "comment[commentable_id]" => task_pk,
             "comment[commentable_type]" => "Organize::Task",
             "comment[content]" => content,
             "comment[config][markup_lang]" => "github_markdown" }
    form["comment[responsible_id]"] = responsible_id if responsible_id.present?
    parse(@transport.post("/organize/comments.json", { api_token: @token }, form))
  end

  private

  def parse(response)
    unless response.code.to_i.between?(200, 299)
      raise Error, "tracker odpowiedział #{response.code}: #{response.body.to_s.truncate(200)}"
    end

    JSON.parse(response.body)
  rescue JSON::ParserError
    raise Error, "tracker zwrócił nie-JSON (#{response.code})"
  end

  # Realny transport — w testach podmieniany fake'iem o tym samym kształcie.
  class HttpTransport
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 15

    def initialize(base_url)
      @base_url = base_url
    end

    def get(path, params)
      request(Net::HTTP::Get.new(url(path, params)))
    end

    def post(path, params, form)
      req = Net::HTTP::Post.new(url(path, params))
      req.set_form_data(form)
      request(req)
    end

    private

    def url(path, params)
      URI.join(@base_url, path).tap { |u| u.query = URI.encode_www_form(params) }
    end

    def request(req)
      req["User-Agent"] = USER_AGENT
      req["Accept"] = "application/json"
      uri = req.uri
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                      open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
        http.request(req)
      end
    rescue SystemCallError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError => e
      raise Error, "połączenie z trackerem nie powiodło się: #{e.message}"
    end
  end
end
