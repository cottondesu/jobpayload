# frozen_string_literal: true

module JobPayload
  # Boots the host application exactly once, then makes sure Active Job is
  # available. Active Job is only required *after* the application's own boot
  # file has run, so the application controls load order.
  class Boot
    DEFAULT_PATH = "config/environment.rb"
    DEFAULT_ENVIRONMENT = "test"

    def self.call(path:, environment:)
      new(path: path, environment: environment).call
    end

    def initialize(path:, environment:)
      @path = File.expand_path(path)
      @environment = environment
    end

    def call
      raise BootError, "boot file not found: #{@path}" unless File.file?(@path)

      ENV["RAILS_ENV"] = @environment
      begin
        # require keeps a boot file from running twice; files without the .rb
        # extension cannot be required, so they are loaded instead.
        @path.end_with?(".rb") ? require(@path) : load(@path)
      rescue Exception => e # rubocop:disable Lint/RescueException
        raise if e.is_a?(SystemExit) || e.is_a?(SignalException) || e.is_a?(NoMemoryError)

        raise BootError, "failed to boot #{@path}: #{e.class}: #{e.message}"
      end
      load_active_job
    end

    private

    def load_active_job
      require "active_job" unless defined?(::ActiveJob::Base)
      # Touch the public APIs the checker relies on so missing pieces surface
      # as boot errors rather than as per-fixture failures.
      ::ActiveJob::Base
      ::ActiveJob::Arguments
      nil
    rescue StandardError, ScriptError => e
      raise BootError, "Active Job could not be loaded after booting #{@path}: #{e.class}: #{e.message}"
    end
  end
end
