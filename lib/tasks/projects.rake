# Fold the projects that were auto-created for agent worktrees into the project
# of their parent repo (see Projects::WorktreeFolder).
#
#   bin/rails projects:fold_worktrees             # dry run: report only
#   bin/rails projects:fold_worktrees DRY_RUN=0   # re-parent rows, archive the worktree projects
namespace :projects do
  desc "Fold agent-worktree projects into their parent repo's project (DRY_RUN=1 by default)"
  task fold_worktrees: :environment do
    Projects::WorktreeFolder.new(dry_run: ENV.fetch("DRY_RUN", "1") != "0").call
  end
end
