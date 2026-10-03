# frozen_string_literal: true

# Entry point for the jobpayload gem.
#
# This file is intentionally lightweight: requiring it must not load Active Job
# (or any other part of the host application's framework). Active Job APIs are
# referenced lazily, only after the host application has been booted, so that
# custom serializer registration and initializer order are left untouched.
require_relative "jobpayload/version"
require_relative "jobpayload/errors"
require_relative "jobpayload/case_registry"

module JobPayload
  autoload :CLI, "jobpayload/cli"
  autoload :Boot, "jobpayload/boot"
  autoload :Canonical, "jobpayload/canonical"
  autoload :Snapshotter, "jobpayload/snapshotter"
  autoload :Fixture, "jobpayload/fixture"
  autoload :FixtureLoader, "jobpayload/fixture_loader"
  autoload :Checker, "jobpayload/checker"
  autoload :Result, "jobpayload/result"
  autoload :Finding, "jobpayload/finding"
  autoload :ExceptionClassifier, "jobpayload/exception_classifier"
  autoload :Formatter, "jobpayload/formatter"

  # Pattern every fixture name must match. Rejects path separators, leading
  # dots and anything else that could escape the fixture directory.
  NAME_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

  # Fixture wrapper schema version written by `snapshot` and read by `check`.
  FIXTURE_SCHEMA = 1

  # Defines snapshot cases. Called from the cases file (test/jobpayload_cases.rb
  # by default) while `jobpayload snapshot` is loading it.
  #
  #   JobPayload.define do
  #     fixture "billing-money-v1" do
  #       BillingJob.new(Money.new(1_250, "USD"))
  #     end
  #   end
  def self.define(&block)
    CaseRegistry.current.define(&block)
  end

  def self.valid_name?(name)
    name.is_a?(String) && NAME_PATTERN.match?(name) && !name.include?("..")
  end

  # Returns +string+ as valid UTF-8 (invalid bytes become U+FFFD), for text
  # from outside jobpayload (exception messages, file names, paths) that ends
  # up in JSON output.
  def self.scrub_utf8(string)
    if [Encoding::UTF_8, Encoding::BINARY, Encoding::US_ASCII].include?(string.encoding)
      string.dup.force_encoding(Encoding::UTF_8).scrub("\uFFFD")
    else
      string.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "\uFFFD")
    end
  rescue EncodingError # no converter (for example UTF-7): keep the bytes
    string.b.force_encoding(Encoding::UTF_8).scrub("\uFFFD")
  end
end
