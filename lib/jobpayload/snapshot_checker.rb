# frozen_string_literal: true

require "json"

module JobPayload
  # Compares what the current application serializes for each snapshot case
  # with the fixture already stored for it (`jobpayload snapshot --check`).
  #
  # Read-only: never writes, renames or creates anything. Only the `job`
  # objects are compared, and every key in them counts. The current job is
  # normalized exactly as `snapshot` writes it; the stored job is taken as
  # is, so an edited baseline (including its volatile metadata) is never
  # masked. Both are compared as canonical JSON: `source` metadata, key order
  # and layout are ignored, while value types (1 and 1.0 differ, because
  # Active Job reads them differently) and array order are kept.
  class SnapshotChecker
    # status: :identical, :different, :missing or :invalid; reason is set for
    # :invalid only.
    Entry = Struct.new(:name, :path, :status, :reason)

    STATUSES = %i[identical different missing invalid].freeze

    # Overall status => exit status.
    EXIT_CODES = { "pass" => 0, "fail" => 1, "tool_error" => 2 }.freeze

    def initialize(registry:, fixtures_dir:)
      @registry = registry
      @fixtures_dir = fixtures_dir
    end

    # Evaluates every case first (a failing case raises before anything is
    # compared), then checks the fixtures in name order.
    def call
      snapshotter = Snapshotter.new(registry: @registry, output_dir: @fixtures_dir)
      current = @registry.cases.map { |kase| [kase.name, snapshotter.build_document(kase)["job"]] }
      current.map { |name, job| compare(name, job) }
    end

    # "tool_error" when any baseline is invalid, else "fail" when any differs
    # or is missing, else "pass".
    def self.status(entries)
      statuses = entries.map(&:status)
      return "tool_error" if statuses.include?(:invalid)
      return "fail" if statuses.intersect?(%i[different missing])

      "pass"
    end

    # 2 > 1 > 0, from status.
    def self.exit_code(entries)
      EXIT_CODES.fetch(status(entries))
    end

    # Canonical JSON for a stored job, without normalizing it. Raises
    # ::JSON::JSONError when the job is not something `snapshot` could have
    # written: a non-finite number (1e400 parses to Infinity) or nesting
    # deeper than snapshot's limit of 100.
    def self.canonical_baseline(job)
      ::JSON.generate(job)
      Canonical.generate(job)
    end

    private

    # +current_job+ is already normalized (Snapshotter#build_document).
    def compare(name, current_job)
      path = File.join(@fixtures_dir, "#{name}.json")
      stat = begin
        File.lstat(path)
      rescue Errno::ENOENT
        return Entry.new(name, path, :missing, nil)
      rescue SystemCallError => e
        # For example an unsearchable fixture directory: not "never generated".
        return invalid(name, path, "cannot access file: #{e.message}")
      end
      # From lstat, so a symlink is never followed, whatever it points to.
      return invalid(name, path, "symbolic link (not followed)") if stat.symlink?
      return invalid(name, path, "not a regular file") unless stat.file?

      # Opened without following symlinks or blocking, and read only after the
      # open file is confirmed to be the one lstat saw.
      read = SecureFixtureReader.read(path, stat)
      return invalid(name, path, read.reason) if read.reason

      fixture = begin
        Fixture.parse_content(path, read.content)
      rescue SystemStackError => e
        # Some json versions parse recursively; nesting deep enough to
        # exhaust the stack must not abort the other fixtures.
        return invalid(name, path, "job cannot be canonicalized: #{e.message}")
      end
      return invalid(name, path, fixture.reason) if fixture.is_a?(Fixture::Invalid)

      baseline = begin
        self.class.canonical_baseline(fixture.job)
      rescue ::JSON::JSONError, ArgumentError, EncodingError, SystemStackError => e
        return invalid(name, path, "job cannot be canonicalized: #{e.message}")
      end
      status = baseline == Canonical.generate(current_job) ? :identical : :different
      Entry.new(name, path, status, nil)
    end

    def invalid(name, path, reason)
      Entry.new(name, path, :invalid, reason)
    end
  end
end
