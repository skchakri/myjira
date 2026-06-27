# Free-text `labels` (a Postgres `text[]`) shared by Task and FollowUpTask. Labels
# are a routing/triage primitive — `needs-human`, `agent-authored`, `flaky`, … —
# not cosmetic styling. They are settable from the web form (comma-separated via
# `labels_text`) or the API (array or comma string), normalized on save, and
# filterable on the board through the GIN-indexed `with_label` scope.
module Labelable
  extend ActiveSupport::Concern

  included do
    before_validation :normalize_labels

    # Containment filter — uses the GIN index on `labels`.
    scope :with_label, lambda { |name|
      n = name.to_s.strip.downcase
      next none if n.blank?

      where("#{table_name}.labels @> ARRAY[?]::text[]", n)
    }
  end

  class_methods do
    # Distinct labels across this relation, sorted — drives the board filter chips.
    # Call on a scoped relation (e.g. `project.tasks.all_labels`).
    def all_labels
      distinct_labels = connection.select_values(
        unscope(:order).select(Arel.sql("DISTINCT unnest(#{table_name}.labels)")).to_sql
      )
      distinct_labels.compact.sort
    end
  end

  # Accept a comma/space string as well as an array (defensive for API callers
  # passing `labels` as a plain string). Splitting here, before the Postgres
  # array type casts the value, keeps the string from being mangled.
  def labels=(value)
    super(value.is_a?(String) ? split_label_string(value) : value)
  end

  # Virtual accessor for the comma-separated form field.
  def labels_text
    Array(labels).join(", ")
  end

  def labels_text=(value)
    self.labels = split_label_string(value)
  end

  private

  # Strip, downcase, squish, drop blanks, dedupe — order preserved.
  def normalize_labels
    self.labels = Array(labels).filter_map do |tag|
      tag.to_s.strip.squish.downcase.presence
    end.uniq
  end

  def split_label_string(value)
    value.to_s.split(",")
  end
end
