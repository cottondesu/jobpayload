# frozen_string_literal: true

require_relative "test_helper"

# Baseline fixtures written by the v1 dummy app are checked against later
# versions of the same app (test/apps/v2_compatible and test/apps/v2_breaking).
class IntegrationTest < Minitest::Test
  include JobPayloadTest
  parallelize_me!

  BUILTIN_TYPES = %w[
    nil string integer float true false symbol date time datetime bigdecimal array hash
    hash-symbol-keys hash-indifferent range duration time-with-zone module
  ].freeze

  def check(app, fixture_name, *extra, env: {})
    out, err, code = run_cli("check", "--boot", app_boot(app), "--fixtures", v1_fixture(fixture_name),
      "--format", "json", *extra, env: env)
    assert_empty err
    [JSON.parse(out), code]
  end

  def assert_finding(app, fixture_name, code:, exit_code:, argument_path: nil, cause: nil)
    document, status = check(app, fixture_name)
    assert_equal 1, document["findings"].size, document["findings"].inspect
    finding = document["findings"].first

    assert_equal exit_code, status
    assert_equal code, finding["code"]
    assert_equal fixture_name, finding["fixture"]
    if argument_path
      assert_equal argument_path, finding["argument_path"]
    else
      assert_nil finding["argument_path"]
    end
    assert_equal cause, finding["cause_chain"].last&.values_at("class", "message") if cause
    finding
  end

  def assert_pass(app, fixture_name)
    document, status = check(app, fixture_name)
    assert_equal [0, "pass", []], [status, document["status"], document["findings"]], fixture_name
  end

  # 1. built-in argument types round-trip
  def test_builtin_argument_payloads_pass
    Dir.mktmpdir do |dir|
      BUILTIN_TYPES.each { |type| FileUtils.cp(v1_fixture("builtin-#{type}-v1"), dir) }
      %w[v1 v2_compatible v2_breaking].each do |app|
        out, err, code = run_cli("check", "--boot", app_boot(app), "--fixtures", dir, "--format", "json")
        document = JSON.parse(out)

        assert_equal [0, "", "pass", []], [code, err, document["status"], document["findings"]], app
        assert_equal BUILTIN_TYPES.size, document["summary"]["compatible"]
      end
    end
  end

  def test_builtin_fixtures_hold_active_job_serialized_forms
    {
      "symbol" => [{ "_aj_serialized" => "ActiveJob::Serializers::SymbolSerializer", "value" => "ready" }],
      "range" => [{ "_aj_serialized" => "ActiveJob::Serializers::RangeSerializer", "begin" => 1, "end" => 10,
                    "exclude_end" => false }],
      "hash-symbol-keys" => [{ "_aj_symbol_keys" => %w[status count], "count" => 2, "status" => "active" }]
    }.each do |type, expected|
      arguments = JSON.parse(File.read(v1_fixture("builtin-#{type}-v1"))).dig("job", "arguments")
      assert_equal expected, arguments, type
    end
  end

  # 2. custom serializer old payload on compatible new code
  def test_custom_serializer_old_payload_passes_on_compatible_code
    assert_pass("v1", "billing-money-v1")
    assert_pass("v2_compatible", "billing-money-v1")
    assert_pass("v2_compatible", "tenant-v1")
    assert_pass("v2_compatible", "account-sync-v1")
  end

  # 3. serializer class removed
  def test_removed_serializer_is_ajp201
    finding = assert_finding("v2_breaking", "billing-legacy-money-v1", code: "AJP201", exit_code: 1,
      argument_path: "arguments[0]", cause: ["ArgumentError", "Serializer LegacyMoneySerializer is not known"])
    assert_equal "ActiveJob::DeserializationError", finding["exception_class"]
    assert_equal "error", finding["severity"]
  end

  # 4. serializer deserialize contract changed
  def test_changed_serializer_contract_is_ajp201
    assert_finding("v2_breaking", "billing-money-v1", code: "AJP201", exit_code: 1,
      argument_path: "arguments[0]", cause: ["KeyError", 'key not found: "value"'])
  end

  # 5. job class removed
  def test_removed_job_class_is_ajp101
    finding = assert_finding("v2_breaking", "legacy-billing-v1", code: "AJP101", exit_code: 1)
    assert_equal "LegacyBillingJob", finding["job_class"]
  end

  # 6. custom job serialized field removed/changed
  def test_custom_job_field_survives_snapshot_and_breaks_on_rename
    assert_equal 42, JSON.parse(File.read(v1_fixture("tenant-v1"))).dig("job", "tenant_id")
    assert_finding("v2_breaking", "tenant-v1", code: "AJP102", exit_code: 1,
      cause: ["KeyError", 'key not found: "organization_id"'])
  end

  # 7. GlobalID existing record
  def test_globalid_existing_record_passes
    assert_pass("v2_breaking", "notify-user-v1")
    assert_pass("v2_breaking", "notify-users-nested-v1")
  end

  # 8. GlobalID missing record
  def test_globalid_missing_record_is_inconclusive
    finding = assert_finding("v2_breaking", "notify-user-missing-v1", code: "AJP202", exit_code: 0,
      argument_path: "arguments[0]", cause: ["ActiveRecord::RecordNotFound", "Couldn't find User with 'id'=\"999\""])
    assert_equal "warning", finding["severity"]
    assert_equal({ "fixtures" => 1, "compatible" => 0, "incompatible" => 0, "inconclusive" => 1, "tool_errors" => 0 },
      check("v2_breaking", "notify-user-missing-v1").first["summary"])

    _document, status = check("v2_breaking", "notify-user-missing-v1", "--fail-on-inconclusive")
    assert_equal 1, status
  end

  def test_globalid_missing_record_nested_is_inconclusive
    assert_finding("v1", "notify-users-nested-missing-v1", code: "AJP202", exit_code: 0,
      argument_path: 'arguments[0]["batch"][1]')
  end

  OLD_USER_EMAIL = { "_aj_serialized" => "UserEmailSerializer", "email" => "old@example.com" }.freeze

  # Writes a fixture built from notify-user-missing-v1 with +arguments+ into
  # a temporary directory and checks it against +app+.
  def check_arguments(app, name, arguments, *extra)
    Dir.mktmpdir do |dir|
      document = JSON.parse(File.read(v1_fixture("notify-user-missing-v1")))
      document["name"] = name
      document["job"]["arguments"] = arguments
      File.write(File.join(dir, "#{name}.json"), JSON.generate(document))

      out, err, code = run_cli("check", "--boot", app_boot(app), "--fixtures", dir, "--format", "json", *extra)
      assert_empty err
      [JSON.parse(out), code]
    end
  end

  # Release blocker: RecordNotFound raised by a custom serializer (find_by! on
  # a renamed key) is a broken payload, not a missing GlobalID record.
  def test_record_not_found_from_custom_serializer_is_breaking_not_inconclusive
    document, code = check_arguments("v2_breaking", "user-email-v1", [OLD_USER_EMAIL])
    assert_equal 1, document["findings"].size
    finding = document["findings"].first

    assert_equal [1, "fail"], [code, document["status"]]
    assert_equal %w[AJP201 error arguments[0]], finding.values_at("code", "severity", "argument_path")
    assert_equal "ActiveRecord::RecordNotFound", finding["cause_chain"].last["class"]
    refute(document["findings"].any? { |f| f["code"] == "AJP202" })

    _document, code = check_arguments("v2_breaking", "user-email-v1", [OLD_USER_EMAIL], "--fail-on-inconclusive")
    assert_equal 1, code

    seeded = OLD_USER_EMAIL.merge("email" => "seeded@example.test")
    assert_equal [[], 0], check_arguments("v1", "user-email-v1", [seeded]).then { |d, c| [d["findings"], c] }
  end

  def test_missing_global_id_and_broken_custom_serializer_in_one_job
    missing = JSON.parse(File.read(v1_fixture("notify-user-missing-v1"))).dig("job", "arguments", 0)
    document, code = check_arguments("v2_breaking", "mixed-email-v1", [missing, OLD_USER_EMAIL])

    assert_equal [1, "fail"], [code, document["status"]]
    assert_equal [%w[AJP201 error arguments[1]], %w[AJP202 warning arguments[0]]],
      document["findings"].map { |f| f.values_at("code", "severity", "argument_path") }
    assert_equal [{ "name" => "mixed-email-v1", "status" => "fail" }], document["fixtures"]
  end

  def test_missing_record_does_not_hide_a_breaking_argument
    Dir.mktmpdir do |dir|
      document = JSON.parse(File.read(v1_fixture("notify-user-missing-v1")))
      document["name"] = "mixed-v1"
      document["job"]["arguments"] << JSON.parse(File.read(v1_fixture("billing-legacy-money-v1"))).dig("job", "arguments", 0)
      File.write(File.join(dir, "mixed-v1.json"), JSON.generate(document))

      out, err, code = run_cli("check", "--boot", app_boot("v2_breaking"), "--fixtures", dir, "--format", "json")
      assert_equal [1, ""], [code, err]
      assert_equal [%w[AJP201 arguments[1]], %w[AJP202 arguments[0]]],
        JSON.parse(out)["findings"].map { |f| f.values_at("code", "argument_path") }
    end
  end

  def test_globalid_missing_model_class_is_breaking
    assert_finding("v2_breaking", "account-sync-v1", code: "AJP201", exit_code: 1,
      argument_path: "arguments[0]", cause: ["NameError", "uninitialized constant Account"])
  end

  # 9. perform is never called
  def test_job_whose_perform_raises_still_passes
    Dir.mktmpdir do |dir|
      marker = File.join(dir, "performed")
      %w[exploding-v1 scheduled-v1].each do |name|
        document, status = check("v2_breaking", name, env: { "JOBPAYLOAD_PERFORM_MARKER" => marker })
        assert_equal [0, "pass"], [status, document["status"]]
      end
      refute File.exist?(marker), "perform was called"
    end
  end

  # 10. JSON output repeated twice is identical
  def test_full_v2_breaking_report_is_deterministic
    args = ["check", "--boot", app_boot("v2_breaking"), "--fixtures", v1_fixtures, "--format", "json"]
    first, err, code = run_cli(*args)
    second, = run_cli(*args)

    assert_equal 1, code, err
    assert_equal first, second
    document = JSON.parse(first)
    assert_equal({ "fixtures" => 30, "compatible" => 23, "incompatible" => 5, "inconclusive" => 2, "tool_errors" => 0 },
      document["summary"])
    assert_equal [
      %w[account-sync-v1 AJP201], %w[billing-legacy-money-v1 AJP201], %w[billing-money-v1 AJP201],
      %w[legacy-billing-v1 AJP101], %w[notify-user-missing-v1 AJP202], %w[notify-users-nested-missing-v1 AJP202],
      %w[tenant-v1 AJP102]
    ], document["findings"].map { |f| f.values_at("fixture", "code") }

    text_args = args[0..-3]
    assert_equal run_cli(*text_args).first, run_cli(*text_args).first
  end
end
