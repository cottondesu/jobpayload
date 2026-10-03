# frozen_string_literal: true

require_relative "test_helper"

class FormatterTest < Minitest::Test
  FixtureResult = JobPayload::Result::FixtureResult

  def finding(code, fixture, path: "arguments[0]", job_class: "BillingJob")
    JobPayload::Finding.new(
      code: code, fixture: fixture, job_class: job_class, argument_path: path,
      message: "Old payload cannot be deserialized by the current application.",
      exception_class: "ActiveJob::DeserializationError",
      exception_message: "Error while trying to deserialize arguments: Serializer MoneySerializer is not known",
      cause_chain: [
        { "class" => "ActiveJob::DeserializationError",
          "message" => "Error while trying to deserialize arguments: Serializer MoneySerializer is not known" },
        { "class" => "ArgumentError", "message" => "Serializer MoneySerializer is not known" }
      ],
      backtraces: [["a.rb:1"], ["b.rb:2"]]
    )
  end

  def result(*fixture_results)
    JobPayload::Result.new(fixture_results)
  end

  def test_all_pass_text
    r = result(FixtureResult.new("billing-money-v1", "x", []), FixtureResult.new("invoice-period-v1", "y", []))
    expected = <<~TEXT
      PASS billing-money-v1
      PASS invoice-period-v1

      2 fixtures checked
      2 compatible
      0 incompatible
      0 inconclusive
    TEXT
    assert_equal expected, JobPayload::Formatter::Text.call(r)
    assert_equal 0, r.exit_code
  end

  def test_breaking_text
    r = result(FixtureResult.new("billing-money-v1", "x", [finding("AJP201", "billing-money-v1")]))
    expected = <<~TEXT
      AJP201 breaking billing-money-v1

      Job:
        BillingJob

      Argument:
        arguments[0]

      Old payload cannot be deserialized by the current application.

      Cause:
        ArgumentError: Serializer MoneySerializer is not known

      1 fixtures checked
      0 compatible
      1 incompatible
      0 inconclusive
    TEXT
    assert_equal expected, JobPayload::Formatter::Text.call(r)
    assert_equal 1, r.exit_code
  end

  def test_inconclusive_text_and_exit_codes
    f = finding("AJP202", "notify-user-v1", job_class: "NotifyUserJob")
    f.message = "GlobalID target record was not found in the current test environment."
    r = result(FixtureResult.new("notify-user-v1", "x", [f]))
    text = JobPayload::Formatter::Text.call(r)

    assert_includes text, "AJP202 inconclusive notify-user-v1\n\nJob:\n  NotifyUserJob\n"
    assert_includes text, "GlobalID target record was not found in the current test environment.\n\n" \
                          "This does not by itself prove a payload compatibility break.\n"
    assert_equal 0, r.exit_code
    assert_equal 1, r.exit_code(fail_on_inconclusive: true)
    assert_equal "pass", r.status
    assert_equal "fail", r.status(fail_on_inconclusive: true)
  end

  def test_debug_text_includes_backtraces_only_when_requested
    r = result(FixtureResult.new("a-v1", "x", [finding("AJP201", "a-v1")]))
    refute_includes JobPayload::Formatter::Text.call(r), "a.rb:1"
    debug = JobPayload::Formatter::Text.call(r, debug: true)
    assert_includes debug, "Cause chain:\n  1. ActiveJob::DeserializationError"
    assert_includes debug, "       a.rb:1\n"
    assert_includes debug, "       b.rb:2\n"
  end

  def test_tool_errors_take_priority_in_exit_code
    fatal = finding("AJP001", "broken-v1", path: nil, job_class: nil)
    r = result(
      FixtureResult.new("a-v1", "a", [finding("AJP201", "a-v1")]),
      FixtureResult.new("broken-v1", "b", [fatal])
    )
    assert_equal 2, r.exit_code
    assert_equal "tool_error", r.status
    assert_equal({ "fixtures" => 2, "compatible" => 0, "incompatible" => 1, "inconclusive" => 0, "tool_errors" => 1 }, r.summary)
    assert_includes JobPayload::Formatter::Text.call(r), "AJP001 fatal broken-v1\n\nOld payload"
  end

  def test_json_schema_v1
    r = result(
      FixtureResult.new("b-v1", "b", [finding("AJP202", "b-v1"), finding("AJP201", "b-v1", path: "arguments[1]")]),
      FixtureResult.new("a-v1", "a", [finding("AJP201", "a-v1", path: "arguments[1]"), finding("AJP201", "a-v1")]),
      FixtureResult.new("c-v1", "c", [])
    )
    json = JobPayload::Formatter::JSON.call(r)
    document = JSON.parse(json)

    assert_equal %w[schema_version tool_version status summary fixtures findings], document.keys
    assert_equal 1, document["schema_version"]
    assert_equal JobPayload::VERSION, document["tool_version"]
    assert_equal "fail", document["status"]
    assert_equal({ "fixtures" => 3, "compatible" => 1, "incompatible" => 2, "inconclusive" => 0, "tool_errors" => 0 },
      document["summary"])
    assert_equal [%w[a-v1 AJP201 arguments[0]], %w[a-v1 AJP201 arguments[1]], %w[b-v1 AJP201 arguments[1]],
      %w[b-v1 AJP202 arguments[0]]],
      document["findings"].map { |f| f.values_at("fixture", "code", "argument_path") }
    assert_equal %w[code name severity fixture job_class argument_path message exception_class exception_message cause_chain],
      document["findings"].first.keys
    assert_equal "error", document["findings"].first["severity"]
    assert_equal "warning", document["findings"].last["severity"]
    assert_equal [{ "name" => "b-v1", "status" => "fail" }, { "name" => "a-v1", "status" => "fail" },
      { "name" => "c-v1", "status" => "pass" }], document["fixtures"]
    refute_includes json, "a.rb:1", "backtraces must never appear in JSON output"
    assert json.end_with?("}\n")
    assert_equal json, JobPayload::Formatter::JSON.call(r)
  end

  def test_json_status_vocabulary
    statuses = lambda do |*codes|
      r = result(*codes.each_with_index.map { |code, i| FixtureResult.new("f#{i}-v1", "f#{i}", code ? [finding(code, "f#{i}-v1")] : []) })
      document = JSON.parse(JobPayload::Formatter::JSON.call(r))
      [document["status"], document["fixtures"].map { |f| f["status"] }, document["summary"]]
    end

    assert_equal ["pass", %w[pass inconclusive], { "fixtures" => 2, "compatible" => 1, "incompatible" => 0,
      "inconclusive" => 1, "tool_errors" => 0 }], statuses.call(nil, "AJP202")
    assert_equal ["fail", %w[fail inconclusive], { "fixtures" => 2, "compatible" => 0, "incompatible" => 1,
      "inconclusive" => 1, "tool_errors" => 0 }], statuses.call("AJP201", "AJP202")
    assert_equal ["tool_error", %w[tool_error fail], { "fixtures" => 2, "compatible" => 0, "incompatible" => 1,
      "inconclusive" => 0, "tool_errors" => 1 }], statuses.call("AJP900", "AJP101")
    assert_equal %w[error warning fatal fatal], %w[AJP201 AJP202 AJP900 AJP001].map { |c| finding(c, "x-v1").severity }
  end

  def test_unknown_format
    assert_raises(JobPayload::UsageError) { JobPayload::Formatter.for("xml") }
  end
end
