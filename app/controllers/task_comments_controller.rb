# Ponowienie komentarza do zadania po porażce (np. odświeżona sesja trackera).
# Osobny kontroler, bo to cykl poboczny decyzji — DecisionsController wysyła
# decyzję na GitHub, tu tylko kolejkujemy sesję komentującą jeszcze raz.
class TaskCommentsController < ApplicationController
  def create
    review = Review.find(params[:review_id])
    return redirect_to(review, alert: "Ten review nie ma linku do zadania") if review.task_url.blank?

    # Guard na podwójny klik jak przy opisie zadania: drugi job w locie pisałby
    # po tym samym polu.
    if %w[queued running].include?(review.task_comment_status)
      return redirect_to(review, alert: "Komentarz do zadania już się dodaje")
    end

    review.update!(task_comment_status: "queued")
    CommentTaskJob.perform_later(review)
    redirect_to review
  end
end
