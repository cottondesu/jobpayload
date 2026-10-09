# frozen_string_literal: true

require "json"

module JobPayload
  # A parsed fixture file (schema v1).
  #
  # Fixture.parse never raises for bad content: it returns an Invalid value
  # carrying the reason, which the checker reports as AJP001.
  class Fixture
    Invalid = Struct.new(:name, :path, :reason)

    attr_reader :name, :path, :job, :source

    def initialize(name:, path:, job:, source:)
      @name = name
      @path = path
      @job = job
      @source = source
    end

    def job_class
      job["job_class"]
    end

    def self.parse(path)
      build(path) { File.binread(path) }
    end

    # Like parse, for bytes the caller has already read from +path+ (for
    # example through SecureFixtureReader); +path+ only names the fixture.
    def self.parse_content(path, content)
      build(path) { content }
    end

    def self.build(path)
      basename = File.basename(path, ".json")
      reason = catch(:invalid) do
        content = begin
          yield
        rescue SystemCallError => e
          invalid!("cannot read file: #{e.message}")
        end
        data = parse_json(content)
        validate!(data, basename)
        return new(name: data["name"], path: path, job: data["job"], source: data["source"])
      end
      # The file name and OS error messages may carry bytes that are not
      # UTF-8; Invalid values end up in JSON output.
      Invalid.new(JobPayload.scrub_utf8(basename), path, JobPayload.scrub_utf8(reason))
    end

    def self.parse_json(content)
      content = content.dup.force_encoding(Encoding::UTF_8)
      invalid!("file is not valid UTF-8") unless content.valid_encoding?
      data = JSON.parse(content, max_nesting: false)
      # Some json versions decode a lone surrogate escape ("\udc80") into
      # bytes that are not valid UTF-8.
      invalid!("file contains a string escape that is not valid UTF-8") unless valid_strings?(data)
      data
    rescue JSON::ParserError => e
      invalid!("invalid JSON: #{e.message.lines.first.to_s.strip}")
    end

    # Iterative, so that deeply nested fixtures cannot exhaust the stack here.
    def self.valid_strings?(data)
      pending = [data]
      until pending.empty?
        value = pending.pop
        case value
        when String then return false unless value.valid_encoding?
        when Array then pending.concat(value)
        when Hash
          pending.concat(value.keys)
          pending.concat(value.values)
        end
      end
      true
    end

    def self.validate!(data, basename)
      invalid!("top-level JSON value must be an object") unless data.is_a?(Hash)
      invalid!("missing jobpayload_schema") unless data.key?("jobpayload_schema")
      schema = data["jobpayload_schema"]
      unless schema == FIXTURE_SCHEMA && schema.is_a?(Integer)
        invalid!("unsupported jobpayload_schema #{schema.inspect} (expected #{FIXTURE_SCHEMA})")
      end
      invalid!("invalid file name #{basename.inspect}.json") unless JobPayload.valid_name?(basename)

      name = data["name"]
      invalid!("name must be a string") unless name.is_a?(String)
      invalid!("invalid name #{name.inspect}") unless JobPayload.valid_name?(name)
      invalid!("name #{name.inspect} does not match file name #{basename}.json") unless name == basename
      invalid!("source must be an object") if data.key?("source") && !data["source"].is_a?(Hash)

      job = data["job"]
      invalid!("job must be an object") unless job.is_a?(Hash)
      invalid!("job.job_class must be a non-empty string") unless job["job_class"].is_a?(String) && !job["job_class"].empty?
      invalid!("job.arguments must be an array") unless job["arguments"].is_a?(Array)
    end

    def self.invalid!(reason)
      throw :invalid, reason
    end
    private_class_method :build, :parse_json, :valid_strings?, :validate!, :invalid!
  end
end
