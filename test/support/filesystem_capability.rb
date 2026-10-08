# frozen_string_literal: true

require "tmpdir"
require "fileutils"

module JobPayloadTest
  # Probes whether the file system under a given directory can store names
  # that are not valid UTF-8 (for example APFS on macOS rejects them with
  # EILSEQ, while ext4 on Linux stores any bytes). Tests that need such names
  # probe the very temporary directory they are about to use, because another
  # mount point can behave differently; nothing is cached.
  #
  # Each probe works in its own fresh subdirectory, so parallel tests never
  # share a path, and removes it before returning.
  module FilesystemCapability
    # Errors that mean "the file system refuses this name". Anything else
    # (EACCES, ENOSPC, EIO, ...) is a real problem and propagates.
    NAME_REJECTED = [Errno::EILSEQ].freeze

    PROBE_NAMES = { file: "probe-\xFF".b, directory: "out\xFF".b }.freeze
    PROBE_CONTENT = "jobpayload probe\n"

    # Set (as on Linux CI) to turn a missing capability into a failure, so
    # the non-UTF-8 end-to-end tests cannot silently stop running.
    REQUIRE_ENV = "JOBPAYLOAD_REQUIRE_NON_UTF8_FILENAMES"

    module_function

    # Returns nil when a +kind+ (:file or :directory) entry whose name is not
    # valid UTF-8 can be created in +dir+, listed with its exact bytes and
    # used; otherwise returns the reason it cannot.
    def non_utf8_name_unsupported_reason(kind, dir)
      name = PROBE_NAMES.fetch(kind)
      Dir.mktmpdir("jobpayload-fs-probe", dir) do |probe_dir|
        path = File.join(probe_dir.b, name)
        begin
          kind == :file ? File.binwrite(path, PROBE_CONTENT) : Dir.mkdir(path)
        rescue *NAME_REJECTED => e
          return "#{e.class} (#{e.message.b.inspect}) creating #{name.inspect}"
        end

        listed = Dir.children(probe_dir).map(&:b)
        return "the file system lists #{listed.inspect} instead of #{[name].inspect}" unless listed == [name]

        if kind == :file
          content = File.binread(path)
          raise "probe file #{path.inspect} reads back #{content.inspect}" unless content == PROBE_CONTENT
        else
          raise "probe directory #{path.inspect} is not a directory" unless File.directory?(path)
        end
        nil
      end
    end

    # Skips the calling test only when the file system under +dir+ cannot
    # store a +kind+ entry with a non-UTF-8 name.
    def skip_unless_non_utf8_names(test, kind, dir)
      reason = non_utf8_name_unsupported_reason(kind, dir)
      return unless reason

      message = "filesystem does not support non-UTF-8 #{kind} names: #{reason}"
      test.flunk("#{message} (#{REQUIRE_ENV} is set)") if ENV[REQUIRE_ENV] == "1"
      test.skip(message)
    end
  end
end
