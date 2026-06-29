# A hand-written static "project memory" block — conventions, where things live,
# gotchas — that gets prepended into every agent launch's prompt so each session
# starts already knowing the lay of the land. Editable in the project form; pairs
# with the auto-accumulating knowledge_facts (see CreateKnowledgeFacts).
class AddMemoryPreambleToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :memory_preamble, :text
  end
end
