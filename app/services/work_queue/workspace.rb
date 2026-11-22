module WorkQueue
  # Projects that can hold a queue: existing queue files plus myjira projects
  # with a repo_path. Queue slugs use the mod's rule: repo path with every
  # non-alphanumeric run replaced by "-".
  module Workspace
    module_function

    def slug_for(path) = path.to_s.gsub(/[^A-Za-z0-9]+/, "-").gsub(/\A-|-\z/, "")

    # [[label, slug, repo_path or nil]]
    def choices
      from_projects = Project.where.not(repo_path: [nil, ""]).pluck(:name, :repo_path).map { |n, r| [n, slug_for(r), r] }
      known = from_projects.map(&:second)
      from_files = Dir.glob(Store.dir.join("*.json")).map { |f| Store.slug_for(f) }.reject { |s| known.include?(s) }
      (from_projects + from_files.map { |s| [Store.label(s), s, nil] }).sort_by(&:first)
    end

    def repo_for(slug)
      Project.where.not(repo_path: [nil, ""]).pluck(:repo_path).find { |r| slug_for(r) == slug }
    end

    # Running as root in the container: hand new worktrees back to the repo's owner.
    def match_owner(path, like)
      return unless Process.uid.zero?

      st = File.stat(like)
      system("chown", "-R", "#{st.uid}:#{st.gid}", path)
    end
  end
end
