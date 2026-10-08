# frozen_string_literal: true

require_relative "test_helper"

# The probe decides whether the non-UTF-8 path tests run or skip, so it is
# checked against a direct attempt on the same file system.
class FilesystemCapabilityTest < Minitest::Test
  Capability = JobPayloadTest::FilesystemCapability

  # Whether the file system under +dir+ keeps a +kind+ entry named +name+
  # with its exact bytes, found without the probe.
  def directly_supported?(kind, name, dir)
    Dir.mktmpdir("direct", dir) do |work|
      path = File.join(work.b, name)
      begin
        kind == :file ? File.binwrite(path, "x") : Dir.mkdir(path)
      rescue Errno::EILSEQ
        return false
      end
      Dir.children(work).map(&:b) == [name]
    end
  end

  def test_probe_agrees_with_a_direct_attempt
    %i[file directory].each do |kind|
      Dir.mktmpdir do |dir|
        reason = Capability.non_utf8_name_unsupported_reason(kind, dir)
        expected = directly_supported?(kind, Capability::PROBE_NAMES.fetch(kind), dir)
        assert_equal expected, reason.nil?, "#{kind}: probe says #{reason.inspect}"
        assert_empty Dir.children(dir), "#{kind}: the probe removes everything it created"
      end
    end
  end

  def test_probe_reports_unrelated_errors_instead_of_skipping
    Dir.mktmpdir do |dir|
      missing = File.join(dir, "missing")
      %i[file directory].each do |kind|
        assert_raises(Errno::ENOENT) { Capability.non_utf8_name_unsupported_reason(kind, missing) }
      end
    end
  end

  def test_only_file_name_rejection_counts_as_unsupported
    assert_equal [Errno::EILSEQ], Capability::NAME_REJECTED
  end
end
