# frozen_string_literal: true

module JobPayload
  # Collects the fixture definitions declared by a cases file.
  #
  # A registry is only "current" while CaseRegistry.load is evaluating a cases
  # file, so JobPayload.define never writes into process-wide state.
  class CaseRegistry
    Case = Struct.new(:name, :block, :location)

    # Thread-local key holding the registry being populated.
    CURRENT_KEY = :__jobpayload_case_registry

    def self.current
      Thread.current[CURRENT_KEY] or
        raise ConfigurationError, "JobPayload.define can only be called from a cases file loaded by `jobpayload snapshot`"
    end

    # Loads the cases file at +path+ and returns the populated registry.
    def self.load(path)
      raise ConfigurationError, "cases file not found: #{path}" unless File.file?(path)

      registry = new
      previous = Thread.current[CURRENT_KEY]
      Thread.current[CURRENT_KEY] = registry
      begin
        Kernel.load(File.expand_path(path))
      rescue ConfigurationError
        raise
      rescue StandardError, ScriptError => e
        raise ConfigurationError, "failed to load cases file #{path}: #{e.class}: #{e.message}"
      ensure
        Thread.current[CURRENT_KEY] = previous
      end
      raise ConfigurationError, "no fixtures defined in #{path}" if registry.cases.empty?

      registry
    end

    def initialize
      @cases = {}
    end

    # Fixtures sorted by name, independent of declaration order.
    def cases
      @cases.values.sort_by(&:name)
    end

    def define(&block)
      raise ConfigurationError, "JobPayload.define requires a block" unless block

      DSL.new(self).instance_eval(&block)
      self
    end

    def add(name, location, &block)
      unless JobPayload.valid_name?(name)
        raise ConfigurationError,
          "invalid fixture name #{name.inspect} (#{location}); names must match #{NAME_PATTERN.source}"
      end
      raise ConfigurationError, "fixture #{name.inspect} has no block (#{location})" unless block
      # Names differing only in case would map to the same file on
      # case-insensitive file systems (macOS, Windows), so they are duplicates too.
      if (existing = @cases.values.find { |kase| kase.name.casecmp?(name) })
        raise ConfigurationError,
          "duplicate fixture name #{name.inspect} (#{location}; #{existing.name.inspect} first defined at #{existing.location}; " \
          "names must be unique ignoring case)"
      end

      @cases[name] = Case.new(name, block, location)
    end

    # Evaluation context for JobPayload.define blocks.
    class DSL
      def initialize(registry)
        @registry = registry
      end

      def fixture(name, &block)
        caller_location = caller_locations(1, 1).first
        @registry.add(name, "#{caller_location.path}:#{caller_location.lineno}", &block)
        nil
      end
    end
  end
end
