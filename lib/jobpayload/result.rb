# frozen_string_literal: true

module JobPayload
  # Outcome of a `check` run.
  class Result
    # Per-fixture outcome. status is :pass, :fail, :inconclusive or
    # :tool_error (the worst finding wins).
    FixtureResult = Struct.new(:name, :path, :findings) do
      def status
        kinds = findings.map(&:kind)
        if kinds.include?(:fatal) then :tool_error
        elsif kinds.include?(:breaking) then :fail
        elsif kinds.include?(:inconclusive) then :inconclusive
        else :pass
        end
      end
    end

    EXIT_SUCCESS = 0
    EXIT_FAILURE = 1
    EXIT_ERROR = 2

    attr_reader :fixture_results

    def initialize(fixture_results)
      @fixture_results = fixture_results
    end

    # All findings, sorted by fixture, code, then argument path.
    def findings
      fixture_results.flat_map(&:findings).sort_by(&:sort_key)
    end

    def summary
      counts = fixture_results.map(&:status).tally
      {
        "fixtures" => fixture_results.size,
        "compatible" => counts.fetch(:pass, 0),
        "incompatible" => counts.fetch(:fail, 0),
        "inconclusive" => counts.fetch(:inconclusive, 0),
        "tool_errors" => counts.fetch(:tool_error, 0)
      }
    end

    # "pass", "fail" or "tool_error".
    def status(fail_on_inconclusive: false)
      statuses = fixture_results.map(&:status)
      if statuses.include?(:tool_error) then "tool_error"
      elsif statuses.include?(:fail) then "fail"
      elsif fail_on_inconclusive && statuses.include?(:inconclusive) then "fail"
      else "pass"
      end
    end

    def exit_code(fail_on_inconclusive: false)
      { "tool_error" => EXIT_ERROR, "fail" => EXIT_FAILURE, "pass" => EXIT_SUCCESS }
        .fetch(status(fail_on_inconclusive: fail_on_inconclusive))
    end
  end
end
