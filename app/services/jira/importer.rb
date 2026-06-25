module Jira
  # Orchestrates importing one Jira issue into a project's board as a Task.
  # Idempotent on the Jira key (tasks.external_ref): re-import updates the same
  # item (refreshing Jira-derived fields) and never duplicates attachments.
  module Importer
    module_function

    Result = Struct.new(:task, :created, :attachments_added, :attachments_skipped, keyword_init: true)

    TYPE_MAP = {
      "Bug" => "issue", "Story" => "task", "Task" => "task", "Sub-task" => "task",
      "Epic" => "feature", "Improvement" => "feature", "New Feature" => "feature",
      "Question" => "ask"
    }.freeze
    PRIORITY_MAP = {
      "Highest" => "urgent", "Critical" => "urgent", "High" => "high",
      "Medium" => "normal", "Low" => "low", "Lowest" => "low"
    }.freeze

    def import(url:, project:, connection: JiraConnection.current, client: nil)
      raise Jira::Error.new("Connect Jira first.", kind: :not_configured) unless connection&.complete?

      key, host = parse(url)
      raise Jira::Error.new("That doesn't look like a Jira ticket URL.", kind: :bad_url) if key.blank?
      if host && connection.host && host.downcase != connection.host.downcase
        raise Jira::Error.new("That URL isn't for #{connection.host}.", kind: :bad_url)
      end

      client ||= Jira::Client.new(connection)
      issue = client.fetch_issue(key)

      task = project.tasks.find_or_initialize_by(external_ref: issue[:key])
      created = task.new_record?
      task.assign_attributes(
        title: issue[:summary].presence || issue[:key],
        description: build_description(issue),
        item_type: TYPE_MAP[issue[:issue_type]] || "task",
        priority: PRIORITY_MAP[issue[:priority]] || "normal",
        source: "jira",
        external_url: url
      )
      task.board_state = "pending" if created
      task.save!

      added, skipped = sync_attachments(task, issue, client)
      Result.new(task: task, created: created, attachments_added: added, attachments_skipped: skipped)
    end

    # Extract [issue_key, host] from a Jira URL (browse link or ?selectedIssue=).
    def parse(url)
      uri = URI.parse(url.to_s)
      key = uri.path.to_s[/[A-Z][A-Z0-9]+-\d+/] ||
            uri.query.to_s[/selectedIssue=([A-Z][A-Z0-9]+-\d+)/, 1]
      [key, uri.host]
    rescue URI::InvalidURIError
      [nil, nil]
    end

    def build_description(issue)
      parts = [Jira::AdfConverter.to_markdown(issue[:description_adf])]
      unless issue[:comments].empty?
        parts << "---\n\n### Comments"
        issue[:comments].each do |c|
          parts << "**#{c[:author]}** · #{c[:created]}\n\n#{Jira::AdfConverter.to_markdown(c[:body_adf])}"
        end
      end
      parts.reject(&:blank?).join("\n\n")
    end

    # Download + attach each Jira attachment not already present (matched by
    # filename + byte size). One bad download is skipped, not fatal.
    def sync_attachments(task, issue, client)
      added = 0
      skipped = []
      Array(issue[:attachments]).each do |att|
        if task.attachments.any? { |a| a.filename.to_s == att[:filename] && a.byte_size == att[:size] }
          next
        end
        begin
          blob = client.download_attachment(att[:content_url])
          task.attachments.attach(io: blob[:io], filename: att[:filename], content_type: blob[:content_type] || att[:mime])
          added += 1
        rescue Jira::Error
          skipped << att[:filename]
        end
      end
      [added, skipped]
    end
  end
end
