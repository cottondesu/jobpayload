# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/in_process_app"

class SnapshotterTest < Minitest::Test
  def registry(cases)
    JobPayload::CaseRegistry.new.tap do |registry|
      cases.each { |name, block| registry.add(name, "test", &block) }
    end
  end

  def snapshot(dir, cases, update = false)
    JobPayload::Snapshotter.new(registry: registry(cases), output_dir: dir, update: update).call
  end

  def test_volatile_metadata_is_normalized_and_custom_keys_are_kept
    job = InProcess::StampedJob.new(1).set(wait_until: Time.now + 60, queue: "low", priority: 3)
    job.stamp = "tenant-42"
    job.executions = 4
    job.exception_executions = { "[RuntimeError]" => 1 }
    job.provider_job_id = "provider-123"
    data = JobPayload::Snapshotter.normalize(job.serialize)

    assert_equal "00000000-0000-0000-0000-000000000000", data["job_id"]
    assert_nil data["provider_job_id"]
    assert_equal "2000-01-01T00:00:00.000000000Z", data["enqueued_at"]
    assert_equal "2000-01-01T00:00:00.000000000Z", data["scheduled_at"]
    assert_equal 0, data["executions"]
    assert_equal({}, data["exception_executions"])
    assert_equal "tenant-42", data["stamp"]
    assert_equal "low", data["queue_name"]
    assert_equal 3, data["priority"]
    assert_equal "InProcess::StampedJob", data["job_class"]
    assert_equal [1], data["arguments"]
  end

  def test_nil_scheduled_at_stays_nil
    assert_nil JobPayload::Snapshotter.normalize(InProcess::PlotJob.new.serialize)["scheduled_at"]
  end

  def test_document_shape
    Dir.mktmpdir do |dir|
      snapshot(dir, "plot-v1" => -> { InProcess::PlotJob.new(InProcess::Point.new(1, 2)) })
      document = JSON.parse(File.read(File.join(dir, "plot-v1.json")))

      assert_equal 1, document["jobpayload_schema"]
      assert_equal "plot-v1", document["name"]
      assert_equal RUBY_VERSION, document.dig("source", "ruby_version")
      assert_equal Gem.loaded_specs["activejob"].version.to_s, document.dig("source", "active_job_version")
      assert_equal JobPayload::VERSION, document.dig("source", "jobpayload_version")
      assert document["source"].key?("rails_version")
      assert_equal [{ "_aj_serialized" => "InProcess::PointSerializer", "x" => 1, "y" => 2 }],
        document.dig("job", "arguments")
    end
  end

  def test_two_snapshots_are_byte_for_byte_identical
    cases = {
      "plot-v1" => -> { InProcess::PlotJob.new({ "z" => 1, "a" => [InProcess::Point.new(1, 2)] }, :sym) },
      "stamped-v1" => -> { InProcess::StampedJob.new.tap { |j| j.stamp = "s" } }
    }
    Dir.mktmpdir do |a|
      Dir.mktmpdir do |b|
        snapshot(a, cases)
        sleep 0.01
        snapshot(b, cases.to_a.reverse.to_h)

        assert_equal Dir.children(a).sort, Dir.children(b).sort
        Dir.children(a).each do |file|
          assert_equal File.binread(File.join(a, file)), File.binread(File.join(b, file)), file
        end
      end
    end
  end

  def test_existing_fixtures_are_not_overwritten_without_update
    Dir.mktmpdir do |dir|
      entries = snapshot(dir, "plot-v1" => -> { InProcess::PlotJob.new(1) })
      assert_equal [:created], entries.map(&:status)

      assert_equal [:identical], snapshot(dir, "plot-v1" => -> { InProcess::PlotJob.new(1) }).map(&:status)

      path = File.join(dir, "plot-v1.json")
      before = File.binread(path)
      assert_equal [:skipped], snapshot(dir, "plot-v1" => -> { InProcess::PlotJob.new(2) }).map(&:status)
      assert_equal before, File.binread(path)

      assert_equal [:updated], snapshot(dir, { "plot-v1" => -> { InProcess::PlotJob.new(2) } }, true).map(&:status)
      assert_equal [2], JSON.parse(File.binread(path)).dig("job", "arguments")
    end
  end

  def test_case_must_return_an_active_job_instance
    Dir.mktmpdir do |dir|
      error = assert_raises(JobPayload::ConfigurationError) { snapshot(dir, "bad-v1" => -> { "not a job" }) }
      assert_match(/must return an ActiveJob::Base instance, got String/, error.message)
    end
  end

  def test_serialization_errors_are_reported_against_the_case
    Dir.mktmpdir do |dir|
      error = assert_raises(JobPayload::ConfigurationError) { snapshot(dir, { "obj-v1" => -> { InProcess::PlotJob.new(Object.new) } }) }
      assert_match(/fixture "obj-v1" \(test\) raised ActiveJob::SerializationError/, error.message)
    end
  end

  def test_a_failing_case_writes_nothing
    Dir.mktmpdir do |dir|
      cases = { "a-v1" => -> { InProcess::PlotJob.new(1) }, "b-v1" => -> { raise "boom" } }
      error = assert_raises(JobPayload::ConfigurationError) { snapshot(dir, cases) }
      assert_match(/"b-v1".*raised RuntimeError: boom/, error.message)
      assert_empty Dir.children(dir)
    end
  end
end
