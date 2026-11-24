namespace :work_queue do
  desc "Recount the Work Queue cost totals (per item, day, phase and model) from the recorded runner phases"
  task rebuild_costs: :environment do
    rows = WorkQueue::Costs.rebuild!
    overview = WorkQueue::Costs.overview
    puts "Recounted #{rows} phase records: $#{format('%.2f', overview.total)} across #{overview.projects.size} projects"
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
