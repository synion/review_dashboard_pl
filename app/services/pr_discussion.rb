# Dyskusja ludzi na PR-ze: komentarze przy liniach poskładane w wątki plus komentarze
# ogólne. Jedyne miejsce, które z płaskiej listy z GitHuba robi wątki — czyta z niego
# i widok zmian (DiffPresenter), i prompty sesji, więc „co jest odpowiedzią na co”
# rozstrzyga się raz.
#
# Po to istnieje: sesja, która nie widzi odpowiedzi autora, zgłasza po raz drugi rzecz,
# którą autor już na PR-ze uzasadnił („robię tak świadomie, bo…”). Wiązanie wątku
# ze znaleziskiem idzie po treści pierwszej linii komentarza (InlineComments.header_for),
# bo GitHub przy publikacji review NIE zwraca id utworzonych pinezek — nie ma czego
# zapisać na znalezisku, a treść działa też dla review wiszących tam od dawna.
class PrDiscussion
  # Komentarze bywają długie (wklejony log, cały plik). Do promptu idzie początek —
  # argument autora mieści się w pierwszych zdaniach, a reszta to koszt bez treści.
  MAX_BODY = 1500

  # Wątek dyskusji: komentarz zakładający + odpowiedzi. Kotwica należy do korzenia —
  # odpowiedzi na GitHubie nie niosą własnej pozycji w diffie.
  CommentThread = Data.define(:root, :replies) do
    def id = root["id"]
    def size = replies.size + 1
    def path = root["path"]
    def side = root["side"].presence || "RIGHT"
    def line = root["line"] || root["original_line"]
    def file_level? = root["subject_type"] == "file"
    def answered? = replies.any?

    # `position: null` znaczy, że linia wypadła z bieżącego diffu. Taki komentarz
    # ma numer linii sprzed zmian i przypięty do wiersza kłamałby o tym, czego dotyczy.
    def outdated? = !file_level? && root["position"].nil?

    def anchored? = !file_level? && !outdated? && line.present?
  end

  # Wejście dla jobów: świeży snapshot z GitHuba i dyskusja na jego podstawie.
  # nil, gdy review nie ma PR-a albo `gh` nie odpowiedział i nie ma nawet starego
  # artefaktu — prompt poleci wtedy bez sekcji dyskusji, zamiast wywracać sesję.
  def self.for(review, client: GithubClient.new)
    snapshot = PrSnapshot.refresh(review, client: client)
    snapshot && new(snapshot)
  end

  # Znalezisk nie trzymamy: wiązanie idzie po treści pinezki, więc `replies_to`
  # potrzebuje tylko tego jednego znaleziska, o które właśnie pyta.
  def initialize(snapshot)
    @snapshot = snapshot
  end

  def fetched_at = @snapshot.fetched_at

  def issue_comments = @snapshot.issue_comments

  def threads
    @threads ||= begin
      by_id = @snapshot.review_comments.index_by { |comment| comment["id"] }
      @snapshot.review_comments.group_by { |comment| root_id(comment, by_id) }.filter_map do |id, comments|
        root = by_id[id] || comments.min_by { |comment| comment["created_at"].to_s }
        CommentThread.new(root: root, replies: sorted(comments - [ root ]))
      end
    end
  end

  # Do promptu idzie każdy wątek POZA moją własną pinezką, na którą nikt nie odpowiedział
  # — jej treść sesja i tak ma w liście znalezisk, więc byłaby echem.
  #
  # Świadomie NIE filtrujemy po „ma odpowiedź": PR-a ogląda kilka osób i autor bywa,
  # że wyjaśnia sprawę SAM z siebie albo pod uwagą drugiego reviewera, zanim w ogóle
  # siadam do swojego review. Taki wątek nie ma żadnej odpowiedzi, a jest jedynym
  # śladem, że rzecz była już wyjaśniona — wycięcie go odtwarza dokładnie ten błąd,
  # dla którego cała ta klasa powstała.
  def relevant_threads
    @relevant_threads ||= threads.reject { |thread| mine?(thread.root) && !thread.answered? }
  end

  # Wątki, których nie da się przypiąć do żadnego z podanych znalezisk — reszta
  # rozmowy, w której autor mógł się odnieść do sprawy nie tam, gdzie ją zgłosiłem.
  def other_threads(findings)
    taken = findings.to_a.map { |finding| InlineComments.header_for(finding) }.to_set
    relevant_threads.reject { |thread| taken.include?(header_of(thread)) }
  end

  # Czy jest o czym pisać w prompcie.
  def any? = relevant_threads.any? || issue_comments.any?

  # Mój własny głos na PR-ze. Snapshot bez loginu (artefakt sprzed tej zmiany) nie
  # pozwala tego rozstrzygnąć — wtedy nie wycinamy nic, bo nadmiar jest tańszy
  # niż zgubiona odpowiedź autora.
  def mine?(comment) = @snapshot.viewer.present? && comment["user"] == @snapshot.viewer

  # Odpowiedzi pod MOJĄ pinezką do tego znaleziska — bez komentarza zakładającego,
  # którego treść sesja i tak ma w liście znalezisk. To ten materiał, którego brak
  # kazał weryfikacji poprawek orzekać „zignorowane” o uwadze świadomie uzasadnionej
  # przez autora. Pusto znaczy „autor się do tej uwagi nie odniósł”, a nie „nie wiem”.
  def replies_to(finding)
    by_header.fetch(InlineComments.header_for(finding), []).flat_map(&:replies)
  end

  # Co ludzie napisali po dacie `time` — po tym poznajemy, że na PR-ze pojawił się
  # nowy głos, choć autor nic nie wypchnął. Bez daty (brak decyzji) nie ma od czego
  # liczyć, więc pusto.
  def replies_after(time)
    return [] if time.blank?

    (threads.flat_map(&:replies) + issue_comments).select do |comment|
      (at = Time.zone.parse(comment["created_at"].to_s)) && at > time
    end
  end

  # Kto mówi — sesja musi odróżnić argument AUTORA od uwagi kogoś trzeciego i od
  # mojej własnej pinezki. Starsze artefakty nie znają loginów: wtedy zostaje sam login.
  def speaker(comment)
    login = comment["user"].to_s
    return "ja (reviewer)" if login.present? && login == @snapshot.viewer
    return "autor PR-a (#{login})" if login.present? && login == @snapshot.author

    login.presence || "ktoś"
  end

  # Cały wątek jako lista markdown. Ciało komentarza wcinamy, żeby jego własne
  # akapity nie rozsypały punktora.
  def transcript(thread)
    ([ thread.root ] + thread.replies).map { |comment| entry(comment) }.join("\n")
  end

  def entry(comment)
    "- **#{speaker(comment)}**#{stamp(comment)}: #{body_of(comment)}"
  end

  private

  def by_header
    @by_header ||= threads.group_by { |thread| header_of(thread) }
  end

  def header_of(thread) = thread.root["body"].to_s.lines.first.to_s.strip

  def body_of(comment)
    text = comment["body"].to_s.strip
    text = "#{text[0, MAX_BODY]}… (ucięte)" if text.length > MAX_BODY
    text.gsub("\n", "\n  ")
  end

  def stamp(comment)
    at = Time.zone.parse(comment["created_at"].to_s)
    at ? " (#{at.to_date})" : ""
  end

  def sorted(comments) = comments.sort_by { |comment| comment["created_at"].to_s }

  # GitHub wskazuje korzeniem wątku pierwszy komentarz, ale odpowiedź na odpowiedź
  # potrafi wskazywać ogniwo pośrednie — idziemy w górę, z zabezpieczeniem przed
  # zapętleniem na uszkodzonych danych.
  def root_id(comment, by_id)
    id = comment["id"]
    seen = Set.new

    while (parent = by_id[comment["in_reply_to_id"]]) && seen.add?(id)
      comment = parent
      id = comment["id"]
    end

    id
  end
end
