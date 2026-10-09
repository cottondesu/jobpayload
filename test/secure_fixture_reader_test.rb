# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/in_process_app"

# The baseline read of `snapshot --check` must not trust the path between the
# lstat check and the read: the entry can be replaced in between. Each race is
# made deterministic by performing the replacement at exactly that point, in
# a wrapper around SecureFixtureReader.read (after SnapshotChecker's lstat,
# before the reader's open). This suite is serial, so the temporary
# singleton-method replacements here cannot leak into other tests.
class SecureFixtureReaderTest < Minitest::Test
  Reader = JobPayload::SecureFixtureReader

  SENTINEL = "JOBPAYLOAD_SECRET_SENTINEL_NOT_FOR_OUTPUT"

  CASES = {
    "plot-v1" => -> { InProcess::PlotJob.new({ "z" => 1, "a" => [InProcess::Point.new(1, 2)] }, :sym) },
    "stamped-v1" => -> { InProcess::StampedJob.new(1.5).tap { |j| j.stamp = "s" } }
  }.freeze

  def setup
    InProcess::PERFORMED.clear
  end

  def teardown
    assert_empty InProcess::PERFORMED, "jobs are never performed"
  end

  def registry(cases)
    JobPayload::CaseRegistry.new.tap do |registry|
      cases.each { |name, block| registry.add(name, "test", &block) }
    end
  end

  def snapshot(dir, cases = CASES)
    JobPayload::Snapshotter.new(registry: registry(cases), output_dir: dir).call
  end

  def check(dir, cases = CASES)
    JobPayload::SnapshotChecker.new(registry: registry(cases), fixtures_dir: dir).call
  end

  def path(dir, name) = File.join(dir, "#{name}.json")

  def statuses(entries) = entries.to_h { |e| [e.name, e.status] }

  def entry(entries, name) = entries.find { |e| e.name == name }

  # Runs +swap+ on the fixture named +name+ after SnapshotChecker's lstat and
  # before the reader opens it.
  def after_lstat(name, swap)
    original = Reader.method(:read)
    Reader.define_singleton_method(:read) do |path, stat|
      swap.call(path) if File.basename(path) == "#{name}.json"
      original.call(path, stat)
    end
    yield
  ensure
    Reader.define_singleton_method(:read, original)
  end

  # Paths of every descriptor whose contents are read.
  def read_paths
    reads = []
    original = Reader.method(:read_verified)
    Reader.define_singleton_method(:read_verified) { |io| reads << io.path && original.call(io) }
    yield
    reads
  ensure
    Reader.define_singleton_method(:read_verified, original)
  end

  def open_descriptors
    Dir.children("/dev/fd").size
  end

  # A file outside the fixture directory that must never be read.
  def secret(dir)
    File.join(dir, "secret.txt").tap { |file| File.write(file, "#{SENTINEL}\n" * 3) }
  end

  def assert_invalid(entries, name, reason, label = nil)
    found = entry(entries, name)
    assert_equal :invalid, found.status, label
    assert_equal reason, found.reason, label
    refute_includes found.reason, SENTINEL, label
    assert_equal 2, JobPayload::SnapshotChecker.exit_code(entries), label
  end

  def test_unchanged_regular_fixtures_are_read_through_the_verified_descriptor
    Dir.mktmpdir do |dir|
      snapshot(dir)
      before = Dir.children(dir).sort.to_h { |e| [e, [File.binread(File.join(dir, e)), File.mtime(File.join(dir, e))]] }
      entries = nil
      reads = read_paths { entries = check(dir) }
      assert_equal({ "plot-v1" => :identical, "stamped-v1" => :identical }, statuses(entries))
      assert_equal [path(dir, "plot-v1"), path(dir, "stamped-v1")], reads
      assert_equal before, Dir.children(dir).sort.to_h { |e| [e, [File.binread(File.join(dir, e)), File.mtime(File.join(dir, e))]] }
    end
  end

  def test_entry_replaced_after_lstat_is_invalid_and_never_read
    Dir.mktmpdir do |outside|
      secret_file = secret(outside)
      {
        "symlink to a secret file" => [lambda { |p, _dir|
          File.delete(p)
          File.symlink(secret_file, p)
        }, "replaced by a symbolic link after it was checked (not followed)"],
        "symlink to a valid copy of the fixture" => [lambda { |p, _dir|
          copy = File.join(outside, "copy.json")
          File.binwrite(copy, File.binread(p))
          File.delete(p)
          File.symlink(copy, p)
        }, "replaced by a symbolic link after it was checked (not followed)"],
        # Following the link would reach the very inode lstat saw, so only
        # O_NOFOLLOW (not the identity check) can refuse this one.
        "symlink to the checked file itself" => [lambda { |p, dir|
          moved = File.join(dir, "moved.json.bak")
          File.rename(p, moved)
          File.symlink(moved, p)
        }, "replaced by a symbolic link after it was checked (not followed)"],
        "another regular file with valid identical content" => [lambda { |p, dir|
          other = File.join(dir, "other.json.tmp")
          File.binwrite(other, File.binread(p))
          File.rename(other, p)
        }, "replaced by a different file after it was checked"],
        "directory" => [lambda { |p, _dir|
          File.delete(p)
          Dir.mkdir(p)
        }, "replaced by something that is not a regular file after it was checked"],
        "removed" => [lambda { |p, _dir|
          File.delete(p)
        }, "file disappeared after it was checked"]
      }.each do |label, (swap, reason)|
        Dir.mktmpdir do |dir|
          snapshot(dir)
          entries = nil
          reads = read_paths { after_lstat("plot-v1", ->(p) { swap.call(p, dir) }) { entries = check(dir) } }
          assert_invalid(entries, "plot-v1", reason, label)
          assert_equal :identical, entry(entries, "stamped-v1").status, "#{label}: other fixtures still compared"
          assert_equal [path(dir, "stamped-v1")], reads, "#{label}: nothing is read from the replaced entry"
        end
      end
    end
  end

  def test_mixed_results_keep_every_case_and_invalid_wins
    cases = CASES.merge("gone-v1" => CASES["plot-v1"], "raced-v1" => CASES["plot-v1"])
    Dir.mktmpdir do |dir|
      snapshot(dir, cases)
      File.delete(path(dir, "gone-v1"))
      document = JSON.parse(File.read(path(dir, "stamped-v1")))
      document["job"]["stamp"] = "edited"
      File.write(path(dir, "stamped-v1"), JSON.generate(document))

      runs = 2.times.map do
        after_lstat("raced-v1", ->(p) { File.delete(p) }) { check(dir, cases) }.tap do
          snapshot(dir, cases.slice("raced-v1"))
        end
      end
      entries = runs.first
      assert_equal %w[gone-v1 plot-v1 raced-v1 stamped-v1], entries.map(&:name)
      assert_equal({ "gone-v1" => :missing, "plot-v1" => :identical, "raced-v1" => :invalid, "stamped-v1" => :different },
        statuses(entries))
      assert_equal 2, JobPayload::SnapshotChecker.exit_code(entries)
      assert_equal runs.first.map(&:to_a), runs.last.map(&:to_a), "deterministic"
    end
  end

  def test_missing_secure_open_flags_fail_closed
    assert_nil Reader.open_flags(Module.new.tap { |m| m.const_set(:RDONLY, 0) })
    without_nofollow = Module.new.tap { |m| { RDONLY: 0, NOFOLLOW: 0, NONBLOCK: 4 }.each { |k, v| m.const_set(k, v) } }
    assert_nil Reader.open_flags(without_nofollow), "Ruby defines a missing flag as 0"
    flags = Reader.open_flags
    [File::NOFOLLOW, File::NONBLOCK].each { |flag| assert_equal flag, flags & flag }
    [File::WRONLY, File::RDWR, File::CREAT, File::TRUNC, File::APPEND].each { |flag| assert_equal 0, flags & flag }

    Dir.mktmpdir do |dir|
      snapshot(dir)
      original = Reader.method(:open_flags)
      Reader.define_singleton_method(:open_flags) { |*| nil }
      begin
        entries = nil
        reads = read_paths { entries = check(dir) }
      ensure
        Reader.define_singleton_method(:open_flags, original)
      end
      assert_invalid(entries, "plot-v1", Reader::UNSUPPORTED)
      assert_invalid(entries, "stamped-v1", Reader::UNSUPPORTED)
      assert_empty reads, "no fallback to a plain read"
    end
  end

  # In a child process with a short deadline, so a regression that blocks
  # (opening the FIFO without O_NONBLOCK) fails fast instead of hanging.
  def test_fifo_swapped_in_after_lstat_never_blocks
    Dir.mktmpdir do |dir|
      file = File.join(dir, "fifo-v1.json")
      File.write(file, "{}")
      script = <<~RUBY
        require "jobpayload"
        stat = File.lstat(ARGV[0])
        File.delete(ARGV[0])
        File.mkfifo(ARGV[0])
        result = JobPayload::SecureFixtureReader.read(ARGV[0], stat)
        print [result.content.inspect, result.reason].join("|")
      RUBY
      Open3.popen3(RbConfig.ruby, "-I", File.join(JobPayloadTest::ROOT, "lib"), "-e", script, file, pgroup: true) do |stdin, out, err, wait|
        stdin.close
        readers = [out, err].map { |io| Thread.new { io.read } }
        unless wait.join(15)
          Process.kill("KILL", -wait.pid)
          wait.join
          flunk "reading a FIFO swapped in after lstat blocked"
        end
        assert_equal ["nil|replaced by something that is not a regular file after it was checked", ""], readers.map(&:value)
        assert wait.value.success?
      end
    end
  end

  def test_open_errors_are_invalid
    Dir.mktmpdir do |dir|
      snapshot(dir)
      # Simulated, because root bypasses permission checks.
      File.define_singleton_method(:new) { |p, *_rest, **_kw| raise Errno::EACCES, p }
      begin
        entries = check(dir)
      ensure
        File.singleton_class.send(:remove_method, :new)
      end
      assert_equal :invalid, entry(entries, "plot-v1").status
      assert_match(/\Acannot read file: Permission denied/, entry(entries, "plot-v1").reason)
      assert_equal 2, JobPayload::SnapshotChecker.exit_code(entries)
    end
  end

  def test_descriptors_are_closed_on_every_path
    cases = (1..120).to_h { |i| [format("case-%03d-v1", i), CASES["plot-v1"]] }
    swaps = [
      ->(p) { File.delete(p) },
      ->(p) { File.delete(p) && Dir.mkdir(p) },
      ->(p) { File.binwrite("#{p}.tmp", File.binread(p)) && File.rename("#{p}.tmp", p) },
      ->(p) { File.write(p, "{") },
      ->(_p) {}
    ]
    Dir.mktmpdir do |dir|
      snapshot(dir, cases)
      before = open_descriptors
      original = Reader.method(:read)
      Reader.define_singleton_method(:read) do |p, stat|
        swaps[File.basename(p)[/\d+/].to_i % swaps.size].call(p)
        original.call(p, stat)
      end
      begin
        entries = check(dir, cases)
      ensure
        Reader.define_singleton_method(:read, original)
      end
      assert_equal 120, entries.size
      assert_equal({ invalid: 96, identical: 24 }, entries.map(&:status).tally)
      assert_equal before, open_descriptors, "no descriptor is left open"
    end
  end

  def test_parse_content_matches_parse
    Dir.mktmpdir do |dir|
      snapshot(dir)
      file = path(dir, "plot-v1")
      parsed = JobPayload::Fixture.parse(file)
      content = File.binread(file).freeze
      from_content = JobPayload::Fixture.parse_content(file, content)
      assert_equal [parsed.name, parsed.job, parsed.source], [from_content.name, from_content.job, from_content.source]
      assert_equal Encoding::BINARY, content.encoding, "the caller's string is not modified"

      { "{" => /\Ainvalid JSON/, "\xFF".b => /\Afile is not valid UTF-8\z/, "[]" => /\Atop-level JSON value must be an object\z/ }
        .each do |bytes, reason|
          File.binwrite(file, bytes)
          assert_equal JobPayload::Fixture.parse(file).to_a, JobPayload::Fixture.parse_content(file, bytes).to_a
          assert_match reason, JobPayload::Fixture.parse_content(file, bytes).reason
        end
    end
  end
end
