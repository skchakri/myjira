module Projects
  # One-time cleanup: every agent worktree used to be registered as its own
  # project (ownsites-wq-193, agent-a1cc…). This folds each of those into the
  # project of its parent repo: re-parents every row that points at it, then
  # archives (never deletes) the emptied worktree project.
  #
  #   Projects::WorktreeFolder.new(dry_run: true).call   # report only, writes nothing
  #   Projects::WorktreeFolder.new(dry_run: false).call  # move + archive
  #
  # Rows that would break a unique index on the parent are handled per table
  # (see COLLISIONS). A worktree project whose parent repo has no project is
  # reported and left alone.
  class WorktreeFolder
    # Every table with a project_id column (checked against db/schema.rb).
    TABLES = %w[
      agent_schedules agents browser_tasks calendar_jobs conversations documents environments
      follow_up_tasks knowledge_facts mcp_installs mcp_servers playbooks session_launches
      tasks test_plans worklog_events
    ].freeze

    # Unique indexes scoped to a project: [columns that must stay unique, what happens to a clash].
    COLLISIONS = {
      "environments" => [%w[name], "refs re-pointed to the parent's environment, duplicate removed"],
      "agents" => [%w[kind name], "refs re-pointed to the parent's agent, duplicate removed"],
      "mcp_servers" => [%w[scope name], "duplicate removed (the parent already lists that server)"],
      "knowledge_facts" => [%w[fingerprint], "merged into the parent's fact (times seen added, newest seen kept)"],
      "documents" => [%w[slug], "kept, slug suffixed with the worktree's slug"]
    }.freeze

    # Rows elsewhere that point at a duplicate about to be removed.
    REFERENCES = {
      "environments" => [%w[tasks environment_id], %w[test_runs environment_id]],
      "agents" => [%w[agent_schedules agent_id], %w[playbooks agent_id], %w[session_launches agent_id]]
    }.freeze

    Fold = Struct.new(:project, :parent, :moves, :clashes, keyword_init: true) do
      def rows = moves.values.sum + clashes.values.sum
    end
    Result = Struct.new(:folds, :unresolved, :dry_run, keyword_init: true)

    def initialize(dry_run: true, out: $stdout)
      @dry_run = dry_run
      @out = out
    end

    def call
      folds = []
      unresolved = []
      worktree_projects.each do |project|
        parent = parent_of(project)
        next unresolved << project unless parent

        fold = plan(project, parent)
        apply(fold) unless @dry_run
        folds << fold
      end
      Result.new(folds: folds, unresolved: unresolved, dry_run: @dry_run).tap { |r| report(r) }
    end

    private

    def conn = ActiveRecord::Base.connection

    def worktree_projects
      Project.active.where.not(repo_path: [nil, ""]).order(:repo_path).select(&:worktree?)
    end

    # The parent repo's own project: live, not this one, and not itself a worktree.
    def parent_of(project)
      repo = Project.canonical_repo_path(project.repo_path)
      Project.where(repo_path: repo).where.not(id: project.id).order(Arel.sql("archived_at IS NOT NULL"), :created_at).first
    end

    def plan(project, parent)
      moves = {}
      clashes = {}
      TABLES.each do |table|
        total = count(table, project.id)
        next if total.zero?

        clash = clash_ids(table, project.id, parent.id).size
        moves[table] = total - clash if total > clash
        clashes[table] = clash if clash.positive?
      end
      Fold.new(project: project, parent: parent, moves: moves, clashes: clashes)
    end

    def count(table, project_id)
      conn.select_value("SELECT COUNT(*) FROM #{table} WHERE project_id = #{conn.quote(project_id)}").to_i
    end

    # [[worktree row id, parent row id]] for rows the parent already has under the same unique key.
    def clash_ids(table, from_id, to_id)
      cols, = COLLISIONS[table]
      return [] unless cols

      on = cols.map { |c| "w.#{c} = p.#{c}" }.join(" AND ")
      conn.select_rows(<<~SQL.squish)
        SELECT w.id, p.id FROM #{table} w JOIN #{table} p ON #{on}
        WHERE w.project_id = #{conn.quote(from_id)} AND p.project_id = #{conn.quote(to_id)}
      SQL
    end

    def apply(fold)
      from = fold.project.id
      to = fold.parent.id
      Project.transaction do
        resolve_clashes(fold, from, to)
        TABLES.each do |table|
          conn.update("UPDATE #{table} SET project_id = #{conn.quote(to)} WHERE project_id = #{conn.quote(from)}")
        end
        fold.project.update_columns(archived_at: Time.current,
                                    description: [fold.project.description.presence,
                                                  "Worktree of #{fold.parent.slug}; folded into it #{Date.current}."].compact.join("\n"))
      end
    end

    def resolve_clashes(fold, from, to)
      fold.clashes.each_key do |table|
        pairs = clash_ids(table, from, to)
        case table
        when "documents"
          ids = pairs.map(&:first)
          suffix = conn.quote("-from-#{fold.project.slug}")
          conn.update("UPDATE documents SET slug = slug || #{suffix} WHERE id IN (#{quote_list(ids)})")
        when "knowledge_facts"
          pairs.each { |dup, keep| merge_fact(dup, keep) }
        else
          pairs.each { |dup, keep| replace(table, dup, keep) }
        end
      end
    end

    def merge_fact(dup, keep)
      conn.update(<<~SQL.squish)
        UPDATE knowledge_facts k SET times_seen = k.times_seen + d.times_seen,
          last_seen_at = GREATEST(k.last_seen_at, d.last_seen_at)
        FROM knowledge_facts d WHERE k.id = #{conn.quote(keep)} AND d.id = #{conn.quote(dup)}
      SQL
      conn.delete("DELETE FROM knowledge_facts WHERE id = #{conn.quote(dup)}")
    end

    def replace(table, dup, keep)
      Array(REFERENCES[table]).each do |ref_table, column|
        conn.update("UPDATE #{ref_table} SET #{column} = #{conn.quote(keep)} WHERE #{column} = #{conn.quote(dup)}")
      end
      conn.delete("DELETE FROM #{table} WHERE id = #{conn.quote(dup)}")
    end

    def quote_list(ids) = ids.map { |id| conn.quote(id) }.join(", ")

    def report(result)
      verb = result.dry_run ? "would fold" : "folded"
      @out.puts result.dry_run ? "DRY RUN: nothing was changed. Run with DRY_RUN=0 to apply." : "APPLIED."
      @out.puts
      result.folds.group_by(&:parent).sort_by { |parent, _| parent.slug }.each do |parent, folds|
        @out.puts "#{parent.slug}  (#{parent.repo_path})  <- #{folds.size} worktree project#{'s' unless folds.size == 1}"
        folds.each { |fold| @out.puts "  #{fold.project.slug.ljust(34)} #{describe(fold)}" }
      end
      totals(result, verb)
      unresolved(result)
    end

    def describe(fold)
      parts = fold.moves.map { |table, n| "#{table}=#{n}" }
      parts += fold.clashes.map { |table, n| "#{table}(clash)=#{n}" }
      parts.presence&.join(" ") || "empty"
    end

    def totals(result, verb)
      moves = Hash.new(0)
      clashes = Hash.new(0)
      result.folds.each do |fold|
        fold.moves.each { |table, n| moves[table] += n }
        fold.clashes.each { |table, n| clashes[table] += n }
      end
      @out.puts
      @out.puts "#{verb} #{result.folds.size} worktree projects into #{result.folds.map(&:parent).uniq.size} parents, then archive them"
      @out.puts "rows re-parented:"
      moves.sort.each { |table, n| @out.puts "  #{table.ljust(20)} #{n}" }
      @out.puts "  (none)" if moves.empty?
      return if clashes.empty?

      @out.puts "rows the parent already has (unique-index clashes):"
      clashes.sort.each { |table, n| @out.puts "  #{table.ljust(20)} #{n.to_s.ljust(6)} #{COLLISIONS[table].last}" }
    end

    def unresolved(result)
      return if result.unresolved.empty?

      @out.puts
      @out.puts "left alone: #{result.unresolved.size} worktree projects whose parent repo has no project"
      result.unresolved.each { |p| @out.puts "  #{p.slug.ljust(34)} #{p.repo_path}" }
    end
  end
end
