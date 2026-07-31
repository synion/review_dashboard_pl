# Ponowienie akcji po decyzji (reviewer/label), gdy GitHub je odrzucił. Osobny
# kontroler jak TaskCommentsController — to cykl poboczny decyzji, sama decyzja
# jest już na PR-ze. Failed wraca do queued i job próbuje jeszcze raz.
class FollowupActionsController < ApplicationController
  def create
    review = Review.find(params[:review_id])
    requeue = { followup_reviewer_status: review.followup_reviewer_status,
                followup_label_status: review.followup_label_status }
                .transform_values { |status| status == "failed" ? "queued" : status }
    return redirect_to(review_path(review), alert: "Nie ma czego ponawiać") unless requeue.value?("queued")

    review.update!(requeue)
    FollowupActionsJob.perform_later(review)
    redirect_to review_path(review), notice: "Ponawiam akcje na PR-ze"
  end
end
