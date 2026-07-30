require "test_helper"

class TaskLinkTest < ActiveSupport::TestCase
  PREFIX = "https://tracker.example.com/organize/tasks/"

  def find(text) = TaskLink.find(text, prefix: PREFIX)

  test "should pull the task link out of a PR description" do
    assert_equal "#{PREFIX}32586", find("Zadanie: #{PREFIX}32586\n\nOpis zmian…")
  end

  # Najczęstszy zapis w opisach: markdown link, gdzie adres kończy się nawiasem.
  test "should stop the link at markdown and sentence punctuation" do
    assert_equal "#{PREFIX}32586", find("Dotyczy [#32586](#{PREFIX}32586).")
    assert_equal "#{PREFIX}32586", find("Zadanie <#{PREFIX}32586>, szczegóły niżej")
    assert_equal "#{PREFIX}32586", find("(#{PREFIX}32586)")
  end

  test "should ignore other links in the description" do
    body = "Poprzedni PR https://github.com/acme/webapp/pull/14 i dokumentacja https://example.com/doc"
    assert_nil find(body)
  end

  test "should take the first task link when the description mentions several" do
    assert_equal "#{PREFIX}1", find("#{PREFIX}1 oraz #{PREFIX}2")
  end

  # Bez prefiksu na projekcie autouzupełnianie jest wyłączone — inaczej wciągałoby
  # pierwszy dowolny URL z opisu.
  test "should stay silent without a configured prefix" do
    assert_nil TaskLink.find("cokolwiek #{PREFIX}5", prefix: nil)
    assert_nil TaskLink.find("cokolwiek #{PREFIX}5", prefix: "")
  end

  test "should handle an empty description" do
    assert_nil find(nil)
    assert_nil find("")
  end
end
