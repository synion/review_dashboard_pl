class FollowupsController < ApplicationController
  def create
    review = Review.find(params[:review_id])
    unless Review::FOLLOWUPABLE_STATUSES.include?(review.status)
      return redirect_to(review_path(review), alert: "Dyskusja możliwa tylko na zakończonym review (status: #{review.status})")
    end
    if params[:message].blank?
      return redirect_to(review_path(review), alert: "Napisz, z czym się nie zgadzasz")
    end

    # Patrz ReviewsController#start — status musi zmienić się od razu, nie dopiero
    # gdy worker zwolni wątek. Przy okazji blokuje drugie wysłanie tej samej uwagi.
    review.update!(status: "reviewing")
    FollowupReviewJob.perform_later(review, params[:message].to_s)
    redirect_to review_path(review), notice: "Wysłano do Claude — zaktualizuje review po ponownej weryfikacji"
  end
end
