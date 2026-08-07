require "test_helper"

class RefreshInboxJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class FakeInbox
    attr_reader :refreshed

    def initialize = @refreshed = []
    def refresh(project) = @refreshed << project
  end

  setup { @project = projects(:webapp) }

  test "odświeża kolejkę projektu" do
    inbox = FakeInbox.new
    RefreshInboxJob.perform_now(@project, inbox: inbox)
    assert_equal [ @project ], inbox.refreshed
  end

  # Automat czyta kolejkę PO jej przepisaniu — dlatego siedzi w jobie, a nie w widoku
  # ani w GithubInbox. Fake nie rusza inbox_items, więc pozycja z fixtures jest tym,
  # co automat zobaczy.
  test "po odświeżeniu zakłada review dla nowych próśb, gdy automat włączony" do
    @project.update!(auto_review_requested: true)

    assert_difference -> { Review.count }, 1 do
      RefreshInboxJob.perform_now(@project, inbox: FakeInbox.new)
    end
    assert_equal inbox_items(:requested).url, Review.order(:id).last.pr_url
  end

  test "z wyłączonym automatem samo odświeżenie nic nie zakłada" do
    assert_no_difference -> { Review.count } do
      RefreshInboxJob.perform_now(@project, inbox: FakeInbox.new)
    end
  end
end
