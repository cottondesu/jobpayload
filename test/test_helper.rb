# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "jobpayload"
require "minitest/autorun"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require_relative "support/filesystem_capability"

module JobPayloadTest
  ROOT = File.expand_path("..", __dir__)
  APPS = File.join(ROOT, "test/apps")
  EXE = File.join(ROOT, "exe/jobpayload")

  module_function

  def app_boot(name)
    File.join(APPS, name, "environment.rb")
  end

  def v1_cases
    File.join(APPS, "v1/jobpayload_cases.rb")
  end

  # Runs the real executable in a fresh Ruby process, so each run boots its
  # own dummy application exactly like `bundle exec jobpayload` would.
  def run_cli(*args, env: {}, chdir: ROOT)
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "-I", File.join(ROOT, "lib"), EXE, *args, chdir: chdir)
    [stdout, stderr, status.exitstatus]
  end

  # Baseline fixtures written once by the v1 dummy app and shared (read-only)
  # by every test that needs them.
  V1_FIXTURES = { mutex: Mutex.new, dir: nil }

  def v1_fixtures
    V1_FIXTURES[:mutex].synchronize do
      V1_FIXTURES[:dir] ||= begin
        dir = Dir.mktmpdir("jobpayload-v1-fixtures")
        Minitest.after_run { FileUtils.remove_entry(dir) }
        _out, err, code = run_cli("snapshot", "--boot", app_boot("v1"), "--cases", v1_cases, "--output", dir)
        raise "v1 snapshot failed (exit #{code}):\n#{err}" unless code.zero?

        dir
      end
    end
  end

  def v1_fixture(name)
    File.join(v1_fixtures, "#{name}.json")
  end
end
