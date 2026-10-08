# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

# Option values whose bytes are not valid in their encoding (a non-UTF-8 path
# under a UTF-8 locale) must reach option parsing without crashing it. Runs
# in-process with --help, so no file system name is ever created: this holds
# on every platform, including those whose file system rejects such names.
class CLIArgvEncodingTest < Minitest::Test
  INVALID = "out\xFF".dup.force_encoding(Encoding::UTF_8)

  def run_in_process(*argv)
    stdout = StringIO.new
    stderr = StringIO.new
    code = JobPayload::CLI.new(argv, stdout: stdout, stderr: stderr).run
    [stdout.string, stderr.string, code]
  end

  def test_invalid_option_values_do_not_break_option_parsing
    refute INVALID.valid_encoding?
    Dir.mktmpdir do |dir|
      path = File.join(dir.b, INVALID.b).force_encoding(Encoding::UTF_8)
      refute path.valid_encoding?
      [
        ["snapshot", "--help", "--output", path],
        ["snapshot", "--output", path, "--cases", path, "--help"],
        ["check", "--fixtures", path, "--boot", path, "--help"]
      ].each do |argv|
        out, err, code = run_in_process(*argv)
        assert_equal [0, ""], [code, err], argv.inspect
        assert_includes out, "Usage: jobpayload #{argv.first} [options]"
      end
      assert_empty Dir.children(dir), "help never touches the given paths"
    end
  end

  def test_caller_argv_is_not_modified
    argv = ["snapshot", "--help", "--output", INVALID.dup]
    out, err, code = run_in_process(*argv)
    assert_equal [0, ""], [code, err]
    assert_includes out, "Usage: jobpayload snapshot [options]"
    assert_equal Encoding::UTF_8, argv.last.encoding
    assert_equal "out\xFF".b, argv.last.b
  end
end
