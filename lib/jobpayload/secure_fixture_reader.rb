# frozen_string_literal: true

module JobPayload
  # Reads a baseline fixture for `snapshot --check` without trusting the path
  # to still name the entry that was checked with lstat.
  #
  # The file is opened read-only with O_NOFOLLOW (a final-component symlink is
  # refused, not followed) and O_NONBLOCK (opening a FIFO never waits for a
  # writer). The open descriptor is then checked with fstat: it must be a
  # regular file with the device and inode lstat reported. Only then is
  # anything read, and only from that descriptor; the path is never reopened.
  #
  # This defends against the fixture's directory entry being replaced between
  # lstat and open. It does not pin parent directories, and it cannot stop a
  # process from rewriting the verified file's contents while it is read.
  module SecureFixtureReader
    # content is set on success, reason otherwise.
    Result = Struct.new(:content, :reason)

    UNSUPPORTED = "cannot open file safely: this platform lacks O_NOFOLLOW or O_NONBLOCK"

    module_function

    # +expected+ is the File::Stat from File.lstat(path), already known to be
    # a regular file.
    def read(path, expected)
      flags = open_flags
      return Result.new(nil, UNSUPPORTED) unless flags

      io = begin
        File.new(path, flags, binmode: true)
      rescue Errno::ENOENT
        return Result.new(nil, "file disappeared after it was checked")
      rescue *symlink_errors
        return Result.new(nil, "replaced by a symbolic link after it was checked (not followed)")
      rescue SystemCallError => e
        return Result.new(nil, "cannot read file: #{e.message}")
      end

      begin
        actual = io.stat
        return Result.new(nil, "replaced by something that is not a regular file after it was checked") unless actual.file?
        unless actual.dev == expected.dev && actual.ino == expected.ino
          return Result.new(nil, "replaced by a different file after it was checked")
        end

        Result.new(read_verified(io), nil)
      rescue SystemCallError, IOError => e
        Result.new(nil, "cannot read file: #{e.message}")
      ensure
        io.close
      end
    end

    # Read-only, no-follow, non-blocking; never creates or truncates. nil when
    # the platform cannot provide that (Ruby defines missing flags as 0), so
    # the caller fails closed instead of falling back to a plain read.
    def open_flags(constants = File::Constants)
      nofollow = constants.const_defined?(:NOFOLLOW) ? constants::NOFOLLOW : 0
      nonblock = constants.const_defined?(:NONBLOCK) ? constants::NONBLOCK : 0
      return nil if nofollow.zero? || nonblock.zero?

      flags = constants::RDONLY | nofollow | nonblock
      # Never become the controlling terminal if the entry was swapped for one.
      flags |= constants::NOCTTY if constants.const_defined?(:NOCTTY)
      flags
    end

    # Errors open(2) reports for a final-component symlink under O_NOFOLLOW:
    # ELOOP on Linux and macOS, EMLINK on FreeBSD, EFTYPE on NetBSD.
    def symlink_errors
      %i[ELOOP EMLINK EFTYPE].filter_map { |name| Errno.const_get(name) if Errno.const_defined?(name) }
    end

    # Only ever called on a descriptor that passed the checks above.
    def read_verified(io)
      io.read
    end
  end
end
