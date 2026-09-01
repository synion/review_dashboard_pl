# Stan PR-a pobrany z GitHuba: zmienione pliki, komentarze przy liniach i komentarze
# ogólne. Trzy odpowiedzi lądują w JEDNYM pliku obok `result.json` — jeden zapis,
# jeden `mtime`, jedno „stan na" w nagłówku widoku.
#
# Artefakt na dysku, nie wpis w cache: katalog `storage/reviews/<id>` już istnieje
# i kasuje się razem z review (`remove_artifacts`), a diff dużego PR-a to setki
# kilobajtów, których nie ma po co wkładać do bazy cache dzielonej z drobnicą.
class PrSnapshot
  FILENAME = "pr_snapshot.json".freeze

  attr_reader :fetched_at, :files, :review_comments, :issue_comments, :author, :viewer

  def self.path_for(review) = review.artifacts_dir.join(FILENAME)

  def self.fetch!(review, client: GithubClient.new)
    data = { "fetched_at" => Time.current.iso8601,
             "files" => client.pr_files(review.pr_url, repo_dir: review.workdir),
             "review_comments" => client.pr_review_comments(review.pr_url, repo_dir: review.workdir),
             "issue_comments" => client.pr_issue_comments(review.pr_url, repo_dir: review.workdir),
             # Loginy jadą do artefaktu, a nie do widoku: prompt sesji musi wiedzieć,
             # który głos w wątku należy do autora, a który jest mój.
             "author" => client.pr_author(review.pr_url, repo_dir: review.workdir),
             "viewer" => client.viewer_login(repo_dir: review.workdir) }

    FileUtils.mkdir_p(review.artifacts_dir)
    path_for(review).write(JSON.generate(data))
    new(data)
  end

  # nil, gdy artefaktu nie ma albo nie da się go odczytać — przerwany zapis znaczy
  # dla widoku dokładnie to samo, co brak pliku: pobierz od nowa.
  def self.load(review)
    path = path_for(review)
    return nil unless path.exist?

    new(JSON.parse(path.read))
  rescue JSON::ParserError
    nil
  end

  # Snapshot pod prompt sesji: pobieramy ZAWSZE od nowa, nie oglądając się na stale?.
  # Ten próg opiera się na `pr_activity_at`, które odświeża się najwyżej co godzinę —
  # a odpowiedź autora sprzed dziesięciu minut to dokładnie ta rzecz, dla której
  # sesja tu zagląda. Cztery spawny `gh` są niczym wobec minut i kosztu sesji.
  # Padnięty `gh` nie może wywrócić review: zostajemy przy ostatnim artefakcie,
  # a gdy i jego nie ma — przy nil, czyli prompcie bez sekcji dyskusji. Łapiemy
  # StandardError, nie samo GithubClient::Error: dyskusja jest DODATKIEM do promptu,
  # a `gh` plujący niepoprawnym JSON-em nie może kosztować całego review.
  def self.refresh(review, client: GithubClient.new)
    return nil if review.pr_url.blank?

    fetch!(review, client: client)
  rescue StandardError => e
    Rails.logger.warn("PrSnapshot review #{review.id}: #{e.class} #{e.message}")
    load(review)
  end

  def initialize(data)
    @fetched_at = Time.zone.parse(data["fetched_at"].to_s)
    @files = data["files"].to_a
    @review_comments = data["review_comments"].to_a
    @issue_comments = data["issue_comments"].to_a
    # Artefakty sprzed tej zmiany nie znają loginów — wtedy PrDiscussion pokaże
    # sam login zamiast roli, zamiast zgadywać.
    @author = data["author"]
    @viewer = data["viewer"]
  end

  # Stęchły, gdy na PR-ze coś się wydarzyło po pobraniu. `pr_activity_at` utrzymuje
  # już CheckReviewRequestJob (`updatedAt` PR-a), więc nie musimy zgadywać TTL-em —
  # wiemy. Bez znanej aktywności zostajemy przy tym, co mamy: nowe pobranie to spawn
  # `gh`, a nic nie wskazuje, żeby było po co.
  def stale?(review)
    review.pr_activity_at.present? && fetched_at.present? && fetched_at < review.pr_activity_at
  end
end
