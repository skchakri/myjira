class AddAgentToSessionLaunches < ActiveRecord::Migration[8.1]
  def change
    # Provenance: a launch that came from clicking an agent in the strip points
    # back at it, so the "Launching" row can show "▶ security-auditor".
    add_reference :session_launches, :agent, type: :uuid, null: true, foreign_key: true
  end
end
