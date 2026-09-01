require "test_helper"

class PrDiscussionTest < ActiveSupport::TestCase
  VIEWER = "reviewerka".freeze
  AUTHOR = "autorka".freeze

  def snapshot(review_comments: [], issue_comments: [], author: AUTHOR, viewer: VIEWER)
    PrSnapshot.new("fetched_at" => "2026-09-01T10:00:00Z", "files" => [],
                   "review_comments" => review_comments, "issue_comments" => issue_comments,
                   "author" => author, "viewer" => viewer)
  end

  def comment(**attrs)
    { "id" => 1, "path" => "app/models/invoice.rb", "line" => 12, "original_line" => 12,
      "side" => "RIGHT", "position" => 3, "in_reply_to_id" => nil, "subject_type" => "line",
      "user" => VIEWER, "body" => "treść", "created_at" => "2026-08-27T10:00:00Z" }.merge(attrs.stringify_keys)
  end

  def finding(title: "Nil w kalkulacji VAT", priority: "critical")
    Finding.new(priority: priority, title: title, body: "Problem: nil", file_location: "app/models/invoice.rb:12")
  end

  # Pinezka wysłana na GitHuba tak, jak zrobiłby to DecisionPublisher.
  def pin(finding, **attrs)
    comment(body: InlineComments.send(:body_for, finding), **attrs)
  end

  # --- składanie wątków ---

  test "odpowiedzi lądują pod swoim korzeniem, w kolejności napisania" do
    comments = [ comment(id: 1, body: "pytanie"),
                 comment(id: 3, in_reply_to_id: 1, body: "druga", created_at: "2026-08-29T10:00:00Z"),
                 comment(id: 2, in_reply_to_id: 1, body: "pierwsza", created_at: "2026-08-28T10:00:00Z") ]

    thread = PrDiscussion.new(snapshot(review_comments: comments)).threads.sole

    assert_equal "pytanie", thread.root["body"]
    assert_equal [ "pierwsza", "druga" ], thread.replies.map { |reply| reply["body"] }
    assert thread.answered?
  end

  # GitHub potrafi wskazać w in_reply_to_id ogniwo pośrednie, nie korzeń.
  test "odpowiedź na odpowiedź wraca do tego samego wątku" do
    comments = [ comment(id: 1), comment(id: 2, in_reply_to_id: 1), comment(id: 3, in_reply_to_id: 2) ]

    assert_equal 3, PrDiscussion.new(snapshot(review_comments: comments)).threads.sole.size
  end

  # Moja pinezka, na którą nikt nie odpisał, jest echem — jej treść sesja ma w znaleziskach.
  test "moja pinezka bez odpowiedzi nie jest dyskusją" do
    discussion = PrDiscussion.new(snapshot(review_comments: [ comment(user: VIEWER) ]))

    assert_empty discussion.relevant_threads
    assert_not discussion.any?
  end

  # Sedno poprawki: PR-a ogląda kilka osób. Autor bywa, że wyjaśnia rzecz sam z siebie
  # albo pod uwagą innego reviewera — taki wątek nie ma ŻADNEJ odpowiedzi, a jest
  # jedynym śladem, że sprawa była już poruszona, zanim usiadłem do review.
  test "cudzy komentarz bez odpowiedzi zostaje — także wtedy nikt mu nie odpisał" do
    comments = [ comment(id: 1, user: AUTHOR, body: "wiem, że wygląda dziwnie — to świadome"),
                 comment(id: 2, user: "drugi-reviewer", body: "a tu nie ma race condition?") ]
    discussion = PrDiscussion.new(snapshot(review_comments: comments))

    assert_equal 2, discussion.relevant_threads.size
    assert discussion.any?
  end

  # Snapshot sprzed tej zmiany nie wie, który głos jest mój — wtedy nie wycinamy nic.
  test "bez loginu reviewera nie wycinamy żadnego wątku" do
    discussion = PrDiscussion.new(snapshot(review_comments: [ comment(user: VIEWER) ], viewer: nil))

    assert_equal 1, discussion.relevant_threads.size
  end

  test "reszta rozmowy to wątki spoza moich pinezek" do
    mine = finding
    comments = [ pin(mine, id: 1), comment(id: 2, in_reply_to_id: 1, user: AUTHOR, body: "ok"),
                 comment(id: 3, user: AUTHOR, body: "to samo tłumaczyłem wyżej") ]
    discussion = PrDiscussion.new(snapshot(review_comments: comments))

    assert_equal [ "to samo tłumaczyłem wyżej" ],
                 discussion.other_threads([ mine ]).map { |thread| thread.root["body"] }
    assert_equal 2, discussion.other_threads([]).size
  end

  test "sam komentarz ogólny wystarczy, żeby było o czym pisać w prompcie" do
    assert PrDiscussion.new(snapshot(issue_comments: [ { "body" => "merguję jutro" } ])).any?
  end

  # --- wiązanie ze znaleziskiem ---

  # Sedno całej zmiany: po treści pinezki poznajemy, że wątek dotyczy TEJ uwagi.
  test "odpowiedź pod moją pinezką wraca przy właściwym znalezisku" do
    mine = finding
    comments = [ pin(mine, id: 5),
                 comment(id: 6, in_reply_to_id: 5, user: AUTHOR, body: "Zostawiam świadomie — dług z mastera.") ]

    replies = PrDiscussion.new(snapshot(review_comments: comments)).replies_to(mine)

    assert_equal [ "Zostawiam świadomie — dług z mastera." ], replies.map { |reply| reply["body"] }
  end

  test "moja pinezka nie jedzie do promptu razem z odpowiedzią — sesja ma jej treść w znalezisku" do
    mine = finding
    comments = [ pin(mine, id: 5), comment(id: 6, in_reply_to_id: 5, user: AUTHOR, body: "ok") ]

    assert_equal 1, PrDiscussion.new(snapshot(review_comments: comments)).replies_to(mine).size
  end

  test "znalezisko bez pinezki na PR-ze nie zbiera cudzych wątków" do
    comments = [ comment(id: 5, body: "zupełnie inna uwaga"), comment(id: 6, in_reply_to_id: 5, body: "ok") ]

    assert_empty PrDiscussion.new(snapshot(review_comments: comments)).replies_to(finding)
  end

  # Tytuł jest kluczem, więc uwaga o tej samej treści, ale innym priorytecie, to inna pinezka.
  test "priorytet jest częścią klucza — inny priorytet to inna pinezka" do
    mine = finding
    comments = [ pin(mine, id: 5), comment(id: 6, in_reply_to_id: 5, body: "ok") ]
    discussion = PrDiscussion.new(snapshot(review_comments: comments))

    assert_empty discussion.replies_to(finding(priority: "minor"))
  end

  # --- role i cytowanie ---

  test "prompt odróżnia autora PR-a od mnie i od kogoś trzeciego" do
    discussion = PrDiscussion.new(snapshot)

    assert_equal "ja (reviewer)", discussion.speaker(comment(user: VIEWER))
    assert_equal "autor PR-a (#{AUTHOR})", discussion.speaker(comment(user: AUTHOR))
    assert_equal "ktoś-inny", discussion.speaker(comment(user: "ktoś-inny"))
  end

  # Artefakty sprzed tej zmiany nie mają loginów — wtedy zostaje sam login, bez zgadywania.
  test "snapshot bez loginów nie przypisuje ról" do
    discussion = PrDiscussion.new(snapshot(author: nil, viewer: nil))

    assert_equal AUTHOR, discussion.speaker(comment(user: AUTHOR))
  end

  test "cytat niesie rolę, datę i treść, a wielolinijkowe ciało nie rozsypuje listy" do
    entry = PrDiscussion.new(snapshot).entry(comment(user: AUTHOR, body: "pierwsza\ndruga"))

    assert_equal "- **autor PR-a (#{AUTHOR})** (2026-08-27): pierwsza\n  druga", entry
  end

  test "bardzo długi komentarz jedzie do promptu obcięty" do
    entry = PrDiscussion.new(snapshot).entry(comment(body: "x" * (PrDiscussion::MAX_BODY + 100)))

    assert_includes entry, "… (ucięte)"
    assert_operator entry.length, :<, PrDiscussion::MAX_BODY + 100
  end

  # --- co się wydarzyło po decyzji ---

  test "odpowiedzi po decyzji liczą się także wtedy, gdy autor nic nie wypchnął" do
    comments = [ comment(id: 5), comment(id: 6, in_reply_to_id: 5, created_at: "2026-08-30T10:00:00Z") ]
    discussion = PrDiscussion.new(snapshot(review_comments: comments,
                                           issue_comments: [ { "created_at" => "2026-08-31T10:00:00Z" } ]))

    assert_equal 2, discussion.replies_after(Time.zone.parse("2026-08-29T00:00:00Z")).size
    assert_empty discussion.replies_after(Time.zone.parse("2026-09-01T00:00:00Z"))
  end

  test "bez daty decyzji nie ma od czego liczyć" do
    comments = [ comment(id: 5), comment(id: 6, in_reply_to_id: 5) ]

    assert_empty PrDiscussion.new(snapshot(review_comments: comments)).replies_after(nil)
  end
end
