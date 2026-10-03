# frozen_string_literal: true

require_relative "test_helper"

# Payloads written under an older (or the same) Active Job version must still
# deserialize under the Active Job version this suite is running with.
class CrossVersionTest < Minitest::Test
  include JobPayloadTest
  parallelize_me!

  FIXTURES = File.join(JobPayloadTest::ROOT, "test/fixtures")

  def self.current_active_job_version
    Gem::Version.new(Gem.loaded_specs.fetch("activejob").version.segments.first(2).join("."))
  end

  def self.fixture_sets
    Dir.children(FIXTURES).grep(/\Aactive_job_\d+\.\d+\z/).sort.map do |dir|
      [dir, Gem::Version.new(dir.delete_prefix("active_job_"))]
    end
  end

  def test_sets_cover_every_supported_minor_version
    assert_equal %w[active_job_7.2 active_job_8.0 active_job_8.1], self.class.fixture_sets.map(&:first)
  end

  fixture_sets.each do |dir, version|
    %w[v1 v2_compatible].each do |app|
      define_method("test_#{dir.tr('.', '_')}_payloads_on_#{app}") do
        skip "#{dir} is newer than activejob #{self.class.current_active_job_version}" if version > self.class.current_active_job_version

        out, err, code = run_cli("check", "--boot", app_boot(app), "--fixtures", File.join(FIXTURES, dir), "--format", "json")
        document = JSON.parse(out)

        assert_equal [0, ""], [code, err]
        assert_equal({ "fixtures" => 30, "compatible" => 28, "incompatible" => 0, "inconclusive" => 2, "tool_errors" => 0 },
          document["summary"])
        assert_equal version.to_s, JSON.parse(File.read(File.join(FIXTURES, dir, "tenant-v1.json")))
          .dig("source", "active_job_version").split(".").first(2).join(".")
      end
    end
  end
end
