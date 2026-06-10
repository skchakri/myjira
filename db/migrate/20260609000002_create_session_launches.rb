class CreateSessionLaunches < ActiveRecord::Migration[8.1]
  def change
    # A request, filed from the web, to spin up a *new* interactive Claude CLI
    # session in a project's repo. A host-side daemon (myjira_session_launcher.py)
    # polls these, spawns `claude` in a tmux window inside repo_path, and reports
    # status back. The launched session is told to use our pre-generated
    # session_id (claude --session-id), so the conversation that streams in via
    # the sync hook is the SAME record we pre-create here.
    create_table :session_launches, id: :uuid do |t|
      t.references :project, null: false, type: :uuid, foreign_key: true
      # The conversation this launch becomes — pre-created so it shows in the grid
      # the instant you click Launch; nullify on destroy keeps launch history.
      t.references :conversation, null: true, type: :uuid, foreign_key: true

      t.string :session_id, null: false        # pre-generated UUID → claude --session-id
      t.string :repo_path,  null: false        # host folder the daemon cd's into
      t.text   :prompt,     null: false        # the initial prompt to run
      t.string :model                          # optional --model override
      t.string :permission_mode                # optional --permission-mode override

      # pending → launching (daemon claimed) → launched | failed | canceled
      t.string   :status, null: false, default: "pending"
      t.string   :tmux_target                  # e.g. "myjira:stampinup-pyr-a1b2c3"
      t.text     :error                        # daemon failure detail, if any
      t.datetime :launched_at

      t.timestamps
    end

    add_index :session_launches, :status
    add_index :session_launches, :session_id, unique: true
  end
end
