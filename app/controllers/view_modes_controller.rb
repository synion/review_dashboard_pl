# Przełącznik układu strony wejściowej. Ciasteczko permanent, bo wybór ma przeżyć
# zamknięcie przeglądarki — inaczej trzeba by go klikać co rano.
class ViewModesController < ApplicationController
  def update
    mode = params[:mode].to_s
    cookies.permanent[ViewModeHelper::COOKIE] = ViewModeHelper::MODES.include?(mode) ? mode : ViewModeHelper::DEFAULT_MODE
    # Wracamy tam, skąd przyszliśmy: przycisk siedzi w topbarze, więc przełącza się
    # go także z listy review czy z panelu, nie tylko ze strony wejściowej.
    redirect_back fallback_location: root_path
  end
end
