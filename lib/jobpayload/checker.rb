# frozen_string_literal: true

require "json"

module JobPayload
  # Checks that previously serialized job payloads can be deserialized by the
  # currently loaded application.
  #
  # For each fixture, in order:
  #   A. the fixture wrapper must be valid (done by Fixture.parse)
  #   B. ActiveJob::Base.deserialize(job_data) must succeed
  #   C. ActiveJob::Arguments.deserialize(job_data["arguments"]) must succeed
  #
  # Each phase receives its own deep copy of the payload. The job is never
  # performed, enqueued or retried.
  class Checker
    MESSAGES = {
      "AJP101" => "Job class cannot be resolved by the current application.",
      "AJP102" => "Job class exists but its deserialize(job_data) cannot restore the old payload.",
      "AJP201" => "Old payload cannot be deserialized by the current application.",
      "AJP202" => "GlobalID target record was not found in the current test environment.",
      "AJP900" => "The check environment failed before compatibility could be determined."
    }.freeze

    RESCUED = [StandardError, ScriptError, SystemStackError].freeze

    # Phase C codes from least to most severe.
    ARGUMENT_CODE_RANK = { "AJP202" => 0, "AJP201" => 1, "AJP900" => 2 }.freeze

    def call(fixtures)
      fixture_results = fixtures.map { |fixture| check(fixture) }
      fixture_results.sort_by! { |result| [result.name, result.path.to_s] }
      Result.new(fixture_results)
    end

    def check(fixture)
      if fixture.is_a?(Fixture::Invalid)
        finding = Finding.build(code: "AJP001", fixture: fixture.name,
          message: "Fixture is invalid: #{fixture.reason}.")
        return Result::FixtureResult.new(fixture.name, fixture.path, [finding])
      end

      findings = []
      findings.concat(check_job(fixture))
      findings.concat(check_arguments(fixture))
      Result::FixtureResult.new(fixture.name, fixture.path, findings)
    end

    private

    # Phase B.
    def check_job(fixture)
      class_name = fixture.job_class
      begin
        klass = ::ActiveSupport::Inflector.safe_constantize(class_name)
      rescue *RESCUED => e
        return [finding("AJP101", fixture, exception: e)] unless environment?(e)

        return [finding("AJP900", fixture, exception: e)]
      end
      unless klass.is_a?(Class) && klass <= ::ActiveJob::Base
        detail = klass ? "#{class_name} is not an ActiveJob::Base subclass" : "uninitialized constant #{class_name}"
        return [finding("AJP101", fixture, message: "#{MESSAGES.fetch('AJP101')} (#{detail})")]
      end

      ::ActiveJob::Base.deserialize(Canonical.deep_copy(fixture.job))
      []
    rescue *RESCUED => e
      [finding(environment?(e) ? "AJP900" : "AJP102", fixture, exception: e)]
    end

    # Phase C. The full deserialize call is the source of truth for whether
    # the arguments are readable. When it fails, each argument is retried on
    # its own to point at every failing argument: Active Job stops at the first
    # error, so a missing GlobalID record (inconclusive) in arguments[0] must
    # not hide a broken serializer in arguments[1].
    def check_arguments(fixture)
      # Kept out of a rescue clause on purpose: exceptions raised while `$!` is
      # set get it as their cause, which would leak the first failure into the
      # cause chain (and classification) of every per-argument retry.
      e = ArgumentLocator.deserialize_error(fixture.job["arguments"], wrap: false)
      return [] unless e

      findings = ArgumentLocator.call(fixture.job["arguments"]).map do |path, error, leaf|
        finding(argument_code(error, leaf), fixture, exception: error, argument_path: path)
      end
      # Never report less than the full call did (for example when no single
      # argument fails on its own). The full call has no single failing leaf:
      # a record-missing error there is already explained by any per-argument
      # finding, and is reported as breaking when there is none.
      overall = argument_code(e, nil)
      floor = ExceptionClassifier.call(e) == :record_missing ? 0 : ARGUMENT_CODE_RANK.fetch(overall)
      unless findings.any? { |f| ARGUMENT_CODE_RANK.fetch(f.code) >= floor }
        findings << finding(overall, fixture, exception: e, argument_path: "arguments")
      end
      findings
    end

    # AJP202 (inconclusive) only when the failing serialized leaf is an Active
    # Job GlobalID reference and a record-missing error is in the cause chain.
    # A custom serializer that raises RecordNotFound (for example a lookup by a
    # renamed key) is a broken payload: AJP201.
    def argument_code(exception, leaf)
      case ExceptionClassifier.call(exception)
      when :environment then "AJP900"
      when :record_missing then ArgumentLocator.global_id?(leaf) ? "AJP202" : "AJP201"
      else "AJP201"
      end
    end

    def environment?(exception)
      ExceptionClassifier.call(exception) == :environment
    end

    def finding(code, fixture, exception: nil, argument_path: nil, message: MESSAGES.fetch(code))
      Finding.build(code: code, fixture: fixture.name, job_class: fixture.job_class,
        argument_path: argument_path, message: message, exception: exception)
    end

    # Finds every failing argument. Inside plain arrays and hashes it descends
    # to the nested values that fail on their own. Returns
    # [[path, exception, failing_value]].
    module ArgumentLocator
      # Keys Active Job adds to a serialized plain hash. Any other key,
      # including user keys such as "_aj_custom", holds a serialized value.
      HASH_METADATA_KEYS = %w[_aj_symbol_keys _aj_ruby2_keywords _aj_hash_with_indifferent_access].freeze

      module_function

      def call(arguments)
        arguments.each_with_index.flat_map { |argument, index| failures(argument, "arguments[#{index}]") }
      end

      def failures(value, path)
        error = deserialize_error(value)
        return [] unless error

        failing = []
        nested = children(value, path).flat_map do |child, child_path, key|
          child_failures = failures(child, child_path)
          failing << key unless child_failures.empty?
          child_failures
        end
        return [[path, error, value]] if nested.empty?

        # The container can also be broken on its own (for example malformed
        # "_aj_" metadata). Retry it with the failing children blanked out so
        # that a missing GlobalID inside cannot hide that.
        own_error = deserialize_error(without(value, failing))
        own_error ? nested << [path, own_error, value] : nested
      end

      def without(value, keys)
        copy = Canonical.deep_copy(value)
        keys.each { |key| copy[key] = nil }
        copy
      end

      # Same test Active Job uses for a serialized GlobalID: a one-key hash.
      def global_id?(value)
        value.is_a?(Hash) && value.size == 1 && value["_aj_globalid"].is_a?(String)
      end

      def children(value, path)
        case value
        when Array
          value.each_with_index.map { |child, index| [child, "#{path}[#{index}]", index] }
        when Hash
          return [] if value.key?("_aj_serialized") || value.key?("_aj_globalid")

          value.reject { |key, _| HASH_METADATA_KEYS.include?(key) }.map { |key, child| [child, "#{path}[#{JSON.generate(key)}]", key] }
        else
          []
        end
      end

      # Deserializes +value+ as a single argument (or, with wrap: false, as the
      # full argument list) and returns the exception raised, if any.
      def deserialize_error(value, wrap: true)
        ::ActiveJob::Arguments.deserialize(Canonical.deep_copy(wrap ? [value] : value))
        nil
      rescue *RESCUED => e
        e
      end
    end
  end
end
