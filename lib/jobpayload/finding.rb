# frozen_string_literal: true

module JobPayload
  # One problem found while checking a fixture.
  #
  # Finding codes are a stable API: 0.2.0 keeps every 0.1.0 code and meaning.
  Finding = Struct.new(
    :code,
    :fixture,
    :job_class,
    :argument_path,
    :message,
    :exception_class,
    :exception_message,
    :cause_chain, # Array of {"class" => String, "message" => String}, outermost first
    :backtraces,  # Array of Array<String>, parallel to cause_chain; never serialized to JSON
    keyword_init: true
  )

  class Finding
    # code => [name, kind]. kind is :breaking, :inconclusive or :fatal.
    CODES = {
      "AJP001" => ["fixture_invalid", :fatal],
      "AJP101" => ["unknown_job_class", :breaking],
      "AJP102" => ["job_deserialize_failed", :breaking],
      "AJP201" => ["argument_deserialize_failed", :breaking],
      "AJP202" => ["globalid_record_missing", :inconclusive],
      "AJP900" => ["environment_error", :fatal]
    }.freeze

    # Severity strings used in JSON output.
    SEVERITIES = { breaking: "error", inconclusive: "warning", fatal: "fatal" }.freeze

    def self.build(code:, fixture:, message:, job_class: nil, argument_path: nil, exception: nil)
      raise ArgumentError, "unknown finding code #{code}" unless CODES.key?(code)

      chain = exception ? ExceptionClassifier.cause_chain(exception) : []
      new(
        code: code,
        fixture: fixture,
        job_class: job_class,
        argument_path: argument_path,
        message: message,
        exception_class: exception && ExceptionClassifier.class_name(exception),
        exception_message: exception && ExceptionClassifier.safe_message(exception),
        cause_chain: chain.map { |e| { "class" => ExceptionClassifier.class_name(e), "message" => ExceptionClassifier.safe_message(e) } },
        backtraces: chain.map { |e| Array(e.backtrace) }
      )
    end

    def name
      CODES.fetch(code).first
    end

    def kind
      CODES.fetch(code).last
    end

    def severity
      SEVERITIES.fetch(kind)
    end

    def sort_key
      [fixture.to_s, code, argument_path.to_s, message.to_s]
    end

    def to_json_hash
      {
        "code" => code,
        "name" => name,
        "severity" => severity,
        "fixture" => fixture,
        "job_class" => job_class,
        "argument_path" => argument_path,
        "message" => message,
        "exception_class" => exception_class,
        "exception_message" => exception_message,
        "cause_chain" => cause_chain
      }
    end
  end
end
