namespace :work_queue do
  desc "Recount the Work Queue cost totals (per item, day, phase and model) from the recorded runner phases"
  task rebuild_costs: :environment do
    rows = WorkQueue::Costs.rebuild!
    overview = WorkQueue::Costs.overview
    puts "Recounted #{rows} phase records: $#{format('%.2f', overview.total)} across #{overview.projects.size} projects"
  end
end
