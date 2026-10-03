# frozen_string_literal: true

module JobPayload
  # Base class for errors that abort a command with exit status 2
  # (usage, configuration, boot or tool errors).
  class Error < StandardError; end

  # Invalid command line usage.
  class UsageError < Error; end

  # Invalid or missing input (cases file, fixture directory, case definitions).
  class ConfigurationError < Error; end

  # The host application could not be booted.
  class BootError < Error; end
end
