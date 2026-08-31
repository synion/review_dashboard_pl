require "test_helper"

class DiffPresenterTest < ActiveSupport::TestCase
  # Po prawej: 10 kontekst, 11-12 dodane, 13-14 kontekst. Po lewej 11 usunięta.
  PATCH = "@@ -10,4 +10,5 @@ class Invoice\n   def total\n-    items.sum(&:price)\n" \
          "+    return 0 if items.empty?\n+    items.sum(&:price)\n   end\n end"

  def snapshot(files: nil, review_comments: [], issue_comments: [])
    files ||= [ { "filename" => "app/models/invoice.rb", "status" => "modified",
                  "additions" => 2, "deletions" => 1, "patch" => PATCH } ]
    PrSnapshot.new("fetched_at" => Time.current.iso8601, "files" => files,
                   "review_comments" => review_comments, "issue_comments" => issue_comments)
  end

  def comment(**attrs)
    { "id" => 1, "path" => "app/models/invoice.rb", "line" => 12, "original_line" => 12,
      "side" => "RIGHT", "position" => 3, "in_reply_to_id" => nil, "subject_type" => "line",
      "user" => "kolega", "body" => "a co jak nil?", "created_at" => "2026-08-27T10:00:00Z" }.merge(attrs.stringify_keys)
  end

  def finding(file_location, priority: "critical", title: "Uwaga")
    Finding.new(file_location: file_location, priority: priority, title: title, body: "treść")
  end

  def present(snapshot, findings: [], mode: "unified", expanded: [])
    DiffPresenter.new(snapshot, findings: findings, mode: mode, expanded: expanded)
  end

  def rows(presenter) = presenter.files.sole.hunks.sole.rows

  # --- struktura pliku ---

  test "plik niesie metadane z API i wyrenderowane hunki" do
    file = present(snapshot).files.sole

    assert_equal "app/models/invoice.rb", file.filename
    assert_equal "modified", file.status
    assert_equal [ 2, 1 ], [ file.additions, file.deletions ]
    assert file.renderable?
    assert_equal "@@ -10,4 +10,5 @@ class Invoice", file.hunks.sole.header
  end

  test "statystyki nagłówka sumują pliki i linie" do
    files = [ { "filename" => "a.rb", "additions" => 2, "deletions" => 1, "patch" => PATCH },
              { "filename" => "b.rb", "additions" => 5, "deletions" => 0, "patch" => PATCH } ]

    assert_equal({ files: 2, additions: 7, deletions: 1 }, present(snapshot(files: files)).stats)
  end

  test "plik binarny albo obcięty przez GitHuba nie jest renderowalny" do
    file = present(snapshot(files: [ { "filename" => "logo.png", "status" => "added", "patch" => nil } ])).files.sole

    assert_not file.renderable?
    assert_equal :no_patch, file.skip_reason
    assert_empty file.hunks
  end

  test "patch ponad limitem czeka na kliknięcie, chyba że plik rozwinięto" do
    huge = "@@ -1,#{DiffPresenter::MAX_PATCH_LINES + 5} +1,1 @@\n" + ("-x\n" * (DiffPresenter::MAX_PATCH_LINES + 5))
    files = [ { "filename" => "big.rb", "patch" => huge } ]

    assert_equal :too_large, present(snapshot(files: files)).files.sole.skip_reason
    assert present(snapshot(files: files), expanded: [ "big.rb" ]).files.sole.renderable?
  end

  # Zwinięty plik nie ma wierszy, do których dałoby się cokolwiek przypiąć —
  # bez tego komentarz i znalezisko znikają z ekranu bez śladu.
  test "wątki i znaleziska z niewyrenderowanego pliku nie giną" do
    huge ="@@ -1,#{DiffPresenter::MAX_PATCH_LINES + 5} +1,#{DiffPresenter::MAX_PATCH_LINES + 5} @@\n" +
           ("+x\n" * (DiffPresenter::MAX_PATCH_LINES + 5))
    presenter = present(snapshot(files: [ { "filename" => "big.rb", "patch" => huge } ],
                                 review_comments: [ comment(path: "big.rb", line: 1) ]),
                        findings: [ finding("big.rb:1") ])

    assert_equal :too_large, presenter.files.sole.skip_reason
    assert_equal 1, presenter.files.sole.file_threads.size, "wątek ląduje pod nagłówkiem pliku"
    assert_equal 1, presenter.unpinned_findings.size, "znalezisko ląduje na liście bez pinezki"
  end

  # --- kotwiczenie komentarzy ---

  test "komentarz ląduje przy swojej linii po prawej stronie" do
    presenter = present(snapshot(review_comments: [ comment(line: 12) ]))

    with_thread = rows(presenter).select { |row| row.threads.any? }
    assert_equal 1, with_thread.size
    assert_equal 12, with_thread.sole.right
    assert_equal "a co jak nil?", with_thread.sole.threads.sole.root["body"]
  end

  test "komentarz po lewej stronie ląduje przy linii usuniętej" do
    presenter = present(snapshot(review_comments: [ comment(side: "LEFT", line: 11) ]))

    row = rows(presenter).find { |r| r.threads.any? }
    assert_equal :del, row.kind
    assert_equal 11, row.left
  end

  test "pusta linia w komentarzu bierze kotwicę z original_line" do
    presenter = present(snapshot(review_comments: [ comment(line: nil, original_line: 13) ]))

    assert_equal 13, rows(presenter).find { |r| r.threads.any? }.right
  end

  # position: null znaczy, że linia wypadła z bieżącego diffu — przypięcie takiego
  # komentarza do przypadkowego wiersza kłamałoby o tym, czego dotyczy.
  test "nieaktualny komentarz idzie pod nagłówek pliku, nie do wiersza" do
    presenter = present(snapshot(review_comments: [ comment(position: nil, line: nil, original_line: 99) ]))

    assert_empty rows(presenter).flat_map(&:threads)
    thread = presenter.files.sole.file_threads.sole
    assert thread.outdated?
  end

  test "komentarz do całego pliku idzie pod jego nagłówek" do
    presenter = present(snapshot(review_comments: [ comment(subject_type: "file", line: nil) ]))

    assert_equal 1, presenter.files.sole.file_threads.size
    assert_empty rows(presenter).flat_map(&:threads)
  end

  test "komentarz do pliku spoza snapshotu nie ginie — ląduje w ogólnych" do
    presenter = present(snapshot(review_comments: [ comment(path: "app/gdzie_indziej.rb") ]))

    assert_equal 1, presenter.orphan_threads.size
  end

  # --- wątki ---

  test "odpowiedzi wiszą pod korzeniem wątku, w kolejności czasu" do
    comments = [ comment(id: 1, body: "pytanie"),
                 comment(id: 3, in_reply_to_id: 1, body: "druga", created_at: "2026-08-27T12:00:00Z"),
                 comment(id: 2, in_reply_to_id: 1, body: "pierwsza", created_at: "2026-08-27T11:00:00Z") ]
    presenter = present(snapshot(review_comments: comments))

    thread = rows(presenter).find { |r| r.threads.any? }.threads.sole
    assert_equal "pytanie", thread.root["body"]
    assert_equal [ "pierwsza", "druga" ], thread.replies.map { |r| r["body"] }
    assert_equal 3, thread.size
  end

  test "komentarze ogólne z konwersacji zostają płaską listą" do
    presenter = present(snapshot(issue_comments: [ { "id" => 7, "body" => "ogólna uwaga", "user" => "ja" } ]))

    assert_equal "ogólna uwaga", presenter.issue_comments.sole["body"]
  end

  # --- pinezki znalezisk ---

  test "znalezisko przypina się do swojej linii" do
    presenter = present(snapshot, findings: [ finding("app/models/invoice.rb:12") ])

    row = rows(presenter).find { |r| r.findings.any? }
    assert_equal 12, row.right
    assert_empty presenter.unpinned_findings
  end

  test "zakres linii przypina się do ostatniej — tam, gdzie kończy się problem" do
    presenter = present(snapshot, findings: [ finding("app/models/invoice.rb:11-13") ])

    assert_equal 13, rows(presenter).find { |r| r.findings.any? }.right
  end

  # Model bywa, że skróci ścieżkę — ta sama reguła co przy publikacji komentarzy.
  test "skrócona ścieżka znaleziska rozwiązuje się po unikalnym sufiksie" do
    presenter = present(snapshot, findings: [ finding("models/invoice.rb:12") ])

    assert_equal 1, rows(presenter).count { |r| r.findings.any? }
  end

  test "znalezisko bez linii, bez pliku albo spoza diffu trafia na listę bez pinezki" do
    findings = [ finding("app/models/invoice.rb"), finding("app/inny.rb:3"),
                 finding("app/models/invoice.rb:999"), finding("") ]
    presenter = present(snapshot, findings: findings)

    assert_equal 4, presenter.unpinned_findings.size
    assert_empty rows(presenter).flat_map(&:findings)
  end

  test "liczniki pliku pokazują wątki i znaleziska" do
    presenter = present(snapshot(review_comments: [ comment(id: 1), comment(id: 2, in_reply_to_id: 1) ]),
                        findings: [ finding("app/models/invoice.rb:12") ])
    file = presenter.files.sole

    assert_equal 1, file.thread_count
    assert_equal 1, file.finding_count
  end

  # --- widok split ---

  test "split paruje usuniętą linię z dodaną, a nadmiar zostaje bez pary" do
    presenter = present(snapshot, mode: "split")
    pairs = rows(presenter).map { |row| [ row.left&.left, row.right&.right ] }

    assert_equal [ [ 10, 10 ], [ 11, 11 ], [ nil, 12 ], [ 12, 13 ], [ 13, 14 ] ], pairs
  end

  test "split trzyma komentarz w wierszu tej strony, do której należy" do
    presenter = present(snapshot(review_comments: [ comment(side: "LEFT", line: 11) ]), mode: "split")

    row = rows(presenter).find { |r| r.threads.any? }
    assert_equal 11, row.left.left
    assert_equal 11, row.right.right, "para dodanej linii zostaje nietknięta"
  end

  test "nieznany tryb schodzi do unified" do
    assert_equal "unified", present(snapshot, mode: "bzdura").mode
  end
end
