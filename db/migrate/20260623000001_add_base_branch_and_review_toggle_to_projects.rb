# Per-project autopilot refinements:
#   base_branch — the branch agents fork from and target PRs at (default "main"
#     when blank). Lets non-main repos (e.g. iCentris/pyr on 2.3) run the pipeline.
#   autopilot_review_enabled — when false, the daily review agent does NOT run for
#     this project (the human adds items by hand); the plan→build→test→PR pipeline
#     still runs autonomously on whatever items exist.
class AddBaseBranchAndReviewToggleToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :base_branch, :string
    add_column :projects, :autopilot_review_enabled, :boolean, null: false, default: true
  end
end
