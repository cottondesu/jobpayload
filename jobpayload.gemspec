# frozen_string_literal: true

require_relative "lib/jobpayload/version"

Gem::Specification.new do |spec|
  spec.name = "jobpayload"
  spec.version = JobPayload::VERSION
  spec.authors = ["cottondesu"]
  spec.summary = "Checks that previously serialized Active Job payloads still deserialize on new code."
  spec.description = <<~DESC
    jobpayload snapshots Active Job serialized job data (ActiveJob::Base#serialize) into
    deterministic JSON fixtures and checks that the current application can still
    deserialize them (ActiveJob::Base.deserialize and ActiveJob::Arguments.deserialize)
    without ever performing the job.
  DESC
  spec.homepage = "https://github.com/cottondesu/jobpayload"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata = {
    "homepage_uri" => "https://github.com/cottondesu/jobpayload",
    "source_code_uri" => "https://github.com/cottondesu/jobpayload",
    "changelog_uri" => "https://github.com/cottondesu/jobpayload/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir[
    "lib/**/*.rb",
    "exe/*",
    "README.md",
    "CHANGELOG.md",
    "LICENSE",
    base: __dir__
  ].sort
  spec.bindir = "exe"
  spec.executables = ["jobpayload"]
  spec.require_paths = ["lib"]

  spec.add_dependency "activejob", ">= 7.2", "< 9"
end
