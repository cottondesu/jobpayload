# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/in_process_app"

class CheckerTest < Minitest::Test
  def setup
    InProcess::PERFORMED.clear
  end

  def fixture(job_class: "InProcess::PlotJob", arguments: [], **extra)
    job = {
      "job_class" => job_class, "job_id" => "00000000-0000-0000-0000-000000000000",
      "provider_job_id" => nil, "queue_name" => "default", "priority" => nil,
      "arguments" => arguments, "executions" => 0, "exception_executions" => {},
      "locale" => "en", "timezone" => "UTC", "enqueued_at" => "2000-01-01T00:00:00.000000000Z",
      "scheduled_at" => nil
    }.merge(extra.transform_keys(&:to_s))
    JobPayload::Fixture.new(name: "case-v1", path: "case-v1.json", job: job, source: {})
  end

  def check(fixture)
    JobPayload::Checker.new.check(fixture)
  end

  def point(x = 1, y = 2)
    { "_aj_serialized" => "InProcess::PointSerializer", "x" => x, "y" => y }
  end

  def test_compatible_payload_has_no_findings_and_never_performs
    result = check(fixture(arguments: [point, "s", 1, [point], { "p" => point, "_aj_symbol_keys" => [] }]))

    assert_empty result.findings
    assert_equal :pass, result.status
    assert_empty InProcess::PERFORMED
  end

  def test_perform_is_not_called_for_jobs_whose_perform_has_side_effects
    check(fixture(job_class: "InProcess::StampedJob", stamp: "s1"))
    assert_empty InProcess::PERFORMED
  end

  def test_unknown_job_class_is_ajp101
    finding = check(fixture(job_class: "InProcess::RemovedJob")).findings.sole

    assert_equal "AJP101", finding.code
    assert_equal :breaking, finding.kind
    assert_equal "InProcess::RemovedJob", finding.job_class
    assert_match(/uninitialized constant InProcess::RemovedJob/, finding.message)
    assert_nil finding.argument_path
  end

  def test_non_job_constant_is_ajp101
    finding = check(fixture(job_class: "InProcess::NotAJob")).findings.sole
    assert_equal "AJP101", finding.code
    assert_match(/not an ActiveJob::Base subclass/, finding.message)
  end

  def test_arguments_are_still_checked_when_job_class_is_unknown
    codes = check(fixture(job_class: "InProcess::RemovedJob", arguments: [point.except("x")])).findings.map(&:code)
    assert_equal %w[AJP101 AJP201], codes
  end

  def test_custom_job_deserialize_failure_is_ajp102
    finding = check(fixture(job_class: "InProcess::StampedJob")).findings.sole

    assert_equal "AJP102", finding.code
    assert_equal "KeyError", finding.exception_class
    assert_equal [{ "class" => "KeyError", "message" => 'key not found: "stamp"' }], finding.cause_chain
  end

  def test_unknown_serializer_is_ajp201_with_cause_chain
    payload = { "_aj_serialized" => "InProcess::LegacyPointSerializer", "x" => 1 }
    finding = check(fixture(arguments: ["ok", payload])).findings.sole

    assert_equal "AJP201", finding.code
    assert_equal "arguments[1]", finding.argument_path
    assert_equal "ActiveJob::DeserializationError", finding.exception_class
    assert_equal %w[ActiveJob::DeserializationError ArgumentError], finding.cause_chain.map { |c| c["class"] }
    assert_equal "Serializer InProcess::LegacyPointSerializer is not known", finding.cause_chain.last["message"]
  end

  def test_changed_serializer_contract_is_ajp201
    finding = check(fixture(arguments: [point.except("y")])).findings.sole
    assert_equal "AJP201", finding.code
    assert_equal "KeyError", finding.cause_chain.last["class"]
  end

  def test_argument_path_narrows_into_plain_arrays_and_hashes
    bad = point.except("y")
    finding = check(fixture(arguments: [1, [point, { "ok" => 1, "bad" => bad, "_aj_symbol_keys" => ["ok"] }]])).findings.sole
    assert_equal 'arguments[1][1]["bad"]', finding.argument_path
  end

  def missing_record(id = 7)
    { "_aj_serialized" => "InProcess::MissingRecordSerializer", "id" => id }
  end

  def missing_gid(id = 7)
    { "_aj_globalid" => "gid://inprocess/InProcess::Account/#{id}" }
  end

  def test_missing_global_id_record_alone_is_inconclusive
    finding = check(fixture(arguments: [missing_gid])).findings.sole

    assert_equal "AJP202", finding.code
    assert_equal :inconclusive, finding.kind
    assert_equal "arguments[0]", finding.argument_path
    assert_equal "ActiveRecord::RecordNotFound", finding.cause_chain.last["class"]
    assert_equal :inconclusive, check(fixture(arguments: [missing_gid])).status
  end

  def test_nested_missing_global_id_record_is_inconclusive
    finding = check(fixture(arguments: [{ "user" => missing_gid, "_aj_symbol_keys" => ["user"] }])).findings.sole
    assert_equal ['arguments[0]["user"]', "AJP202"], [finding.argument_path, finding.code]
  end

  # Release blocker: a custom serializer raising RecordNotFound (for example
  # find_by! on a renamed key) is a broken payload, never inconclusive.
  def test_record_not_found_from_a_custom_serializer_is_ajp201
    result = check(fixture(arguments: [missing_record]))

    assert_equal [%w[arguments[0] AJP201]], result.findings.map { |f| [f.argument_path, f.code] }
    assert_equal "ActiveRecord::RecordNotFound", result.findings.sole.cause_chain.last["class"]
    assert_equal :fail, result.status
  end

  def test_global_id_key_inside_a_larger_hash_is_not_a_global_id
    refute JobPayload::Checker::ArgumentLocator.global_id?(missing_gid.merge("x" => 1))
    refute JobPayload::Checker::ArgumentLocator.global_id?(missing_record)
    refute JobPayload::Checker::ArgumentLocator.global_id?(nil)
    assert JobPayload::Checker::ArgumentLocator.global_id?(missing_gid)
  end

  def test_missing_global_id_and_broken_serializer_raising_record_not_found
    result = check(fixture(arguments: [missing_gid, missing_record]))

    assert_equal [%w[arguments[0] AJP202], %w[arguments[1] AJP201]], result.findings.map { |f| [f.argument_path, f.code] }
    assert_equal :fail, result.status
  end

  def test_missing_record_does_not_mask_a_later_breaking_argument
    broken = { "_aj_serialized" => "InProcess::LegacyPointSerializer" }
    result = check(fixture(arguments: [missing_gid, "ok", broken, { "nested" => [missing_gid(8), point.except("y")] }]))

    assert_equal [%w[arguments[0] AJP202], %w[arguments[2] AJP201], ['arguments[3]["nested"][0]', "AJP202"],
      ['arguments[3]["nested"][1]', "AJP201"]],
      result.findings.map { |f| [f.argument_path, f.code] }
    assert_equal :fail, result.status
    assert_equal "Couldn't find InProcess::Account with 'id'=7", result.findings.first.cause_chain.last["message"]
  end

  # Pre-existing gap: a container broken on its own (here, malformed
  # "_aj_symbol_keys") must not be hidden by a missing GlobalID inside it.
  def test_missing_global_id_does_not_hide_a_broken_container
    result = check(fixture(arguments: [{ "_aj_symbol_keys" => 5, "user" => missing_gid }]))

    assert_equal [%w[arguments[0] AJP201], ['arguments[0]["user"]', "AJP202"]],
      result.findings.map { |f| [f.argument_path, f.code] }.sort
    assert_equal "NoMethodError", result.findings.find { |f| f.code == "AJP201" }.cause_chain.last["class"]
    assert_equal :fail, result.status
  end

  def test_container_failing_only_through_its_children_is_not_reported_itself
    result = check(fixture(arguments: [[missing_gid, { "_aj_symbol_keys" => ["k"], "k" => missing_record }]]))

    assert_equal [%w[arguments[0][0] AJP202], ['arguments[0][1]["k"]', "AJP201"]],
      result.findings.map { |f| [f.argument_path, f.code] }
  end

  # The full call is the source of truth: a breaking failure there is never
  # downgraded to the inconclusive per-argument findings.
  def test_breaking_failure_of_the_full_call_is_kept_when_retries_find_only_missing_records
    InProcess::FlakySerializer.reset!
    flaky = { "_aj_serialized" => "InProcess::FlakySerializer", "value" => 1 }
    result = check(fixture(arguments: [flaky, missing_gid]))

    assert_equal [%w[arguments AJP201], %w[arguments[1] AJP202]], result.findings.map { |f| [f.argument_path, f.code] }.sort
    assert_equal :fail, result.status
  end

  def test_record_missing_in_the_full_call_is_explained_by_the_global_id_finding
    InProcess::FlakySerializer.reset!
    InProcess::FlakySerializer.calls = 1 # the flaky argument never fails
    flaky = { "_aj_serialized" => "InProcess::FlakySerializer", "value" => 1 }
    assert_equal [%w[arguments[1] AJP202]],
      check(fixture(arguments: [flaky, missing_gid])).findings.map { |f| [f.argument_path, f.code] }
  end

  # No GlobalID leaf to attribute the record-missing error to: breaking.
  def test_record_missing_in_the_full_call_without_a_failing_argument_is_breaking
    InProcess::FlakySerializer.reset!(ActiveRecord::RecordNotFound)
    flaky = { "_aj_serialized" => "InProcess::FlakySerializer", "value" => 1 }
    finding = check(fixture(arguments: [flaky])).findings.sole

    assert_equal %w[arguments AJP201], [finding.argument_path, finding.code]
    assert_equal "ActiveRecord::RecordNotFound", finding.cause_chain.last["class"]
  end

  # Only GlobalID arguments can be inconclusive.
  def test_record_not_found_in_a_job_level_deserialize_is_ajp102
    finding = check(fixture(job_class: "InProcess::LookupJob", account_id: 3)).findings.sole

    assert_equal ["AJP102", :breaking], [finding.code, finding.kind]
    assert_equal "ActiveRecord::RecordNotFound", finding.cause_chain.last["class"]
  end

  # Active Job only reserves its own metadata keys; "_aj_custom" is a user key.
  def test_missing_global_id_under_a_user_key_starting_with_aj_is_inconclusive
    finding = check(fixture(arguments: [{ "_aj_custom" => missing_gid, "_aj_symbol_keys" => [] }])).findings.sole
    assert_equal ['arguments[0]["_aj_custom"]', "AJP202"], [finding.argument_path, finding.code]
  end

  def test_broken_value_under_a_user_key_starting_with_aj_is_located
    finding = check(fixture(arguments: [{ "_aj_custom" => point.except("y"), "_aj_symbol_keys" => [] }])).findings.sole
    assert_equal ['arguments[0]["_aj_custom"]', "AJP201"], [finding.argument_path, finding.code]
  end

  # Exhausting the Ruby stack is a tool limitation (exit 2), never a
  # compatibility result (exit 1).
  def test_stack_exhaustion_is_a_tool_error_not_a_compatibility_failure
    deep = 30_000.times.reduce(1) { |inner, _| [inner] }
    result = check(fixture(arguments: [{ "_aj_serialized" => "InProcess::PointSerializer", "x" => deep, "y" => 2 }]))

    refute_empty result.findings
    assert(result.findings.all? { |f| f.code == "AJP900" && f.exception_class == "SystemStackError" },
      result.findings.map { |f| [f.code, f.exception_class] }.inspect)
    assert_equal :tool_error, result.status
  end

  def test_malformed_argument_representation_is_ajp201
    finding = check(fixture(arguments: [{ "_aj_serialized" => nil }])).findings.sole
    assert_equal "AJP201", finding.code
  end

  def test_each_phase_gets_its_own_copy
    args = [point]
    fx = fixture(job_class: "InProcess::MutatingJob", arguments: args)
    result = check(fx)

    assert_empty result.findings
    assert_equal [point], fx.job["arguments"], "fixture data must not be mutated"
  end

  def test_invalid_fixture_is_ajp001
    invalid = JobPayload::Fixture::Invalid.new("broken-v1", "broken-v1.json", "invalid JSON: unexpected token")
    finding = check(invalid).findings.sole

    assert_equal "AJP001", finding.code
    assert_equal :fatal, finding.kind
    assert_equal :tool_error, check(invalid).status
    assert_equal "Fixture is invalid: invalid JSON: unexpected token.", finding.message
  end

  def test_results_are_sorted_by_fixture_name
    fixtures = %w[c-v1 a-v1 b-v1].map do |name|
      JobPayload::Fixture.new(name: name, path: "#{name}.json", job: fixture.job, source: {})
    end
    assert_equal %w[a-v1 b-v1 c-v1], JobPayload::Checker.new.call(fixtures).fixture_results.map(&:name)
  end
end
