# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

# The "general" project is the home of the shared CLI ⇄ Claude-in-Chrome relay
# channel. It is not tied to a repo — any Claude session files browser
# instructions here. Idempotent.
Project.find_or_create_by!(slug: "general") do |p|
  p.name = "General"
  p.description = "Shared relay channel between Claude CLI and Claude-in-Chrome."
end
