# Fleet management for the project-board autopilot. The autonomous flow (review →
# plan → engineer/debug → test → PR) runs whenever a project has autopilot
# enabled; these tasks turn it on/off across projects (by slug or category) and
# show the fleet state.
#
#   bin/rails board:status
#   bin/rails board:enable SLUGS=plan-my-trip,ownsites CAP=4
#   bin/rails board:enable CATEGORY=pyr CAP=2 REVIEW=off BASE=2.3
#   bin/rails board:disable SLUGS=plan-my-trip            # or CATEGORY=pyr / SLUGS=ALL
#   bin/rails board:stop      # global kill switch (all projects)
#   bin/rails board:resume
#   bin/rails board:tick      # run one orchestrator step now
namespace :board do
  desc "Show autopilot status across all projects with a repo"
  task status: :environment do
    fmt = "%-22s %-9s %-4s %-6s %-4s %-8s %-8s\n"
    printf(fmt, "PROJECT", "CATEGORY", "AP", "PAUSE", "CAP", "PENDING", "INFLIGHT")
    Project.where.not(repo_path: [nil, ""]).order(:category, :slug).each do |p|
      printf(fmt, p.slug.truncate(22), p.category, p.autopilot_enabled? ? "on" : "-",
             p.autopilot_paused? ? "yes" : "-", p.autopilot_daily_cap,
             p.tasks.where(board_state: "pending").count, p.inflight_board_launch? ? "yes" : "-")
    end
    puts "\nglobal stopped: #{Setting.autopilot_stopped?}   " \
         "running now: #{Autopilot::Orchestrator.global_inflight_count}/#{Autopilot::Orchestrator::GLOBAL_MAX_CONCURRENT}   " \
         "review hour (UTC): #{Autopilot::Orchestrator::REVIEW_HOUR}"
  end

  desc "Enable autopilot. SLUGS=a,b or CATEGORY=pyr required; CAP, REVIEW=on|off, BASE optional"
  task enable: :environment do
    scope = board_scope
    cap = (ENV["CAP"].presence || 5).to_i
    attrs = { autopilot_enabled: true, autopilot_paused: false, autopilot_daily_cap: cap }
    attrs[:autopilot_review_enabled] = (ENV["REVIEW"] != "off") if ENV["REVIEW"].present?
    attrs[:base_branch] = ENV["BASE"] if ENV["BASE"].present?
    scope.find_each do |p|
      if p.repo_path.blank?
        puts "skip #{p.slug} (no repo_path)"
      else
        p.update!(attrs)
        puts "enabled #{p.slug} (#{p.category}, cap #{cap}, review #{p.autopilot_review_enabled? ? 'on' : 'off'}, base #{p.base_branch_or_default})"
      end
    end
  end

  desc "Disable autopilot. SLUGS=a,b or CATEGORY=pyr or SLUGS=ALL"
  task disable: :environment do
    scope = ENV["SLUGS"].to_s.strip == "ALL" ? Project.where(autopilot_enabled: true) : board_scope
    scope.find_each { |p| p.update!(autopilot_enabled: false); puts "disabled #{p.slug}" }
  end

  desc "Global kill switch: stop all autopilot"
  task stop: :environment do
    Setting.autopilot_stopped = true
    puts "autopilot globally STOPPED (in-flight sessions finish; nothing new launches)"
  end

  desc "Resume global autopilot"
  task resume: :environment do
    Setting.autopilot_stopped = false
    puts "autopilot resumed"
  end

  desc "Run one orchestrator tick now"
  task tick: :environment do
    require "pp"
    pp Autopilot::Orchestrator.tick!
  end

  desc "Move open follow-up gaps onto the board. Default all projects; or SLUGS / CATEGORY"
  task import_gaps: :environment do
    scope = ENV["SLUGS"].present? || ENV["CATEGORY"].present? ? board_scope : Project.where.not(repo_path: [nil, ""])
    totals = { created: 0, moved: 0 }
    scope.find_each do |p|
      r = Board::GapImporter.import(p)
      next if r[:created].zero? && r[:moved].zero?
      puts "#{p.slug}: created #{r[:created]}, moved #{r[:moved]}"
      totals[:created] += r[:created]
      totals[:moved]   += r[:moved]
    end
    puts "TOTAL: created #{totals[:created]}, moved #{totals[:moved]}"
  end

  # Resolve the target projects from SLUGS=a,b,c or CATEGORY=pyr.
  def board_scope
    slugs = ENV["SLUGS"].to_s.split(",").map(&:strip).reject(&:blank?)
    return Project.where(slug: slugs) if slugs.any?
    cat = ENV["CATEGORY"].to_s.strip
    abort "Specify SLUGS=a,b,c or CATEGORY=pyr|skchakri|icentris|other" if cat.blank?
    Project.where(category: cat)
  end
end
