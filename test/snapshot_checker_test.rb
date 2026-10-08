# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/in_process_app"

class SnapshotCheckerTest < Minitest::Test
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

  def statuses(entries) = entries.to_h { |e| [e.name, e.status] }

  def path(dir, name) = File.join(dir, "#{name}.json")

  def edit(dir, name)
    document = JSON.parse(File.read(path(dir, name)))
    yield document
    File.write(path(dir, name), JSON.generate(document))
  end

  # Names, bytes and modification times of everything under +dir+.
  def tree(dir)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).reject { |e| File.basename(e) == "." }.sort.to_h do |entry|
      full = File.join(dir, entry)
      [entry, [File.file?(full) ? File.binread(full) : :dir, File.mtime(full)]]
    end
  end

  def test_fresh_snapshot_is_identical
    Dir.mktmpdir do |dir|
      snapshot(dir)
      entries = check(dir)
      assert_equal({ "plot-v1" => :identical, "stamped-v1" => :identical }, statuses(entries))
      assert_equal %w[plot-v1 stamped-v1], entries.map(&:name)
      assert_equal [path(dir, "plot-v1"), path(dir, "stamped-v1")], entries.map(&:path)
      assert(entries.all? { |e| e.reason.nil? })
      assert_equal 0, JobPayload::SnapshotChecker.exit_code(entries)
    end
  end

  def test_source_key_order_and_layout_are_ignored
    Dir.mktmpdir do |dir|
      snapshot(dir)
      document = JSON.parse(File.read(path(dir, "stamped-v1")))
      document["source"] = { "ruby_version" => "0.0.0", "active_job_version" => "1.0", "extra" => true }
      document = document.to_a.reverse.to_h
      document["job"] = document["job"].to_a.reverse.to_h
      File.write(path(dir, "stamped-v1"), JSON.pretty_generate(document, indent: "\t", space: "   "))
      File.write(path(dir, "plot-v1"), JSON.generate(JSON.parse(File.read(path(dir, "plot-v1")))))

      assert_equal({ "plot-v1" => :identical, "stamped-v1" => :identical }, statuses(check(dir)))
    end
  end

  def test_source_only_change_is_identical
    Dir.mktmpdir do |dir|
      snapshot(dir)
      edit(dir, "plot-v1") { |doc| doc.delete("source") }
      edit(dir, "stamped-v1") { |doc| doc["source"]["jobpayload_version"] = "9.9.9" }
      assert_equal({ "plot-v1" => :identical, "stamped-v1" => :identical }, statuses(check(dir)))
    end
  end

  # The stored job is compared as is: snapshot's normalization of volatile
  # metadata applies to the current job only, so an edited baseline is never
  # masked by normalizing it again.
  def test_edited_baseline_metadata_is_different
    {
      "job_id" => "6b3c0f4e-0000-4000-8000-000000000000",
      "executions" => 3,
      "enqueued_at" => "2024-05-01T10:00:00.000000000Z",
      "provider_job_id" => "provider-1",
      "exception_executions" => { "[RuntimeError]" => 2 },
      "scheduled_at" => "2024-05-01T10:00:00.000000000Z",
      "stamp" => "edited" # custom metadata from StampedJob#serialize
    }.each do |key, value|
      Dir.mktmpdir do |dir|
        snapshot(dir)
        edit(dir, "stamped-v1") { |doc| doc["job"][key] = value }
        assert_equal({ "plot-v1" => :identical, "stamped-v1" => :different }, statuses(check(dir)), key)
      end
    end
  end

  def test_payload_changes_are_different
    {
      "argument value" => ->(job) { job["arguments"][0]["a"][0]["x"] = 9 },
      "added key" => ->(job) { job["arguments"][0]["new"] = 1 },
      "removed key" => ->(job) { job.delete("queue_name") },
      "added element" => ->(job) { job["arguments"] << "extra" },
      "array order" => ->(job) { job["arguments"].reverse! },
      "null vs missing key" => ->(job) { job.delete("priority") }
    }.each do |label, change|
      Dir.mktmpdir do |dir|
        snapshot(dir)
        edit(dir, "plot-v1") { |doc| change.call(doc["job"]) }
        entries = check(dir)
        assert_equal({ "plot-v1" => :different, "stamped-v1" => :identical }, statuses(entries), label)
        assert_nil entries.first.reason, label
        assert_equal 1, JobPayload::SnapshotChecker.exit_code(entries), label
        assert_equal entries.map(&:to_a), check(dir).map(&:to_a), "repeated checks give the same result"
      end
    end
  end

  def test_comparison_is_type_strict
    {
      "1 vs 1.0" => [1.0, nil, "1", 0.0],
      "null vs false" => [1, false, "1", 0.0],
      "string vs integer" => [1, nil, 1, 0.0],
      "0.0 vs -0.0" => [1, nil, "1", -0.0]
    }.each do |label, stored|
      kase = { "int-v1" => -> { InProcess::PlotJob.new(1, nil, "1", 0.0) } }
      Dir.mktmpdir do |dir|
        snapshot(dir, kase)
        assert_equal :identical, check(dir, kase).sole.status, label
        edit(dir, "int-v1") { |doc| doc["job"]["arguments"] = stored }
        assert_equal :different, check(dir, kase).sole.status, label
      end
    end
  end

  def test_equivalent_json_spellings_are_identical
    kase = { "text-v1" => -> { InProcess::PlotJob.new("caf\u00e9 <&>", 100.0, 12) } }
    Dir.mktmpdir do |dir|
      snapshot(dir, kase)
      text = File.read(path(dir, "text-v1"), encoding: Encoding::UTF_8)
      edited = text.sub("caf\u00e9", "caf\\u00e9").sub("100.0", "1.0e2")
      assert_includes edited, "caf\\u00e9"
      assert_includes edited, "1.0e2"
      File.write(path(dir, "text-v1"), edited)
      assert_equal :identical, check(dir, kase).sole.status
    end
  end

  def test_missing_baseline
    Dir.mktmpdir do |dir|
      snapshot(dir)
      File.delete(path(dir, "plot-v1"))
      entries = check(dir)
      assert_equal({ "plot-v1" => :missing, "stamped-v1" => :identical }, statuses(entries))
      assert_equal 1, JobPayload::SnapshotChecker.exit_code(entries)
    end
  end

  def test_missing_directory_is_reported_and_not_created
    Dir.mktmpdir do |parent|
      dir = File.join(parent, "fixtures")
      entries = check(dir)
      assert_equal({ "plot-v1" => :missing, "stamped-v1" => :missing }, statuses(entries))
      refute File.exist?(dir)
      assert_empty Dir.children(parent)
    end
  end

  def test_invalid_baselines
    {
      "not json" => [->(p) { File.write(p, "{") }, /invalid JSON/],
      "wrong schema" => [->(p) { edit_file(p) { |d| d["jobpayload_schema"] = 2 } }, /unsupported jobpayload_schema 2/],
      "name mismatch" => [->(p) { edit_file(p) { |d| d["name"] = "other-v1" } }, /does not match file name/],
      "no job" => [->(p) { edit_file(p) { |d| d.delete("job") } }, /job must be an object/],
      "bad utf8" => [->(p) { File.binwrite(p, "{\"name\": \"\xFF\"}".b) }, /not valid UTF-8/],
      "directory" => [->(p) { File.delete(p) && Dir.mkdir(p) }, /not a regular file/]
    }.each do |label, (break_it, reason)|
      Dir.mktmpdir do |dir|
        snapshot(dir)
        break_it.call(path(dir, "plot-v1"))
        entries = check(dir)
        entry = entries.first
        assert_equal :invalid, entry.status, label
        assert_match reason, entry.reason, label
        assert entry.reason.valid_encoding?, label
        assert_equal 2, JobPayload::SnapshotChecker.exit_code(entries), label
      end
    end
  end

  def test_baselines_that_cannot_be_canonicalized_are_invalid
    {
      "Infinity" => ->(text) { text.sub('"y": 2', '"y": 1e400') },
      "-Infinity" => ->(text) { text.sub('"y": 2', '"y": -1e400') },
      "too deep" => ->(text) { text.sub('"x": 1', %("x": #{"[" * 150}1#{"]" * 150})) },
      "far too deep" => ->(text) { text.sub('"x": 1', %("x": #{"[" * 20_000}1#{"]" * 20_000})) },
      # Exhausts the stack in recursive json parsers (json 2.7).
      "stack deep" => ->(text) { text.sub('"x": 1', %("x": #{"[" * 1_000_000}1#{"]" * 1_000_000})) }
    }.each do |label, break_it|
      Dir.mktmpdir do |dir|
        snapshot(dir)
        File.write(path(dir, "plot-v1"), break_it.call(File.read(path(dir, "plot-v1"))))
        entries = check(dir)
        assert_equal({ "plot-v1" => :invalid, "stamped-v1" => :identical }, statuses(entries), label)
        assert_match(/\Ajob cannot be canonicalized: /, entries.first.reason, label)
        assert_equal 2, JobPayload::SnapshotChecker.exit_code(entries), label
      end
    end
  end

  # An inaccessible fixture (for example in a directory that cannot be
  # searched) is not a missing one. Simulated, because root bypasses
  # permission checks.
  def test_access_errors_are_invalid_not_missing
    Dir.mktmpdir do |dir|
      snapshot(dir)
      original = File.method(:lstat)
      File.define_singleton_method(:lstat) { |p| raise Errno::EACCES, p }
      begin
        entries = check(dir)
      ensure
        File.define_singleton_method(:lstat, original)
      end
      assert_equal({ "plot-v1" => :invalid, "stamped-v1" => :invalid }, statuses(entries))
      assert_match(/\Acannot access file: Permission denied/, entries.first.reason)
      assert_equal 2, JobPayload::SnapshotChecker.exit_code(entries)
    end
  end

  def test_symlinks
    Dir.mktmpdir do |dir|
      snapshot(dir)
      File.rename(path(dir, "plot-v1"), File.join(dir, "elsewhere.json"))
      File.symlink(File.join(dir, "elsewhere.json"), path(dir, "plot-v1"))
      File.delete(path(dir, "stamped-v1"))
      File.symlink(File.join(dir, "gone.json"), path(dir, "stamped-v1"))
      entries = check(dir)
      assert_equal({ "plot-v1" => :identical, "stamped-v1" => :invalid }, statuses(entries))
      assert_equal "not a regular file", entries.last.reason

      File.delete(path(dir, "stamped-v1"))
      File.symlink(path(dir, "stamped-v1"), path(dir, "stamped-v1"))
      assert_equal "not a regular file", check(dir).last.reason
    end
  end

  def edit_file(path)
    document = JSON.parse(File.read(path))
    yield document
    File.write(path, JSON.generate(document))
  end

  def test_exit_code_precedence
    entry = ->(status) { JobPayload::SnapshotChecker::Entry.new("x", "x", status, nil) }
    {
      %i[identical identical] => 0,
      %i[identical different] => 1,
      %i[missing identical] => 1,
      %i[different missing] => 1,
      %i[different invalid] => 2,
      %i[missing invalid] => 2,
      %i[invalid missing identical] => 2,
      %i[invalid] => 2,
      [] => 0
    }.each do |statuses, expected|
      entries = statuses.map(&entry)
      assert_equal expected, JobPayload::SnapshotChecker.exit_code(entries), statuses.inspect
      assert_equal %w[pass fail tool_error][expected], JobPayload::SnapshotChecker.status(entries), statuses.inspect
    end
  end

  def test_check_never_writes
    Dir.mktmpdir do |dir|
      snapshot(dir)
      edit(dir, "plot-v1") { |doc| doc["job"]["arguments"] = [] }
      File.delete(path(dir, "stamped-v1"))
      File.write(File.join(dir, "orphan-v1.json"), "not even json")
      File.utime(Time.at(1_000_000_000), Time.at(1_000_000_000), dir)
      before = tree(dir)
      dir_mtime = File.mtime(dir)

      entries = check(dir)
      assert_equal({ "plot-v1" => :different, "stamped-v1" => :missing }, statuses(entries))
      assert_equal before, tree(dir)
      assert_equal dir_mtime, File.mtime(dir), "no entry was created, renamed or removed"
    end
  end

  def test_orphaned_fixtures_are_ignored
    Dir.mktmpdir do |dir|
      snapshot(dir)
      File.write(File.join(dir, "orphan-v1.json"), "{")
      assert_equal %w[plot-v1 stamped-v1], check(dir).map(&:name)
    end
  end

  def test_a_failing_case_raises_before_anything_is_compared
    Dir.mktmpdir do |dir|
      snapshot(dir)
      before = tree(dir)
      cases = CASES.merge("boom-v1" => -> { raise "boom" })
      error = assert_raises(JobPayload::ConfigurationError) { check(dir, cases) }
      assert_match(/"boom-v1".*raised RuntimeError: boom/, error.message)
      assert_equal before, tree(dir)
    end
  end
end
