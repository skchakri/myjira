# Evaluate a PlaybookRun — mark it passed/failed/inconclusive against its
# playbook's success criteria, then return to the playbook so its pass/fail
# history (and pass-rate) updates.
class PlaybookRunsController < ApplicationController
  def update
    run = PlaybookRun.find(params[:id])
    run.evaluate!(result: params.dig(:playbook_run, :result), notes: params.dig(:playbook_run, :notes))
    redirect_to [run.playbook.project, run.playbook], notice: "Run marked #{run.result}."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to [run.playbook.project, run.playbook], alert: "Couldn't evaluate run: #{e.record.errors.full_messages.to_sentence}"
  end
end
