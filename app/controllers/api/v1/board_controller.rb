module Api
  module V1
    # Host launcher daemon ↔ board PR reconciliation. The daemon has GitHub access
    # (`gh`); the container doesn't. Each loop it GETs #pr_sync (what to merge /
    # poll), runs gh, then POSTs the outcomes to #pr_sync_apply. No auth, local-only.
    class BoardController < BaseController
      def pr_sync
        render json: Board::PrSync.work
      end

      def pr_sync_apply
        applied = Array(params[:results]).filter_map do |r|
          task = Task.find_by(id: r[:task_id])
          next unless task

          result = Board::PrSync.apply!(task, action: r[:action], ok: to_bool(r[:ok]),
                                              state: r[:state], mergeable: r[:mergeable], error: r[:error])
          { task_id: task.id, result: result }
        end
        render json: { applied: applied }
      end

      private

      def to_bool(value)
        ActiveModel::Type::Boolean.new.cast(value)
      end
    end
  end
end
