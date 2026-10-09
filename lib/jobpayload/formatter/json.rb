# frozen_string_literal: true

require "json"

module JobPayload
  module Formatter
    # Machine-readable output, schema v1. Field names and meanings are stable
    # within schema_version 1; see README "JSON output".
    module JSON
      SCHEMA_VERSION = 1

      module_function

      def call(result, fail_on_inconclusive: false, debug: false) # rubocop:disable Lint/UnusedMethodArgument
        document = {
          "schema_version" => SCHEMA_VERSION,
          "tool_version" => VERSION,
          "status" => result.status(fail_on_inconclusive: fail_on_inconclusive),
          "summary" => result.summary,
          "fixtures" => result.fixture_results.map { |r| { "name" => r.name, "status" => r.status.to_s } },
          "findings" => result.findings.map(&:to_json_hash)
        }
        Canonical.pretty(document)
      end
    end
  end
end
