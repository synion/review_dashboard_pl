require "test_helper"

class IntumClientTest < ActiveSupport::TestCase
  # Fake transportu HTTP: odpowiedzi kolejkowane per (metoda, ścieżka bez query).
  class FakeTransport
    Response = Struct.new(:code, :body)
    Call = Struct.new(:method, :path, :params, :form)

    def initialize
      @responses = Hash.new { |h, k| h[k] = [] }
      @calls = []
    end

    attr_reader :calls

    def queue(method, path, code:, body:)
      @responses[[ method, path ]] << Response.new(code.to_s, body.is_a?(String) ? body : body.to_json)
    end

    def get(path, params)
      @calls << Call.new(:get, path, params, nil)
      @responses[[ :get, path ]].shift or raise "brak odpowiedzi dla GET #{path}"
    end

    def post(path, params, form)
      @calls << Call.new(:post, path, params, form)
      @responses[[ :post, path ]].shift or raise "brak odpowiedzi dla POST #{path}"
    end
  end

  def client(transport)
    IntumClient.new(base_url: "https://tracker.example.com", token: "tajny", transport: transport)
  end

  test "users iteruje strony do pustej i filtruje gości oraz nieaktywnych" do
    fake = FakeTransport.new
    fake.queue(:get, "/account/users.json", code: 200, body: [
      { user_id: 1, get_name: "Anna Kowalska", role: "admin", active: true },
      { user_id: 2, get_name: "Klient Gość", role: "guest", active: true },
      { user_id: 3, get_name: "Rola Numeryczna", role: "1089", active: true },
      { user_id: 4, get_name: "Były Pracownik", role: "user", active: false }
    ])
    fake.queue(:get, "/account/users.json", code: 200, body: [])

    users = client(fake).users

    assert_equal [ { "id" => "1", "name" => "Anna Kowalska" }, { "id" => "3", "name" => "Rola Numeryczna" } ], users
    assert_equal [ { "page" => 1, "api_token" => "tajny" }, { "page" => 2, "api_token" => "tajny" } ],
                 fake.calls.map { |c| c.params.transform_keys(&:to_s) }
  end

  test "task pobiera zadanie po scoped_id (w tym PK)" do
    fake = FakeTransport.new
    fake.queue(:get, "/organize/tasks/123.json", code: 200, body: { id: 9876, responsible_id: 5 })

    task = client(fake).task("123")

    assert_equal 9876, task["id"]
  end

  test "post_comment wysyła formularz z markup github_markdown i opcjonalnym responsible" do
    fake = FakeTransport.new
    fake.queue(:post, "/organize/comments.json", code: 201, body: { id: 1 })

    client(fake).post_comment(9876, "treść **md**", responsible_id: "55")

    call = fake.calls.sole
    assert_equal({ "comment[commentable_id]" => 9876, "comment[commentable_type]" => "Organize::Task",
                   "comment[content]" => "treść **md**", "comment[config][markup_lang]" => "github_markdown",
                   "comment[responsible_id]" => "55" }, call.form)
    assert_equal({ api_token: "tajny" }, call.params)
  end

  test "post_comment bez responsible nie wysyła pustego pola" do
    fake = FakeTransport.new
    fake.queue(:post, "/organize/comments.json", code: 201, body: { id: 1 })

    client(fake).post_comment(9876, "treść")

    assert_not_includes fake.calls.sole.form.keys, "comment[responsible_id]"
  end

  test "nie-2xx rzuca Error z kodem i skrótem body" do
    fake = FakeTransport.new
    fake.queue(:get, "/organize/tasks/123.json", code: 403, body: { error: "login_required" })

    error = assert_raises(IntumClient::Error) { client(fake).task("123") }
    assert_includes error.message, "403"
    assert_includes error.message, "login_required"
  end
end
