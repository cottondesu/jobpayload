# frozen_string_literal: true

require "fileutils"

module JobPayload
  # Turns snapshot cases into fixture files.
  #
  # The source of truth is ActiveJob::Base#serialize. Volatile Active Job
  # metadata is replaced with fixed values so repeated snapshots are
  # byte-for-byte identical; every other key (including keys added by a job's
  # own #serialize override) is kept as-is.
  class Snapshotter
    CANONICAL_JOB_ID = "00000000-0000-0000-0000-000000000000"
    CANONICAL_TIME = "2000-01-01T00:00:00.000000000Z"

    # Volatile keys and the stable values they are replaced with. Keys are only
    # replaced when present, so the shape of #serialize is never changed.
    NORMALIZED = {
      "job_id" => CANONICAL_JOB_ID,
      "provider_job_id" => nil,
      "enqueued_at" => CANONICAL_TIME,
      "executions" => 0,
      "exception_executions" => {}
    }.freeze

    Entry = Struct.new(:name, :path, :status) # status: :created, :identical, :updated, :skipped

    def initialize(registry:, output_dir:, update: false)
      @registry = registry
      @output_dir = output_dir
      @update = update
    end

    # Generates every fixture in memory first, so a failing case leaves the
    # fixture directory untouched, then writes them in name order.
    def call
      documents = @registry.cases.map { |kase| [kase.name, Canonical.generate(build_document(kase))] }
      begin
        FileUtils.mkdir_p(@output_dir)
      rescue SystemCallError => e
        raise ConfigurationError, "cannot create output directory #{@output_dir}: #{e.message}"
      end
      documents.map { |name, content| write(name, content) }
    end

    def build_document(kase)
      {
        "jobpayload_schema" => FIXTURE_SCHEMA,
        "name" => kase.name,
        "source" => self.class.source_versions,
        "job" => serialize_case(kase)
      }
    end

    def self.normalize(job_data)
      data = job_data.to_h { |key, value| [key.to_s, value] }
      NORMALIZED.each { |key, value| data[key] = Canonical.deep_copy(value) if data.key?(key) }
      data["scheduled_at"] = CANONICAL_TIME if data.key?("scheduled_at") && !data["scheduled_at"].nil?
      # Round-trip through JSON so the fixture holds exactly what a queue would store.
      JSON.parse(JSON.generate(data))
    end

    def self.source_versions
      {
        "ruby_version" => RUBY_VERSION,
        "active_job_version" => active_job_version,
        "rails_version" => rails_version,
        "jobpayload_version" => VERSION
      }
    end

    def self.active_job_version
      spec = Gem.loaded_specs["activejob"]
      return spec.version.to_s if spec
      return ::ActiveJob.version.to_s if defined?(::ActiveJob) && ::ActiveJob.respond_to?(:version)

      nil
    end

    def self.rails_version
      return nil unless defined?(::Rails) && ::Rails.respond_to?(:version)

      ::Rails.version.to_s
    end

    private

    # Runs the case block and serializes the job it returns. Any error is
    # reported against the case, never as an internal error.
    def serialize_case(kase)
      job = kase.block.call
      unless job.is_a?(::ActiveJob::Base)
        raise ConfigurationError,
          "fixture #{kase.name.inspect} (#{kase.location}) must return an ActiveJob::Base instance, got #{job.class}"
      end

      self.class.normalize(job.serialize)
    rescue ConfigurationError
      raise
    rescue StandardError, ScriptError => e
      raise ConfigurationError, "fixture #{kase.name.inspect} (#{kase.location}) raised #{e.class}: #{e.message}"
    end

    def write(name, content)
      path = File.join(@output_dir, "#{name}.json")
      status =
        if !File.exist?(path)
          :created
        elsif File.binread(path) == content.b
          :identical
        elsif @update
          :updated
        else
          :skipped
        end
      Canonical.atomic_write(path, content) if %i[created updated].include?(status)
      Entry.new(name, path, status)
    rescue SystemCallError => e
      raise ConfigurationError, "cannot write fixture #{path}: #{e.message}"
    end
  end
end
