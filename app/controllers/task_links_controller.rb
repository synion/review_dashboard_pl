# Potwierdzenie zadania PR-a, gdy TaskLinkCheck nie był pewny linku. Człowiek
# zatwierdza wybrany link albo wkleja właściwy — dopiero wtedy ruszają opis
# zadania, bramka zgodności i komentarz do trackera.
class TaskLinksController < ApplicationController
  def update
    review = Review.find(params[:review_id])
    url = params[:task_url].to_s.strip.presence || review.task_url
    return redirect_to(review, alert: "Podaj link do zadania") if url.blank?

    changed = url != review.task_url
    if changed && %w[queued running].include?(review.task_description_status)
      return redirect_to(review, alert: "Opis zadania właśnie się generuje — zmień link, gdy skończy")
    end

    attrs = { task_url: url, task_link_status: "confirmed", task_link_note: nil }
    # Inne zadanie = wszystko, co dashboard o zadaniu wie, dotyczy starego.
    attrs.merge!(task_title: nil, task_description: nil, task_criteria: nil, task_fit: nil, task_fit_status: "skipped", task_fit_reconciliation: nil,
                 task_comments_seen: nil, task_comments_latest: nil, task_comments_checked_at: nil) if changed
    describe = changed || !%w[queued running ready].include?(review.task_description_status)
    attrs[:task_description_status] = "queued" if describe
    review.update!(attrs)

    CheckTaskCommentsJob.perform_later(review)
    if describe
      DescribeTaskJob.perform_later(review)
    elsif review.status == "reviewed"
      review.enqueue_task_fit!
    end
    redirect_to review, notice: "Zadanie potwierdzone#{" — opis zadania w kolejce" if describe}"
  end
end
