# frozen_string_literal: true

module JobPayload
  # Output formatters for `check` results.
  module Formatter
    autoload :Text, "jobpayload/formatter/text"
    autoload :JSON, "jobpayload/formatter/json"

    FORMATS = %w[text json].freeze

    def self.for(name)
      case name
      when "text" then Text
      when "json" then JSON
      else raise UsageError, "unknown format #{name.inspect} (expected one of: #{FORMATS.join(', ')})"
      end
    end
  end
end
