# frozen_string_literal: true

# Test-only. Loaded by the dummy application's boot file when
# JOBPAYLOAD_TEST_RACE_HOOK names this file, so a real `jobpayload snapshot
# --check` process replaces one fixture entry after SnapshotChecker's lstat
# and before SecureFixtureReader opens it. Nothing in lib/ knows about it.
#
#   JOBPAYLOAD_TEST_RACE          symlink | fifo | replace | remove
#   JOBPAYLOAD_TEST_RACE_FIXTURE  file name of the fixture to replace
#   JOBPAYLOAD_TEST_RACE_TARGET   symlink target, or the file renamed over it
JobPayload::SecureFixtureReader.singleton_class.prepend(Module.new do
  def read(path, expected)
    if File.basename(path) == ENV.fetch("JOBPAYLOAD_TEST_RACE_FIXTURE")
      case ENV.fetch("JOBPAYLOAD_TEST_RACE")
      when "symlink" then File.delete(path) && File.symlink(ENV.fetch("JOBPAYLOAD_TEST_RACE_TARGET"), path)
      when "fifo" then File.delete(path) && File.mkfifo(path)
      when "replace" then File.rename(ENV.fetch("JOBPAYLOAD_TEST_RACE_TARGET"), path)
      when "remove" then File.delete(path)
      else raise "unknown JOBPAYLOAD_TEST_RACE"
      end
    end
    super
  end
end)
