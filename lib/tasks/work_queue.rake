namespace :work_queue do
  desc "Recount the Work Queue cost totals (per item, day, phase and model) from the recorded runner phases"
  task rebuild_costs: :environment do
    rows = WorkQueue::Costs.rebuild!
    overview = WorkQueue::Costs.overview
    puts "Recounted #{rows} phase records: $#{format('%.2f', overview.total)} across #{overview.projects.size} projects"
  end

  # Worktrees and branches left behind by tasks that were delivered before the runner
  # started cleaning up by itself (see WorkQueue::WorktreeCleaner). Run it on the host,
  # as the user who owns the repos: it has to see the sessions working in a worktree.
  #
  #   bin/rails work_queue:cleanup_worktrees             # dry run: report only
  #   bin/rails work_queue:cleanup_worktrees VERBOSE=1   # dry run, one line per task
  #   bin/rails work_queue:cleanup_worktrees DRY_RUN=0   # remove, and log on each task
  desc "Remove the worktrees, local and origin branches of tasks whose PR is merged and deployed (DRY_RUN=1 by default). Calls gh."
  task cleanup_worktrees: :environment do
    WorkQueue::WorktreeCleaner.new.sweep(dry_run: ENV.fetch("DRY_RUN", "1") != "0", verbose: ENV["VERBOSE"] == "1")
  end

  desc "Refresh PR, delivery and repo deploy status for every done task with a PR (the Releases page reads it). " \
       "The watcher does this continuously for tasks updated in the last 14 days; this covers older ones. Calls gh."
  task refresh_delivery: :environment do
    store = WorkQueue::Store.new
    items = store.all.select { |i| i.status == "done" && i.pr.present? }.uniq(&:pr)
    items.each { |item| WorkQueue::StatusCache.refresh(item, store: store) }
    releases = WorkQueue::Releases.new(store: store)
    puts "Refreshed #{items.size} pull requests: #{releases.pending_count} merged tasks not live in #{releases.repos.size} repos; " \
         "#{releases.no_workflow.size} repos without a Deploy workflow"
  end
end
