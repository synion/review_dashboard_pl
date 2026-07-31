require "test_helper"

class FollowupActionsTest < ActiveSupport::TestCase
  class FakeGithub
    Call = Struct.new(:method, :args)

    def initialize(fail_on: nil)
      @fail_on = fail_on
      @calls = []
    end

    attr_reader :calls

    def add_reviewer(pr_url, login:, repo_dir:)
      @calls << Call.new(:add_reviewer, login)
      raise GithubClient::Error, "reviewer padł" if @fail_on == :add_reviewer
    end

    def add_label(pr_url, name:, repo_dir:)
      @calls << Call.new(:add_label, name)
      raise GithubClient::Error, "label padł" if @fail_on == :add_label
    end
  end

  setup do
    @review = reviews(:pr_review)
  end

  test "wykonuje zakolejkowane akcje i zapisuje statusy sent" do
    @review.update!(followup_reviewer_login: "anna", followup_reviewer_status: "queued",
                    followup_label_name: "po review", followup_label_status: "queued")
    FollowupActions.call(@review, client: FakeGithub.new)

    @review.reload
    assert_equal %w[sent sent], [ @review.followup_reviewer_status, @review.followup_label_status ]
  end

  test "pomija akcje niezakolejkowane (puste albo już wysłane)" do
    @review.update!(followup_reviewer_login: "anna", followup_reviewer_status: "sent",
                    followup_label_name: "po review", followup_label_status: nil)
    fake = FakeGithub.new
    FollowupActions.call(@review, client: fake)

    assert_empty fake.calls
  end

  test "porażka jednej akcji nie zatrzymuje drugiej — failed z powodem w osobnej kolumnie" do
    @review.update!(followup_reviewer_login: "anna", followup_reviewer_status: "queued",
                    followup_label_name: "po review", followup_label_status: "queued")
    fake = FakeGithub.new(fail_on: :add_reviewer)
    FollowupActions.call(@review, client: fake)

    @review.reload
    assert_equal "failed", @review.followup_reviewer_status
    assert_equal "reviewer padł", @review.followup_reviewer_error
    assert_equal "sent", @review.followup_label_status
    assert_equal [ :add_reviewer, :add_label ], fake.calls.map(&:method)
    assert @review.followup_retryable?
  end

  test "ponowny sukces czyści poprzedni błąd" do
    @review.update!(followup_reviewer_login: "anna", followup_reviewer_status: "queued",
                    followup_reviewer_error: "stary błąd")
    FollowupActions.call(@review, client: FakeGithub.new)

    @review.reload
    assert_equal "sent", @review.followup_reviewer_status
    assert_nil @review.followup_reviewer_error
  end
end
