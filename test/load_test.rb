# frozen_string_literal: true

require_relative "test_helper"

class LoadTest < Minitest::Test
  # `require "jobpayload"` must not load Active Job before the host app boots.
  def test_requiring_the_gem_does_not_load_active_job
    script = <<~RUBY
      require "jobpayload"
      JobPayload::CLI
      JobPayload::Checker
      JobPayload::Snapshotter
      JobPayload::Formatter::Text
      JobPayload::Formatter::JSON
      loaded = $LOADED_FEATURES.grep(%r{/(active_job|active_support|active_record|global_id)[/.]})
      puts(defined?(::ActiveJob) ? "ActiveJob defined" : "ActiveJob not defined")
      puts(defined?(::ActiveSupport) ? "ActiveSupport defined" : "ActiveSupport not defined")
      puts "features=\#{loaded.size}"
    RUBY
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", File.join(JobPayloadTest::ROOT, "lib"), "-e", script)
    assert status.success?, err
    assert_equal "ActiveJob not defined\nActiveSupport not defined\nfeatures=0\n", out
  end

  # Everything the CLI does before booting the application (option parsing,
  # finding fixture files) must not load the json library either: without
  # Bundler, that would activate the newest installed json gem and make the
  # application's own `require "bundler/setup"` fail on a version conflict.
  def test_work_before_boot_does_not_load_json
    script = <<~RUBY
      require "jobpayload"
      JobPayload::CLI
      JobPayload::FixtureLoader.files(ARGV.fetch(0))
      JobPayload::Boot
      JobPayload::ExceptionClassifier
      puts(defined?(::JSON) ? "JSON defined" : "JSON not defined")
    RUBY
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a-v1.json"), "{}")
      out, err, status = Open3.capture3(RbConfig.ruby, "-I", File.join(JobPayloadTest::ROOT, "lib"), "-e", script, dir)
      assert status.success?, err
      assert_equal "JSON not defined\n", out
    end
  end
end
