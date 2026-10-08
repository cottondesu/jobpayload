# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/in_process_app"

class ExceptionClassifierTest < Minitest::Test
  Classifier = JobPayload::ExceptionClassifier

  # Raises +outer+ with +inner+ as its cause and returns the outer exception.
  def chained(inner, outer)
    begin
      begin
        raise inner
      rescue StandardError
        raise outer
      end
    rescue StandardError => e
      return e
    end
  end

  def test_plain_failure
    assert_equal :failure, Classifier.call(ArgumentError.new("Serializer MoneySerializer is not known"))
  end

  def test_record_not_found_in_cause_chain_is_record_missing
    error = chained(ActiveRecord::RecordNotFound.new("gone"), ActiveJob::DeserializationError)
    assert_equal :record_missing, Classifier.call(error)
  end

  def test_record_missing_detection_ignores_message_text
    assert_equal :failure, Classifier.call(StandardError.new("ActiveRecord::RecordNotFound Couldn't find User"))
  end

  def test_subclasses_are_matched_by_ancestor_name
    subclass = Class.new(ActiveRecord::RecordNotFound)
    assert_equal :record_missing, Classifier.call(subclass.new("x"))
  end

  def test_connection_errors_are_environment
    error = chained(ActiveRecord::ConnectionNotEstablished.new("no db"), ActiveJob::DeserializationError)
    assert_equal :environment, Classifier.call(error)
    assert_equal :environment, Classifier.call(ActiveRecord::NoDatabaseError.new("missing"))
    assert_equal :environment, Classifier.call(ActiveRecord::StatementInvalid.new("no such table: users"))
  end

  def test_missing_database_configuration_is_environment
    assert_equal :environment, Classifier.call(ActiveRecord::AdapterNotSpecified.new("database configuration does not specify adapter"))
  end

  def test_class_name_of_anonymous_exception_class_falls_back_to_named_ancestor
    anonymous = Class.new(KeyError)
    assert_equal "KeyError", Classifier.class_name(anonymous.new("x"))
    finding = JobPayload::Finding.build(code: "AJP201", fixture: "f", message: "m", exception: anonymous.new("x"))
    assert_equal "KeyError", finding.exception_class
    assert_equal [{ "class" => "KeyError", "message" => "x" }], finding.cause_chain
  end

  def test_environment_wins_over_record_missing
    error = chained(ActiveRecord::RecordNotFound.new("gone"), ActiveRecord::ConnectionNotEstablished.new("down"))
    assert_equal :environment, Classifier.call(error)
  end

  def test_name_error_for_missing_model_is_failure
    error = chained(NameError.new("uninitialized constant Account"), ActiveJob::DeserializationError)
    assert_equal :failure, Classifier.call(error)
  end

  def test_cause_chain_is_outermost_first
    inner = KeyError.new("key not found")
    error = chained(inner, ActiveJob::DeserializationError)
    assert_equal [ActiveJob::DeserializationError, KeyError], Classifier.cause_chain(error).map(&:class)
  end

  def test_cause_chain_survives_cycles
    cyclic = Class.new(StandardError) do
      attr_accessor :fake_cause

      def cause
        fake_cause
      end
    end
    a = cyclic.new("a")
    b = cyclic.new("b")
    a.fake_cause = b
    b.fake_cause = a

    assert_equal [a, b], Classifier.cause_chain(a)
    assert_equal :failure, Classifier.call(a)
  end

  def test_cause_chain_is_bounded
    deep = Class.new(StandardError) do
      def cause
        self.class.new("deeper")
      end
    end
    assert_equal Classifier::MAX_CHAIN_LENGTH, Classifier.cause_chain(deep.new("x")).size
  end

  def test_safe_message_handles_broken_message_methods
    broken = Class.new(StandardError) do
      def message
        raise "nope"
      end
    end
    assert_equal "(message unavailable: RuntimeError)", Classifier.safe_message(broken.new)
  end

  def test_safe_message_is_always_valid_utf8
    binary = Classifier.safe_message(RuntimeError.new("bad \xFF byte".b))
    assert_equal ["bad \uFFFD byte", Encoding::UTF_8], [binary, binary.encoding]

    sjis = Classifier.safe_message(RuntimeError.new("\u65E5\u672C".encode(Encoding::Shift_JIS)))
    assert_equal ["\u65E5\u672C", Encoding::UTF_8], [sjis, sjis.encoding]

    assert_equal "ok \u00E9", Classifier.safe_message(RuntimeError.new("ok \u00E9"))
  end

  def test_scrub_utf8_replaces_only_invalid_bytes_and_never_mutates_its_input
    valid = "out-\u00E9\u2713/a.json"
    assert_equal valid, JobPayload.scrub_utf8(valid)

    [
      "out\xFF/a.json".b,
      "out\xFF/a.json".dup.force_encoding(Encoding::UTF_8),
      "out\xFF/a.json".b.freeze
    ].each do |raw|
      before = [raw.b, raw.encoding]
      scrubbed = JobPayload.scrub_utf8(raw)
      assert_equal ["out\uFFFD/a.json", Encoding::UTF_8, true], [scrubbed, scrubbed.encoding, scrubbed.valid_encoding?]
      assert_equal before, [raw.b, raw.encoding], "the raw path bytes and encoding are not mutated"
    end
  end

  def test_scrub_never_raises_for_encodings_without_a_converter
    scrubbed = JobPayload.scrub_utf8("a+b".dup.force_encoding(Encoding::UTF_7))
    assert_equal ["a+b", Encoding::UTF_8], [scrubbed, scrubbed.encoding]
  end

  def test_stack_exhaustion_is_an_environment_problem
    error = begin
      begin
        raise SystemStackError, "stack level too deep"
      rescue SystemStackError
        raise ActiveJob::DeserializationError
      end
    rescue ActiveJob::DeserializationError => e
      e
    end
    assert_equal :environment, Classifier.call(error)
    assert_equal :environment, Classifier.call(SystemStackError.new("stack level too deep"))
  end

  def test_json_output_survives_non_utf8_exception_messages
    error = chained(RuntimeError.new("inner \xFE".b), ArgumentError.new("outer \xFF".b))
    finding = JobPayload::Finding.build(code: "AJP201", fixture: "bin-v1", job_class: "X", argument_path: "arguments[0]",
      message: "m", exception: error)
    json = JobPayload::Formatter::JSON.call(JobPayload::Result.new([JobPayload::Result::FixtureResult.new("bin-v1", "b", [finding])]))
    document = JSON.parse(json)

    assert json.valid_encoding?
    assert_equal ["outer \uFFFD", "inner \uFFFD"], document["findings"].first["cause_chain"].map { |c| c["message"] }
    assert_equal "outer \uFFFD", document["findings"].first["exception_message"]
  end
end
