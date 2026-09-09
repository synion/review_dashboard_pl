# Zaślepka `gh` dla jobów, które przed sesją ciągną rozmowę z PR-a (PrDiscussion).
# Bez niej test odpalałby prawdziwego `gh` na fixture'owym URL-u — wolno i po sieci.
# Domyślnie PR jest pusty: żadnych komentarzy, więc prompt nie dostaje sekcji dyskusji.
class FakeGithubClient
  attr_reader :head_calls

  def initialize(head: nil, head_error: nil, review_comments: [], issue_comments: [],
                 author: "autorka", viewer: "reviewerka")
    @head = head
    @head_error = head_error
    @review_comments = review_comments
    @issue_comments = issue_comments
    @author = author
    @viewer = viewer
    @head_calls = []
  end

  def pr_files(_url, repo_dir:) = []
  def pr_review_comments(_url, repo_dir:) = @review_comments
  def pr_issue_comments(_url, repo_dir:) = @issue_comments
  def pr_reviews_with_bodies(_url, repo_dir:) = []
  def pr_author(_url, repo_dir:) = @author
  def viewer_login(repo_dir:) = @viewer

  def pr_head_sha(url, repo_dir:)
    @head_calls << url
    raise GithubClient::Error, @head_error if @head_error

    @head
  end
end
