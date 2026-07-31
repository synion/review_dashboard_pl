# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_31_061534) do
  create_table "claude_runs", force: :cascade do |t|
    t.integer "cache_creation_tokens"
    t.integer "cache_read_tokens"
    t.string "claude_config"
    t.integer "context_tokens"
    t.integer "context_window"
    t.decimal "cost_usd", precision: 10, scale: 4
    t.datetime "created_at", null: false
    t.integer "duration_ms"
    t.string "effort"
    t.text "error_message"
    t.datetime "finished_at"
    t.string "kind"
    t.text "last_message"
    t.string "model"
    t.integer "pid"
    t.string "resume_session_id"
    t.integer "review_id", null: false
    t.string "session_id"
    t.datetime "started_at"
    t.string "status"
    t.integer "supervisor_pid"
    t.datetime "updated_at", null: false
    t.text "user_message"
    t.index ["review_id"], name: "index_claude_runs_on_review_id"
  end

  create_table "findings", force: :cascade do |t|
    t.text "body"
    t.datetime "created_at", null: false
    t.string "file_location"
    t.text "fix_note"
    t.string "fix_status"
    t.string "priority"
    t.integer "review_id", null: false
    t.string "title"
    t.datetime "updated_at", null: false
    t.string "verdict"
    t.text "verdict_note"
    t.index ["review_id"], name: "index_findings_on_review_id"
  end

  create_table "inbox_items", force: :cascade do |t|
    t.string "actor"
    t.string "author"
    t.datetime "created_at", null: false
    t.integer "pr_number"
    t.integer "project_id", null: false
    t.string "reason"
    t.datetime "signal_at"
    t.string "task_url"
    t.string "title"
    t.datetime "updated_at", null: false
    t.string "url"
    t.index ["project_id", "pr_number"], name: "index_inbox_items_on_project_id_and_pr_number", unique: true
    t.index ["project_id"], name: "index_inbox_items_on_project_id"
  end

  create_table "playwright_runs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "exit_code"
    t.string "mode"
    t.string "output_path"
    t.integer "review_id", null: false
    t.string "status"
    t.datetime "updated_at", null: false
    t.index ["review_id"], name: "index_playwright_runs_on_review_id"
  end

  create_table "projects", force: :cascade do |t|
    t.datetime "archived_at"
    t.datetime "created_at", null: false
    t.string "default_claude_config"
    t.string "default_effort"
    t.string "default_model"
    t.string "docs_path", default: "doc/llm"
    t.datetime "inbox_checked_at"
    t.datetime "main_at"
    t.string "name"
    t.string "repo_path"
    t.string "repo_url"
    t.text "review_prompt_extra"
    t.text "task_comment_instructions"
    t.string "task_url_prefix"
    t.datetime "updated_at", null: false
    t.string "worktree_command"
    t.string "worktree_delete_command"
  end

  create_table "reviews", force: :cascade do |t|
    t.string "branch"
    t.string "claude_config"
    t.datetime "created_at", null: false
    t.datetime "decided_at"
    t.string "decision"
    t.text "decision_body"
    t.string "decision_head_sha"
    t.text "description"
    t.string "effort"
    t.text "error_message"
    t.datetime "findings_verified_at"
    t.datetime "fixes_checked_at"
    t.datetime "github_checked_at"
    t.string "model"
    t.string "playwright_command"
    t.string "playwright_test_path"
    t.integer "pr_number"
    t.string "pr_title"
    t.string "pr_url"
    t.integer "project_id", null: false
    t.text "raw_result"
    t.json "scope"
    t.string "status", default: "created", null: false
    t.text "summary"
    t.text "task_comment"
    t.text "task_comment_instructions"
    t.string "task_comment_status", default: "skipped", null: false
    t.text "task_description"
    t.string "task_description_status", default: "skipped", null: false
    t.string "task_url"
    t.datetime "updated_at", null: false
    t.string "worktree_path"
    t.index ["project_id"], name: "index_reviews_on_project_id"
  end

  add_foreign_key "claude_runs", "reviews"
  add_foreign_key "findings", "reviews"
  add_foreign_key "inbox_items", "projects"
  add_foreign_key "playwright_runs", "reviews"
  add_foreign_key "reviews", "projects"
end
