# frozen_string_literal: true

module JobPayload
  # Classifies an exception raised while deserializing a payload by looking at
  # the classes in its cause chain (never primarily at message text).
  #
  # Classes are compared by name, including ancestors, so the classifier works
  # whether or not a given library (Active Record, a database driver, ...) is
  # loaded in the host application.
  module ExceptionClassifier
    # The referenced record does not exist. The payload may still be perfectly
    # readable by the new code, so the result is inconclusive.
    RECORD_MISSING = %w[
      ActiveRecord::RecordNotFound
      GlobalID::Locator::RecordNotFound
      Mongoid::Errors::DocumentNotFound
    ].freeze

    # The check environment itself is broken (no database, no connection,
    # schema not loaded...). ActiveRecord::StatementInvalid is included because
    # SQL errors while locating a record mean the test database does not match
    # the application, not that the payload is unreadable. SystemStackError is
    # included because exhausting the Ruby stack (pathologically deep payloads)
    # means jobpayload could not finish the check, not that the payload is
    # incompatible.
    ENVIRONMENT = %w[
      ActiveRecord::ConnectionNotEstablished
      ActiveRecord::NoDatabaseError
      ActiveRecord::StatementInvalid
      ActiveRecord::DatabaseConnectionError
      ActiveRecord::PendingMigrationError
      ActiveRecord::AdapterNotSpecified
      ActiveRecord::AdapterNotFound
      PG::ConnectionBad
      Mysql2::Error::ConnectionError
      Trilogy::ConnectionError
      SQLite3::CantOpenException
      Errno::ECONNREFUSED
      SystemStackError
    ].freeze

    MAX_CHAIN_LENGTH = 32

    module_function

    # Returns :environment, :record_missing or :failure.
    def call(exception)
      names = cause_chain(exception).flat_map { |e| ancestor_names(e) }
      return :environment if names.intersect?(ENVIRONMENT)
      return :record_missing if names.intersect?(RECORD_MISSING)

      :failure
    end

    # The exception followed by its causes, outermost first. Stops on cycles.
    def cause_chain(exception)
      chain = []
      seen = {}.compare_by_identity
      current = exception
      while current && !seen.key?(current) && chain.size < MAX_CHAIN_LENGTH
        seen[current] = true
        chain << current
        current = current.cause
      end
      chain
    end

    def ancestor_names(exception)
      exception.class.ancestors.filter_map { |mod| mod.is_a?(Class) ? mod.name : nil }
    end

    # Name of the exception's class; anonymous classes fall back to the
    # nearest named ancestor so reports never show an empty class.
    def class_name(exception)
      exception.class.ancestors.find { |mod| mod.is_a?(Class) && mod.name }&.name.to_s
    end

    # Exception#message can itself raise (or return non-strings) for badly
    # behaved exception classes; never let that crash the report.
    # Always valid UTF-8, so JSON output never fails on a message carrying
    # binary or otherwise invalid bytes (they become U+FFFD).
    def safe_message(exception)
      JobPayload.scrub_utf8(exception.message.to_s)
    rescue StandardError => e
      "(message unavailable: #{e.class})"
    end
  end
end
