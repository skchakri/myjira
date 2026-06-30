module Api
  module V1
    class TasksController < BaseController
      before_action :find_project!

      def index
        render json: @project.tasks.board_ordered.map { |t| serialize(t) }
      end

      def show
        render json: serialize(@project.tasks.find(params[:id]), detailed: true)
      end

      def create
        # Dedup at the boundary: if an open board item is an exact restatement of
        # this title, return it (idempotently) instead of creating a near-identical
        # pending row. This is what stops the uncoordinated producers (review agent,
        # self-improve, captured sessions) from flooding the pending column.
        if (dup = @project.open_board_duplicate(task_params[:title]))
          return render json: serialize(dup, detailed: true).merge(deduped: true, next_steps: next_steps_for(dup))
        end
        task = @project.tasks.new(task_params)
        resolve_environment(task)
        task.save!
        render json: serialize(task, detailed: true).merge(next_steps: next_steps_for(task)), status: :created
      end

      def update
        task = @project.tasks.find(params[:id])
        attrs = task_params
        # The approval gate: an agent may report a finished plan as board_state
        # "planned", but in the assisted workflow nothing executes without human
        # approval. Convert it to waiting:awaiting_approval here. The ONLY path to
        # "planned" is BoardsController#approve. (Engineering/answer agents move to
        # in_review/done/failed, never "planned", so they are unaffected.)
        if attrs[:board_state].to_s == "planned"
          attrs[:board_state] = "waiting"
          attrs[:wait_reason] = "awaiting_approval"
        end
        task.assign_attributes(attrs)
        resolve_environment(task)
        task.plan_updated_at = Time.current if task.plan_changed?
        task.finished_at ||= Time.current if task.board_state_changed? && %w[in_review done].include?(task.board_state)
        task.implemented_at ||= Time.current if task.status_changed? && %w[implemented ready_for_test].include?(task.status)
        task.save!
        # board_state changes already broadcast from the model; refresh the board for
        # the other on-board edits agents make (e.g. triage assigning title/type/priority).
        if (task.saved_changes.keys & %w[title item_type priority agent_role]).any? && !task.saved_change_to_board_state?
          Turbo::StreamsChannel.broadcast_refresh_to([@project, :board])
        end
        render json: serialize(task, detailed: true).merge(next_steps: next_steps_for(task))
      end

      # The engineering/debugger agent calls this once coding is done: it fires the
      # auto-test leg (headless Playwright + a relay/Claude-in-Chrome visual ticket)
      # for the item's latest test plan and returns the run so the agent can poll it.
      def finish
        task = @project.tasks.find(params[:id])
        task.update!(finished_at: Time.current) if task.finished_at.blank?
        run = Board::TestLeg.run!(task, initiated_by: params[:initiated_by].presence || "agent")
        if run
          render json: {
            ok: true,
            test_run: { id: run.id, status: run.status, total_cases: run.total_cases },
            poll: "#{base_url}/api/v1/test_runs/#{run.id}",
            web: "#{base_url}/test_runs/#{run.id}",
            instructions: "Poll the run until status is passed/failed/partial. On pass: " \
                          "open a PR off main and PATCH this task {board_state:'in_review', pr_url, pr_number, " \
                          "pr_state:'open', pr_diff, branch_name}. On fail: PATCH {board_state:'failed', agent_notes}."
          }
        else
          render json: {
            ok: false,
            message: "No test plan attached to this task yet. Create one first: " \
                     "POST #{base_url}/api/v1/projects/#{@project.slug}/test_plans then add cases, then call finish again."
          }, status: :unprocessable_entity
        end
      end

      private

      BOARD_FIELDS = %i[item_type board_state agent_role position plan branch_name
                        pr_url pr_number pr_state pr_diff agent_notes changelog_summary
                        pr_mergeable conflict_resolution_at wait_reason].freeze

      def task_params
        raw = params[:task] || params
        raw.permit(:title, :description, :implementation_notes, :external_ref, :status,
                   :priority, :source, :environment_id, :labels_text, *BOARD_FIELDS,
                   labels: [], pending_questions: [%i[id q a]])
      end

      def resolve_environment(task)
        env_name = params[:environment] || params.dig(:task, :environment)
        return if env_name.blank? && task.environment_id.present?
        return if env_name.blank?
        env = @project.environments.find_or_create_by!(name: env_name)
        task.environment = env
      end

      def serialize(task, detailed: false)
        data = {
          id: task.id, title: task.title, status: task.status, priority: task.priority,
          item_type: task.item_type, board_state: task.board_state, agent_role: task.agent_role,
          position: task.position, labels: task.labels,
          source: task.source, external_ref: task.external_ref,
          environment: task.environment&.name,
          pr: task.pr_url.present? ? { url: task.pr_url, number: task.pr_number, state: task.pr_state, branch: task.branch_name } : nil,
          implemented_at: task.implemented_at,
          created_at: task.created_at, updated_at: task.updated_at,
          urls: {
            web: "#{base_url}/projects/#{@project.slug}/tasks/#{task.id}",
            board: "#{base_url}/projects/#{@project.slug}/board",
            api: "#{base_url}/api/v1/projects/#{@project.slug}/tasks/#{task.id}"
          }
        }
        if detailed
          data[:description] = task.description
          data[:attachments] = task.attachments.map do |a|
            { filename: a.filename.to_s, content_type: a.content_type, byte_size: a.byte_size,
              url: "#{base_url}#{Rails.application.routes.url_helpers.rails_blob_path(a, only_path: true)}" }
          end
          data[:plan] = task.plan
          data[:changelog_summary] = task.changelog_summary
          data[:implementation_notes] = task.implementation_notes
          data[:agent_notes] = task.agent_notes
          data[:test_plans] = task.test_plans.map { |p| { id: p.id, title: p.title, status: p.status } }
          data[:latest_test_run] = task.last_test_run&.then { |r| { id: r.id, status: r.status } }
          data[:follow_ups] = task.follow_up_tasks.order(created_at: :desc).map { |f| { id: f.id, title: f.title, severity: f.severity, status: f.status, kind: f.kind } }
        end
        data
      end
    end
  end
end
