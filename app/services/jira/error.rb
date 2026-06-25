module Jira
  # One error type carrying a kind symbol; controllers map kind → user message.
  # kinds: :not_configured, :bad_url, :unauthorized, :not_found, :request_error
  class Error < StandardError
    attr_reader :kind

    def initialize(message, kind: :request_error)
      super(message)
      @kind = kind
    end

    def user_message = message
  end
end
