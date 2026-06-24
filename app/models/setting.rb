# Tiny durable key/value store for singleton app-level flags. Today it backs the
# global autopilot stop-all kill switch (persisted so it survives restarts and is
# auditable). Values are stored as strings; flag helpers coerce to/from booleans.
class Setting < ApplicationRecord
  AUTOPILOT_STOP = "autopilot_stopped".freeze

  validates :key, presence: true, uniqueness: true

  def self.get(key, default = nil)
    find_by(key: key)&.value || default
  end

  def self.set(key, value)
    rec = find_or_initialize_by(key: key)
    rec.update!(value: value.to_s)
    value
  end

  def self.flag?(key)
    get(key) == "true"
  end

  def self.set_flag(key, on)
    set(key, on ? "true" : "false")
  end

  # Global autopilot kill switch. When on, the orchestrator launches nothing new
  # across every project (in-flight sessions are left to finish).
  def self.autopilot_stopped?
    flag?(AUTOPILOT_STOP)
  end

  def self.autopilot_stopped=(value)
    set_flag(AUTOPILOT_STOP, value)
  end
end
