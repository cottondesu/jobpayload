# frozen_string_literal: true

require_relative "test_helper"

# End-to-end tests of the executable. Every test runs `jobpayload` in a fresh
# Ruby process that boots a dummy application from test/apps.
class CLITest < Minitest::Test
  include JobPayloadTest
  parallelize_me!

  def v1_boot = app_boot("v1")

  def test_version
    out, err, code = run_cli("--version")
    assert_equal ["jobpayload v0.1.0\n", "", 0], [out, err, code]
  end

  def test_help_goes_to_stdout
    out, err, code = run_cli("--help")
    assert_equal 0, code
    assert_empty err
    assert_includes out, "Usage: jobpayload COMMAND [options]"

    out, _err, code = run_cli("check", "--help")
    assert_equal 0, code
    assert_includes out, "--fail-on-inconclusive"
  end

  def test_subcommand_version_and_abbreviations
    out, err, code = run_cli("check", "--version")
    assert_equal ["jobpayload v0.1.0\n", "", 0], [out, err, code]

    out, err, code = run_cli("check", "--fail", "--fixtures", "/nonexistent")
    assert_equal ["", 2], [out, code]
    assert_includes err, "invalid option: --fail"
  end

  def test_application_exit_during_boot_is_a_tool_error
    out, err, code = run_cli("check", "--boot", v1_boot, "--fixtures", v1_fixtures, env: { "JOBPAYLOAD_TEST_BOOT_EXIT" => "1" })
    assert_equal ["", 2], [out, code]
    assert_includes err, "the application exited with status 1"
  end

  def test_boot_file_without_rb_extension
    Dir.mktmpdir do |dir|
      boot = File.join(dir, "boot")
      File.write(boot, "require #{v1_boot.inspect}\n")
      _out, err, code = run_cli("check", "--boot", boot, "--fixtures", v1_fixture("billing-money-v1"))
      assert_equal 0, code, err
    end
  end

  def test_snapshot_output_must_be_a_directory
    Dir.mktmpdir do |dir|
      file = File.join(dir, "file")
      File.write(file, "")
      out, err, code = run_cli("snapshot", "--boot", v1_boot, "--cases", v1_cases, "--output", file)
      assert_equal ["", 2], [out, code]
      assert_includes err, "output path is not a directory"
    end
  end

  def test_no_command
    out, err, code = run_cli
    assert_equal ["", 2], [out, code]
    assert_includes err, "jobpayload: no command given"
  end

  def test_unknown_command
    out, err, code = run_cli("deploy")
    assert_equal ["", 2], [out, code]
    assert_includes err, 'jobpayload: unknown command "deploy"'
  end

  def test_unknown_option_and_bad_format
    out, err, code = run_cli("check", "--nope")
    assert_equal ["", 2], [out, code]
    assert_includes err, "invalid option: --nope"

    out, err, code = run_cli("check", "--format", "xml")
    assert_equal ["", 2], [out, code]
    assert_includes err, "invalid argument: --format xml"

    _out, err, code = run_cli("check", "extra")
    assert_equal 2, code
    assert_includes err, 'unexpected argument "extra"'
  end

  def test_missing_boot_file
    out, err, code = run_cli("check", "--boot", "/nonexistent/config/environment.rb", "--fixtures", v1_fixtures)
    assert_equal ["", 2], [out, code]
    assert_includes err, "jobpayload: error: AJP900 environment_error: boot file not found: /nonexistent/config/environment.rb"
  end

  def test_default_boot_file_is_config_environment_rb
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(v1_fixtures, File.join(dir, "fixtures"))
      out, err, code = run_cli("check", "--fixtures", "fixtures", chdir: dir)
      assert_equal ["", 2], [out, code]
      assert_includes err, "boot file not found: #{File.realpath(dir)}/config/environment.rb"
    end
  end

  def test_boot_failure_is_a_tool_error
    out, err, code = run_cli("check", "--boot", v1_boot, "--fixtures", v1_fixtures, "--format", "json",
      env: { "JOBPAYLOAD_TEST_BOOT_FAIL" => "1" })
    assert_equal ["", 2], [out, code]
    assert_includes err, "AJP900 environment_error: failed to boot"
    assert_includes err, "RuntimeError: simulated boot failure"
  end

  def test_missing_case_file
    Dir.mktmpdir do |dir|
      out, err, code = run_cli("snapshot", "--boot", v1_boot, "--cases", File.join(dir, "missing.rb"), "--output", dir)
      assert_equal ["", 2], [out, code]
      assert_includes err, "cases file not found"
    end
  end

  def test_missing_fixture_directory
    out, err, code = run_cli("check", "--boot", v1_boot, "--fixtures", "/nonexistent/fixtures")
    assert_equal ["", 2], [out, code]
    assert_includes err, "fixture path not found: /nonexistent/fixtures"
  end

  def test_snapshot_and_update
    Dir.mktmpdir do |dir|
      out, err, code = run_cli("snapshot", "--boot", v1_boot, "--cases", v1_cases, "--output", dir)
      assert_equal 0, code, err
      assert_includes out, "created   billing-money-v1  #{dir}/billing-money-v1.json"
      assert_match(/^30 fixtures: 30 created, 0 updated, 0 identical, 0 skipped$/, out)

      path = File.join(dir, "billing-money-v1.json")
      original = File.binread(path)
      File.binwrite(path, original.sub('"amount": 1250', '"amount": 1'))
      edited = File.binread(path)

      out, err, code = run_cli("snapshot", "--boot", v1_boot, "--cases", v1_cases, "--output", dir)
      assert_equal 0, code, err
      assert_includes out, "skipped   billing-money-v1  #{path}  (exists and differs; pass --update to replace)"
      assert_match(/^30 fixtures: 0 created, 0 updated, 29 identical, 1 skipped$/, out)
      assert_equal edited, File.binread(path), "snapshot without --update must not overwrite"

      out, err, code = run_cli("snapshot", "--boot", v1_boot, "--cases", v1_cases, "--output", dir, "--update",
        "--format", "json")
      assert_equal 0, code, err
      document = JSON.parse(out)
      assert_equal({ "created" => 0, "updated" => 1, "identical" => 29, "skipped" => 0 }, document["summary"])
      assert_equal original, File.binread(path)
    end
  end

  def test_snapshot_bytes_are_deterministic_across_processes
    Dir.mktmpdir do |dir|
      _out, err, code = run_cli("snapshot", "--boot", v1_boot, "--cases", v1_cases, "--output", dir)
      assert_equal 0, code, err
      files = Dir.children(dir).sort
      assert_equal Dir.children(v1_fixtures).sort, files
      files.each do |file|
        assert_equal File.binread(File.join(v1_fixtures, file)), File.binread(File.join(dir, file)), file
      end
    end
  end

  # Under a UTF-8 locale (as on CI) ARGV strings are tagged UTF-8, so a path
  # with non-UTF-8 bytes is an invalid string; under the C locale it is not.
  # Both must work: the file system gets the exact bytes, and only output is
  # scrubbed to valid UTF-8.
  # These tests need a file system that stores such names (macOS APFS
  # rejects them); they are skipped only when a probe of their own temporary
  # directory shows it cannot.
  NON_UTF8_LOCALES = [{ "LANG" => "C.UTF-8", "LC_ALL" => "C.UTF-8" }, { "LANG" => "C", "LC_ALL" => "C" }].freeze

  def test_snapshot_json_with_an_output_path_that_is_not_utf8
    NON_UTF8_LOCALES.each do |locale|
      Dir.mktmpdir do |dir|
        FilesystemCapability.skip_unless_non_utf8_names(self, :directory, dir)
        output = File.join(dir, "out\xFF".b)
        out, err, code = run_cli("snapshot", "--boot", v1_boot, "--cases", v1_cases, "--output", output, "--format", "json",
          env: locale)
        assert_equal 0, code, "#{locale}: #{err}"
        assert_equal ["out\xFF".b], Dir.children(dir).map(&:b), "the directory name keeps its original bytes"
        assert_equal 30, Dir.children(output).size
        paths = JSON.parse(out.force_encoding(Encoding::UTF_8))["fixtures"].map { |f| f["path"] }
        assert_equal 30, paths.size
        assert(paths.all? { |path| path.include?("out\uFFFD/") }, locale.inspect)
      end
    end
  end

  def test_text_output_and_check_with_a_fixture_path_that_is_not_utf8
    NON_UTF8_LOCALES.each do |locale|
      Dir.mktmpdir do |dir|
        FilesystemCapability.skip_unless_non_utf8_names(self, :directory, dir)
        output = File.join(dir, "out\xFF".b)
        out, err, code = run_cli("snapshot", "--boot", v1_boot, "--cases", v1_cases, "--output", output, env: locale)
        assert_equal 0, code, "#{locale}: #{err}"
        out.force_encoding(Encoding::UTF_8)
        assert out.valid_encoding?, locale.inspect
        assert_includes out, "out\uFFFD/billing-money-v1.json"

        out, err, code = run_cli("check", "--boot", v1_boot, "--fixtures", output, "--format", "json", env: locale)
        assert_equal 0, code, "#{locale}: #{err}"
        assert_equal 30, JSON.parse(out.force_encoding(Encoding::UTF_8))["summary"]["fixtures"]
      end
    end
  end

  # A valid UTF-8, non-ASCII path works on every file system.
  def test_snapshot_and_check_with_a_utf8_path
    Dir.mktmpdir do |dir|
      name = "\u51FA\u529B-\u2713"
      output = File.join(dir, name)
      out, err, code = run_cli("snapshot", "--boot", v1_boot, "--cases", v1_cases, "--output", output, "--format", "json")
      assert_equal 0, code, err
      assert_equal [name.b], Dir.children(dir).map(&:b)
      paths = JSON.parse(out.force_encoding(Encoding::UTF_8))["fixtures"].map { |f| f["path"] }
      assert_equal 30, paths.size
      assert(paths.all? { |path| path.include?("#{name}/") })

      out, err, code = run_cli("check", "--boot", v1_boot, "--fixtures", output)
      assert_equal 0, code, err
      assert_includes out.force_encoding(Encoding::UTF_8), "30 fixtures"
    end
  end

  # A writable copy of the shared v1 baseline.
  def copy_of_v1_fixtures(dir)
    copy = File.join(dir, "fixtures")
    FileUtils.cp_r(v1_fixtures, copy)
    copy
  end

  def snapshot_check(fixtures, *extra, env: {})
    run_cli("snapshot", "--check", "--boot", v1_boot, "--cases", v1_cases, "--output", fixtures, *extra, env: env)
  end

  def file_states(dir)
    Dir.children(dir).sort.to_h { |name| [name, [File.binread(File.join(dir, name)), File.mtime(File.join(dir, name))]] }
  end

  def test_snapshot_check_on_an_unchanged_baseline
    Dir.mktmpdir do |dir|
      fixtures = copy_of_v1_fixtures(dir)
      before = file_states(fixtures)

      out, err, code = snapshot_check(fixtures)
      assert_equal [0, ""], [code, err]
      assert_includes out, "identical billing-money-v1  #{fixtures}/billing-money-v1.json"
      assert_match(/\n\n30 fixtures: 30 identical, 0 different, 0 missing, 0 invalid\n\z/, out)

      out, err, code = snapshot_check(fixtures, "--format", "json")
      assert_equal [0, ""], [code, err]
      document = JSON.parse(out)
      assert_equal [1, "check", "pass"], document.values_at("schema_version", "mode", "status")
      assert_equal({ "fixtures" => 30, "identical" => 30, "different" => 0, "missing" => 0, "invalid" => 0 }, document["summary"])
      assert_equal({ "name" => "account-sync-v1", "path" => "#{fixtures}/account-sync-v1.json", "status" => "identical",
                     "reason" => nil }, document["fixtures"].first)
      assert_equal before, file_states(fixtures), "--check never writes"
    end
  end

  def test_snapshot_check_reports_drift_with_exit_codes
    Dir.mktmpdir do |dir|
      fixtures = copy_of_v1_fixtures(dir)
      billing = File.join(fixtures, "billing-money-v1.json")
      File.binwrite(billing, File.binread(billing).sub('"amount": 1250', '"amount": 1'))
      # Only source metadata and layout change: still identical.
      tenant = File.join(fixtures, "tenant-v1.json")
      document = JSON.parse(File.read(tenant))
      document["source"]["ruby_version"] = "0.0.0"
      File.write(tenant, JSON.generate(document))
      File.delete(File.join(fixtures, "scheduled-v1.json"))
      # Volatile metadata stored in a baseline is compared as stored.
      array = File.join(fixtures, "builtin-array-v1.json")
      document = JSON.parse(File.read(array))
      document["job"]["job_id"] = "6b3c0f4e-0000-4000-8000-000000000000"
      File.write(array, JSON.generate(document))
      before = file_states(fixtures)

      out, err, code = snapshot_check(fixtures)
      assert_equal [1, ""], [code, err]
      assert_includes out, "different billing-money-v1  #{billing}\n"
      assert_includes out, "different builtin-array-v1  #{array}\n"
      assert_includes out, "missing   scheduled-v1  #{fixtures}/scheduled-v1.json\n"
      assert_includes out, "identical tenant-v1  #{tenant}\n"
      assert_equal 32, out.lines.size, "one line per fixture, a blank line and the summary"
      assert_match(/^30 fixtures: 27 identical, 2 different, 1 missing, 0 invalid$/, out)

      json, err, code = snapshot_check(fixtures, "--format", "json")
      assert_equal [1, ""], [code, err]
      assert_equal "fail", JSON.parse(json)["status"]
      assert_equal({ "name" => "billing-money-v1", "path" => billing, "status" => "different", "reason" => nil },
        JSON.parse(json)["fixtures"].find { |f| f["name"] == "billing-money-v1" })
      assert_equal [json, code], snapshot_check(fixtures, "--format", "json").values_at(0, 2), "byte-for-byte deterministic"
      assert_equal before, file_states(fixtures), "--check never writes"

      File.write(File.join(fixtures, "exploding-v1.json"), "{")
      before = file_states(fixtures)
      out, err, code = snapshot_check(fixtures)
      assert_equal [2, ""], [code, err], "an invalid baseline outranks drift"
      assert_includes out, "invalid   exploding-v1  #{fixtures}/exploding-v1.json  (invalid JSON:"
      assert_match(/^30 fixtures: 26 identical, 2 different, 1 missing, 1 invalid$/, out)
      assert_equal "tool_error", JSON.parse(snapshot_check(fixtures, "--format", "json").first)["status"]
      assert_equal before, file_states(fixtures), "--check never writes"
    end
  end

  def test_snapshot_check_usage_and_configuration_errors
    Dir.mktmpdir do |dir|
      log = File.join(dir, "boot.log")
      out, err, code = snapshot_check(dir, "--update", env: { "JOBPAYLOAD_BOOT_LOG" => log })
      assert_equal ["", 2], [out, code]
      assert_includes err, "jobpayload: error: --check and --update cannot be used together"
      refute File.exist?(log), "rejected before booting the application"

      file = File.join(dir, "not-a-dir")
      File.write(file, "x")
      out, err, code = snapshot_check(file)
      assert_equal ["", 2], [out, code]
      assert_includes err, "output path is not a directory"

      missing = File.join(dir, "no-such-dir")
      out, err, code = snapshot_check(missing)
      assert_equal [1, ""], [code, err]
      assert_match(/^30 fixtures: 0 identical, 0 different, 30 missing, 0 invalid$/, out)
      refute File.exist?(missing), "--check never creates the fixture directory"

      cases = File.join(dir, "cases.rb")
      File.write(cases, "JobPayload.define { fixture('boom-v1') { raise 'boom' } }\n")
      out, err, code = run_cli("snapshot", "--check", "--boot", v1_boot, "--cases", cases, "--output", dir)
      assert_equal ["", 2], [out, code]
      assert_includes err, 'fixture "boom-v1"'

      out, _err, code = run_cli("snapshot", "--help")
      assert_equal 0, code
      assert_includes out, "--check"
    end
  end

  RACE_HOOK = File.expand_path("support/race_after_lstat.rb", __dir__)
  SENTINEL = "JOBPAYLOAD_SECRET_SENTINEL_NOT_FOR_OUTPUT"

  # Like run_cli, but a run that does not finish within +seconds+ is killed
  # (with its process group) and fails the test instead of hanging the suite.
  def run_cli_with_deadline(*args, env: {}, seconds: 120)
    Open3.popen3(env, RbConfig.ruby, "-I", File.join(ROOT, "lib"), EXE, *args, chdir: ROOT, pgroup: true) do |stdin, out, err, wait|
      stdin.close
      readers = [out, err].map { |io| Thread.new { io.read } }
      unless wait.join(seconds)
        Process.kill("KILL", -wait.pid)
        wait.join
        flunk "jobpayload #{args.first(2).join(" ")} did not finish within #{seconds}s"
      end
      [*readers.map(&:value), wait.value.exitstatus]
    end
  end

  # A real process, with the fixture entry replaced between lstat and open
  # (test/support/race_after_lstat.rb).
  def test_snapshot_check_entry_replaced_after_lstat_in_a_real_process
    {
      "symlink" => "replaced by a symbolic link after it was checked (not followed)",
      "fifo" => "replaced by something that is not a regular file after it was checked",
      "replace" => "replaced by a different file after it was checked",
      "remove" => "file disappeared after it was checked"
    }.each do |mode, reason|
      Dir.mktmpdir do |dir|
        fixtures = copy_of_v1_fixtures(dir)
        tenant = File.join(fixtures, "tenant-v1.json")
        target =
          case mode
          when "symlink" then File.join(dir, "secret.txt").tap { |f| File.write(f, "#{SENTINEL}\n") }
          when "replace" then File.join(fixtures, "tenant-v1.json.new").tap { |f| FileUtils.cp(tenant, f) }
          else ""
          end
        env = { "JOBPAYLOAD_TEST_RACE_HOOK" => RACE_HOOK, "JOBPAYLOAD_TEST_RACE" => mode,
                "JOBPAYLOAD_TEST_RACE_FIXTURE" => "tenant-v1.json", "JOBPAYLOAD_TEST_RACE_TARGET" => target }

        out, err, code = run_cli_with_deadline("snapshot", "--check", "--boot", v1_boot, "--cases", v1_cases,
          "--output", fixtures, env: env)
        assert_equal [2, ""], [code, err], mode
        assert_includes out, "invalid   tenant-v1  #{tenant}  (#{reason})\n", mode
        assert_match(/^30 fixtures: 29 identical, 0 different, 0 missing, 1 invalid$/, out, mode)
        refute_includes out, SENTINEL, mode

        # The entry is replaced again on this second run (except after
        # "replace", whose source is gone): JSON output carries no secret either.
        next if mode == "replace"

        FileUtils.rm_f(tenant) # the symlink or FIFO itself, never its target
        FileUtils.cp(v1_fixture("tenant-v1"), tenant)
        json, err, code = run_cli_with_deadline("snapshot", "--check", "--boot", v1_boot, "--cases", v1_cases,
          "--output", fixtures, "--format", "json", env: env)
        assert_equal [2, ""], [code, err], mode
        assert_equal({ "status" => "invalid", "reason" => reason },
          JSON.parse(json)["fixtures"].find { |f| f["name"] == "tenant-v1" }.slice("status", "reason"), mode)
        refute_includes json, SENTINEL, mode
      end
    end
  end

  def test_snapshot_check_through_a_symlinked_output_directory
    Dir.mktmpdir do |dir|
      fixtures = copy_of_v1_fixtures(dir)
      link = File.join(dir, "linked")
      File.symlink(fixtures, link)
      out, err, code = snapshot_check(link)
      assert_equal [0, ""], [code, err]
      assert_match(/^30 fixtures: 30 identical, 0 different, 0 missing, 0 invalid$/, out)
    end
  end

  # `check` keeps reading symlinked fixtures (only `snapshot --check` refuses
  # them).
  def test_check_still_reads_symlinked_fixtures
    Dir.mktmpdir do |dir|
      outside = File.join(dir, "outside")
      Dir.mkdir(outside)
      fixtures = File.join(dir, "fixtures")
      Dir.mkdir(fixtures)
      %w[tenant-v1 legacy-billing-v1].each do |name|
        FileUtils.cp(v1_fixture(name), outside)
        File.symlink(File.join(outside, "#{name}.json"), File.join(fixtures, "#{name}.json"))
      end
      FileUtils.cp(v1_fixture("billing-money-v1"), fixtures)

      out, err, code = run_cli("check", "--boot", v1_boot, "--fixtures", fixtures)
      assert_equal [0, ""], [code, err]
      assert_equal "PASS billing-money-v1\nPASS legacy-billing-v1\nPASS tenant-v1\n", out.lines.first(3).join

      out, err, code = run_cli("check", "--boot", v1_boot, "--fixtures", File.join(fixtures, "tenant-v1.json"))
      assert_equal [0, ""], [code, err]
      assert out.start_with?("PASS tenant-v1\n"), out

      File.write(File.join(outside, "tenant-v1.json"), "{ nope")
      out, err, code = run_cli("check", "--boot", v1_boot, "--fixtures", fixtures, "--format", "json")
      assert_equal [2, ""], [code, err]
      assert_equal [%w[tenant-v1 AJP001 fatal]], JSON.parse(out)["findings"].map { |f| f.values_at("fixture", "code", "severity") }
    end
  end

  def test_snapshot_check_boots_once_and_evaluates_each_case_once
    Dir.mktmpdir do |dir|
      cases = File.join(dir, "cases.rb")
      File.write(cases, <<~RUBY)
        JobPayload.define do
          fixture("counted-a-v1") { File.write(ENV.fetch("EVAL_LOG"), "a\n", mode: "a"); ExplodingJob.new("a") }
          fixture("counted-b-v1") { File.write(ENV.fetch("EVAL_LOG"), "b\n", mode: "a"); ExplodingJob.new("b") }
        end
      RUBY
      fixtures = File.join(dir, "fixtures")
      boot_log = File.join(dir, "boot.log")
      eval_log = File.join(dir, "eval.log")
      marker = File.join(dir, "performed")
      env = { "JOBPAYLOAD_BOOT_LOG" => boot_log, "EVAL_LOG" => eval_log, "JOBPAYLOAD_PERFORM_MARKER" => marker }
      _out, err, code = run_cli("snapshot", "--boot", v1_boot, "--cases", cases, "--output", fixtures, env: env)
      assert_equal [0, ""], [code, err]
      [boot_log, eval_log].each { |log| File.delete(log) }

      out, err, code = run_cli("snapshot", "--check", "--boot", v1_boot, "--cases", cases, "--output", fixtures, env: env)
      assert_equal [0, ""], [code, err]
      assert_match(/^2 fixtures: 2 identical, 0 different, 0 missing, 0 invalid$/, out)
      assert_equal 1, File.readlines(boot_log).size, "booted once"
      assert_equal %W[a\n b\n], File.readlines(eval_log), "each case evaluated once"
      refute File.exist?(marker), "no job is performed"
    end
  end

  def test_snapshot_case_errors_are_tool_errors
    Dir.mktmpdir do |dir|
      cases = File.join(dir, "cases.rb")
      File.write(cases, "JobPayload.define { fixture('dup') { ExplodingJob.new }; fixture('dup') { ExplodingJob.new } }\n")
      out, err, code = run_cli("snapshot", "--boot", v1_boot, "--cases", cases, "--output", File.join(dir, "out"))
      assert_equal ["", 2], [out, code]
      assert_includes err, 'duplicate fixture name "dup"'

      File.write(cases, "raise 'broken cases file'\n")
      out, err, code = run_cli("snapshot", "--boot", v1_boot, "--cases", cases, "--output", File.join(dir, "out"))
      assert_equal ["", 2], [out, code]
      assert_includes err, "jobpayload: error: failed to load cases file #{cases}: RuntimeError: broken cases file"

      File.write(cases, "JobPayload.define { fixture('not-a-job') { Money.new(1, 'USD') } }\n")
      out, err, code = run_cli("snapshot", "--boot", v1_boot, "--cases", cases, "--output", File.join(dir, "out"))
      assert_equal ["", 2], [out, code]
      assert_includes err, "must return an ActiveJob::Base instance, got Money"
      refute File.exist?(File.join(dir, "out", "not-a-job.json"))
    end
  end

  def test_default_paths_and_environment
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      FileUtils.mkdir_p(File.join(dir, "test"))
      File.write(File.join(dir, "config/environment.rb"), "require #{v1_boot.inspect}\n")
      File.write(File.join(dir, "test/jobpayload_cases.rb"), <<~RUBY)
        JobPayload.define do
          fixture("money-v1") { BillingJob.new(Money.new(1, "EUR")) }
          fixture("env-v1") { ExplodingJob.new(ENV["RAILS_ENV"]) }
        end
      RUBY
      log = File.join(dir, "boot.log")
      env = { "JOBPAYLOAD_BOOT_LOG" => log, "RAILS_ENV" => "production" }

      out, err, code = run_cli("snapshot", chdir: dir, env: env)
      assert_equal 0, code, err
      assert_includes out, "created   env-v1  test/jobpayload_fixtures/env-v1.json"
      env_fixture = JSON.parse(File.read(File.join(dir, "test/jobpayload_fixtures/env-v1.json")))
      assert_equal ["test"], env_fixture.dig("job", "arguments"), "RAILS_ENV must default to test, never production"

      out, err, code = run_cli("check", chdir: dir, env: env)
      assert_equal 0, code, err
      assert_equal "PASS env-v1\nPASS money-v1\n\n2 fixtures checked\n2 compatible\n0 incompatible\n0 inconclusive\n", out

      _out, err, code = run_cli("check", "--environment", "staging", chdir: dir, env: env)
      assert_equal 0, code, err
      assert_equal ["boot pid=X RAILS_ENV=test"] * 2 + ["boot pid=X RAILS_ENV=staging"],
        File.readlines(log, chomp: true).map { |l| l.sub(/pid=\d+/, "pid=X") }
    end
  end

  def test_check_boots_the_application_once
    Dir.mktmpdir do |dir|
      log = File.join(dir, "boot.log")
      _out, err, code = run_cli("check", "--boot", v1_boot, "--fixtures", v1_fixtures, env: { "JOBPAYLOAD_BOOT_LOG" => log })
      assert_equal 0, code, err
      assert_equal 1, File.readlines(log).size
    end
  end

  def test_check_text_output
    out, err, code = run_cli("check", "--boot", v1_boot, "--fixtures", v1_fixtures)
    assert_equal 0, code
    assert_empty err
    assert out.start_with?("PASS account-sync-v1\nPASS billing-legacy-money-v1\n")
    assert out.end_with?("30 fixtures checked\n28 compatible\n0 incompatible\n2 inconclusive\n"), out
    assert_equal out, run_cli("check", "--boot", v1_boot, "--fixtures", v1_fixtures).first
  end

  def test_check_json_output_is_pure_and_deterministic
    out, err, code = run_cli("check", "--boot", v1_boot, "--fixtures", v1_fixtures, "--format", "json")
    assert_equal 0, code
    assert_empty err
    document = JSON.parse(out)
    assert_equal "pass", document["status"]
    assert_equal({ "fixtures" => 30, "compatible" => 28, "incompatible" => 0, "inconclusive" => 2, "tool_errors" => 0 },
      document["summary"])
    assert_equal %w[notify-user-missing-v1 notify-users-nested-missing-v1], document["findings"].map { |f| f["fixture"] }

    again, = run_cli("check", "--boot", v1_boot, "--fixtures", v1_fixtures, "--format", "json")
    assert_equal out, again
  end

  def test_application_output_never_reaches_stdout
    out, err, code = run_cli("check", "--boot", v1_boot, "--fixtures", v1_fixture("billing-money-v1"), "--format", "json",
      env: { "JOBPAYLOAD_TEST_NOISY" => "1" })
    assert_equal 0, code, err
    assert_equal "pass", JSON.parse(out)["status"]
    assert_equal "noisy boot output\nmore noise\n", err
  end

  def test_fail_on_inconclusive
    _out, _err, code = run_cli("check", "--boot", v1_boot, "--fixtures", v1_fixtures, "--fail-on-inconclusive")
    assert_equal 1, code

    out, _err, code = run_cli("check", "--boot", v1_boot, "--fixtures", v1_fixture("notify-user-v1"), "--fail-on-inconclusive",
      "--format", "json")
    assert_equal 0, code
    assert_equal "pass", JSON.parse(out)["status"]
  end

  def test_tool_errors_take_priority_over_compatibility_failures
    Dir.mktmpdir do |dir|
      FileUtils.cp(v1_fixture("legacy-billing-v1"), dir)
      File.write(File.join(dir, "broken-v1.json"), "{ nope")
      out, err, code = run_cli("check", "--boot", app_boot("v2_breaking"), "--fixtures", dir, "--format", "json")
      assert_equal 2, code
      assert_empty err
      document = JSON.parse(out)
      assert_equal "tool_error", document["status"]
      assert_equal [%w[broken-v1 AJP001 fatal], %w[legacy-billing-v1 AJP101 error]],
        document["findings"].map { |f| f.values_at("fixture", "code", "severity") }
    end
  end

  def test_environment_errors_during_check_exit_2
    out, err, code = run_cli("check", "--boot", v1_boot, "--fixtures", v1_fixture("notify-user-v1"),
      env: { "JOBPAYLOAD_TEST_NO_DB" => "1" })
    assert_equal 2, code, err
    assert_includes out, "AJP900 fatal notify-user-v1"
    assert_includes out, "\n1 tool error\n"
  end

  # Known limitation: nesting deep enough to exhaust the Ruby stack is not
  # supported, but must exit 2 (tool error), never 1 (incompatible).
  def test_stack_exhaustion_on_a_pathologically_deep_fixture_exits_2
    Dir.mktmpdir do |dir|
      document = JSON.parse(File.read(v1_fixture("notify-user-v1")))
      document["name"] = "deep-v1"
      depth = 20_000
      arguments = "#{'[' * depth}{\"_aj_serialized\":\"NoSuchSerializer\"}#{']' * depth}"
      json = JSON.generate(document).sub(/"arguments":\[.*?\]/) { %("arguments":[#{arguments}]) }
      File.write(File.join(dir, "deep-v1.json"), json)

      out, err, code = run_cli("check", "--boot", v1_boot, "--fixtures", dir, "--format", "json")
      assert_equal 2, code, err
      assert_empty out
      assert_match(/internal error: SystemStackError/, err)
    end
  end

  def test_stack_exhaustion_inside_a_custom_serializer_payload_exits_2
    Dir.mktmpdir do |dir|
      document = JSON.parse(File.read(v1_fixture("billing-money-v1")))
      document["job"]["arguments"] = [{ "_aj_serialized" => "MoneySerializer", "amount" => "DEEP", "currency" => "USD" }]
      depth = 20_000
      json = JSON.generate(document).sub('"DEEP"', "#{'[' * depth}1#{']' * depth}")
      File.write(File.join(dir, "billing-money-v1.json"), json)

      out, err, code = run_cli("check", "--boot", v1_boot, "--fixtures", dir, "--format", "json")
      assert_equal 2, code, err
      document = JSON.parse(out)
      assert_equal "tool_error", document["status"]
      assert_equal(%w[AJP900], document["findings"].map { |f| f["code"] }.uniq)
    end
  end

  def test_application_exception_outside_standard_error_exits_2
    Dir.mktmpdir do |dir|
      boot = File.join(dir, "boot.rb")
      File.write(boot, <<~RUBY)
        require #{app_boot("v2_breaking").inspect}
        class LegacyError < Exception; end
        class RaisingSerializer < ActiveJob::Serializers::ObjectSerializer
          def deserialize(_hash) = raise(LegacyError, "boom")
          def klass = Struct
        end
      RUBY
      document = JSON.parse(File.read(v1_fixture("billing-money-v1")))
      document["job"]["arguments"] = [{ "_aj_serialized" => "RaisingSerializer" }]
      Dir.mkdir(File.join(dir, "fx"))
      File.write(File.join(dir, "fx", "billing-money-v1.json"), JSON.generate(document))

      out, err, code = run_cli("check", "--boot", boot, "--fixtures", File.join(dir, "fx"))
      assert_equal 2, code, err
      assert_empty out
      assert_match(/internal error: LegacyError: boom/, err)
    end
  end

  def test_debug_shows_backtraces
    out, _err, code = run_cli("check", "--boot", app_boot("v2_breaking"), "--fixtures", v1_fixture("tenant-v1"), "--debug")
    assert_equal 1, code
    assert_includes out, "Cause chain:"
    assert_match(%r{test/apps/v2_breaking/environment\.rb:\d+}, out)

    out, = run_cli("check", "--boot", app_boot("v2_breaking"), "--fixtures", v1_fixture("tenant-v1"))
    refute_includes out, "Cause chain:"
  end
end
