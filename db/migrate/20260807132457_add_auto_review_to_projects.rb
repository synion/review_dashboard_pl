# Dwa niezależne przełączniki automatu per projekt — nie jeden wspólny: „zleć review
# każdej nowej prośbie" i „sprawdź PR, który wrócił po poprawkach" mają różne koszty
# (pierwszy zakłada review i pali pełną sesję, drugi tylko wznawia istniejącą).
#
# `autostart` na review, bo decyzja o samoczynnym starcie zapada przy ZAKŁADANIU
# rekordu, a wykonuje ją DescribeReviewJob kilka minut później — bez kolumny musiałby
# zgadywać z ustawienia projektu, które w międzyczasie ktoś mógł przestawić.
class AddAutoReviewToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :auto_review_requested, :boolean, default: false, null: false
    add_column :projects, :auto_review_returned, :boolean, default: false, null: false
    add_column :reviews, :autostart, :boolean, default: false, null: false
  end
end
