module WorkQueue
  # Errands: queue items only the person can do ("kind": "yours"). This module holds the
  # pieces that are not a single item's state: when a snooze ends, and the "looks like an
  # errand" hint. Marking is always the person's click; nothing here converts an item.
  module Errands
    SNOOZES = [["1d", "1 day"], ["3d", "3 days"], ["monday", "Next Monday"]].freeze
    HINT_OFF = "errand_hint_off".freeze

    # Things an agent cannot do for the person, at the start of the title or of a clause
    # in it ("A thru Z: confirm with the practice …", "…, claim Healthgrades").
    VERBS = [
      "confirm (?:with|the|that) ", "ask (?:the|him|her|them) ", "call ", "collect ", "sign (?!in\\b|up\\b|out\\b|off\\b)",
      "pay ", "claim ", "buy ", "send .{1,60}? to ", "record a .{0,40}?video", "get .{1,60}? approved"
    ].freeze
    PATTERN = /(?:\A|[:;,.] +|\band +|\bthen +)(?:optional: *)?(?:#{VERBS.join('|')})/i

    module_function

    def looks_like?(title) = title.to_s.match?(PATTERN)

    # Worth asking "mark as mine?": person-only wording on an item that sits blocked or in
    # review with no PR, not already an errand, and not waved away before.
    def suggest?(item, run: nil)
      return false if item.yours? || item.pr.present? || %w[blocked review].exclude?(item.status)
      return false unless looks_like?(item.title)

      (run || RunState.get(item.key))[HINT_OFF] != "1"
    end

    def dismiss_hint(item) = RunState.set(item.key, HINT_OFF => "1")

    # When a snooze ends: "1d", "3d", "monday", or a date ("2026-11-30"). Always 08:00, so a
    # snoozed errand is back for the morning. nil when the value is not understood or is past.
    def snooze_until(value, now: Time.current)
      day = case value.to_s
      when "1d" then now.to_date + 1
      when "3d" then now.to_date + 3
      when "monday" then now.to_date.next_occurring(:monday)
      else Date.iso8601(value.to_s)
      end
      at = day.in_time_zone.change(hour: 8)
      at if at > now
    rescue ArgumentError
      nil
    end
  end
end
