# Move a project's open follow-up "gaps" onto the board as work items. A gap
# becomes a pending board item (type from kind, priority from severity), the
# follow-up is linked to it and marked resolved (moved off the open list, so the
# board is the single source of truth). Idempotent: gaps already linked to a live
# board item, or clearly covered by an existing item, are just moved (resolved).
module Board
  module GapImporter
    module_function

    KIND_TO_TYPE = {
      "bug" => "issue", "regression" => "issue", "enhancement" => "feature",
      "gap" => "task", "question" => "ask"
    }.freeze
    SEV_TO_PRIO = { "critical" => "urgent", "high" => "high", "medium" => "normal", "low" => "low" }.freeze
    PRIO_RANK   = { "urgent" => 0, "high" => 1, "normal" => 2, "low" => 3 }.freeze

    def import(project)
      created = 0
      moved = 0
      existing = project.tasks.pluck(:title).map { |t| normalize(t) }

      project.follow_up_tasks.where(status: %w[open in_progress]).order(:created_at).each do |gap|
        if gap.task_id && project.tasks.exists?(id: gap.task_id)
          gap.update!(status: "resolved") # already on the board → move it off the open list
          moved += 1
          next
        end
        n = normalize(gap.title)
        if existing.any? { |e| covered?(e, n) }
          gap.update!(status: "resolved") # an existing board item already covers it
          moved += 1
          next
        end
        task = project.tasks.create!(
          title: gap.title, description: gap.description,
          item_type: KIND_TO_TYPE[gap.kind] || "task",
          priority: SEV_TO_PRIO[gap.severity] || "normal",
          board_state: "pending", source: "gap-import"
        )
        gap.update!(task_id: task.id, status: "resolved")
        existing << n
        created += 1
      end

      reorder_pending(project) if created.positive?
      { created: created, moved: moved }
    end

    # Re-order the pending queue by severity (urgent→low), oldest first.
    def reorder_pending(project)
      project.tasks.where(board_state: "pending").to_a
             .sort_by { |t| [PRIO_RANK[t.priority] || 9, t.created_at] }
             .each_with_index { |t, i| t.update_columns(position: i + 1, updated_at: Time.current) } # rubocop:disable Rails/SkipsModelValidations
    end

    def normalize(str)
      str.to_s.downcase.gsub(/[^a-z0-9]/, "")[0, 40].to_s
    end

    def covered?(existing_norm, gap_norm)
      return false if gap_norm.length < 10
      existing_norm[0, 26] == gap_norm[0, 26] ||
        existing_norm.include?(gap_norm[0, 22]) || gap_norm.include?(existing_norm[0, 22])
    end
  end
end
