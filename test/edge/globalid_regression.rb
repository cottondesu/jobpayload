# frozen_string_literal: true

# Rails edge regression for GlobalID classification. Not part of `rake test`
# (the file name does not match *_test.rb): run it against Rails main with
#
#   BUNDLE_GEMFILE=gemfiles/rails_edge.gemfile bundle exec rake test:rails_edge
#
# Rails main raises ActiveJob::DeserializationError::RecordNotFound (caused by
# GlobalID::Locator::RecordNotFound) for a missing GlobalID record, and wraps
# any other locator failure in GlobalID::Locator::RecordUnavailable. These
# tests reproduce both with a real Active Record model and check that
# jobpayload's classification is unchanged. A missing edge contract is a
# failure, never a skip.
require_relative "../test_helper"
require_relative "../support/in_process_app"
require "bundler"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Migration.verbose = false
ActiveRecord::Schema.define do
  create_table :edge_users, force: true do |t|
    t.string :email, null: false
  end
end

module Edge
  class User < ActiveRecord::Base
    include GlobalID::Identification

    self.table_name = "edge_users"
  end

  # Its table does not exist: the test database does not match the application.
  class Unmigrated < ActiveRecord::Base
    include GlobalID::Identification

    self.table_name = "edge_unmigrated"
  end
end

class RailsEdgeGlobalIDRegression < Minitest::Test
  COMPONENTS = %w[activejob activerecord activemodel activesupport].freeze

  def setup
    Edge::User.delete_all
    @user = Edge::User.create!(email: "kept@example.test")
    ghost = Edge::User.create!(email: "ghost@example.test")
    @missing_gid = ghost.to_global_id.to_s
    ghost.destroy!
    InProcess::PERFORMED.clear
  end

  def teardown
    assert_empty InProcess::PERFORMED, "jobs are never performed"
  end

  def gid(value) = { "_aj_globalid" => value }

  def missing = gid(@missing_gid)

  def broken_serializer = { "_aj_serialized" => "InProcess::PointSerializer", "x" => 1 }

  def record_not_found_serializer = { "_aj_serialized" => "InProcess::MissingRecordSerializer", "id" => 1 }

  def fixture(arguments, job_class: "InProcess::PlotJob")
    job = ActiveJob::Base.new.serialize.merge("job_class" => job_class, "arguments" => arguments)
    JobPayload::Fixture.new(name: "edge-v1", path: "edge-v1.json", job: job, source: {})
  end

  def check(arguments, **options)
    JobPayload::Result.new([JobPayload::Checker.new.check(fixture(arguments, **options))])
  end

  # [argument_path, code] of every finding, by argument path.
  def codes(result) = result.findings.map { |f| [f.argument_path, f.code] }.sort_by { |path, _| path.to_s }

  def deserialize_error(arguments)
    ActiveJob::Arguments.deserialize(arguments)
    flunk "expected ActiveJob::Arguments.deserialize(#{arguments.inspect}) to fail"
  rescue ActiveJob::DeserializationError => e
    e
  end

  def chain_classes(error) = JobPayload::ExceptionClassifier.cause_chain(error).map { |e| e.class.name }

  # Rails main, every component from the same Git revision.
  def test_rails_main_is_loaded_from_one_git_revision
    specs = COMPONENTS.to_h { |name| [name, Gem.loaded_specs.fetch(name)] }
    diagnostics = specs.map { |name, spec| "#{name} #{spec.version} #{spec.source.class}" }.join(", ")
    specs.each_value do |spec|
      assert_kind_of Bundler::Source::Git, spec.source, "not Rails main from Git: #{diagnostics}"
      assert spec.version.prerelease?, "not a Rails development version: #{diagnostics}"
    end
    assert_equal 1, specs.values.map { |spec| spec.source.revision }.uniq.size, diagnostics
    assert_equal ActiveJob.gem_version, ActiveRecord.gem_version
  end

  # E8: the real exception shape of Rails main.
  def test_edge_record_not_found_contract
    assert defined?(ActiveJob::DeserializationError::RecordNotFound),
      "Rails edge contract unavailable: ActiveJob::DeserializationError::RecordNotFound is not defined " \
      "(activejob #{ActiveJob.gem_version}); re-check how Rails main reports missing GlobalID records"
    assert_equal ActiveJob::DeserializationError, ActiveJob::DeserializationError::RecordNotFound.superclass

    error = deserialize_error([missing])
    assert_instance_of ActiveJob::DeserializationError::RecordNotFound, error
    assert_equal %w[ActiveJob::DeserializationError::RecordNotFound GlobalID::Locator::RecordNotFound], chain_classes(error)
    assert_equal :record_missing, JobPayload::ExceptionClassifier.call(error)
  end

  # E1
  def test_direct_missing_global_id_is_ajp202
    result = check([missing])
    finding = result.findings.sole

    assert_equal ["arguments[0]", "AJP202", :inconclusive], [finding.argument_path, finding.code, finding.kind]
    assert_equal %w[ActiveJob::DeserializationError::RecordNotFound GlobalID::Locator::RecordNotFound],
      finding.cause_chain.map { |c| c["class"] }
    assert_equal :inconclusive, result.fixture_results.sole.status
    assert_equal [0, 1], [result.exit_code, result.exit_code(fail_on_inconclusive: true)]
  end

  def test_existing_global_id_passes
    assert_empty check([gid(@user.to_global_id.to_s), [gid(@user.to_global_id.to_s)]]).findings
  end

  # E2
  def test_nested_missing_global_id_is_ajp202
    arguments = ActiveJob::Arguments.serialize([{ "users" => [@user, @user] }])
    arguments[0]["users"][1] = missing
    result = check(arguments)

    assert_equal [['arguments[0]["users"][1]', "AJP202"]], codes(result)
    assert_equal 0, result.exit_code
  end

  # E3
  def test_record_not_found_from_a_custom_serializer_is_ajp201
    result = check([record_not_found_serializer])

    assert_equal [%w[arguments[0] AJP201]], codes(result)
    assert_equal :breaking, result.findings.sole.kind
    assert_equal "ActiveRecord::RecordNotFound", result.findings.sole.cause_chain.last["class"]
    assert_equal 1, result.exit_code
  end

  # E4
  def test_missing_global_id_does_not_hide_a_broken_serializer
    result = check([missing, record_not_found_serializer])

    assert_equal [%w[arguments[0] AJP202], %w[arguments[1] AJP201]], codes(result)
    assert_equal ["fail", 1], [result.status, result.exit_code]
  end

  # E5
  def test_record_not_found_in_a_job_level_deserialize_is_ajp102
    result = check([], job_class: "InProcess::LookupJob")

    assert_equal [[nil, "AJP102"]], codes(result)
    assert_equal :breaking, result.findings.sole.kind
    assert_equal 1, result.exit_code
  end

  # E6: Rails main wraps the database error in RecordUnavailable; the cause
  # chain still carries it.
  def test_database_error_while_locating_a_record_is_ajp900
    error = deserialize_error([gid("gid://#{GlobalID.app}/Edge::Unmigrated/1")])
    classes = chain_classes(error)
    assert_equal "ActiveJob::DeserializationError", classes.first
    assert_includes classes, "GlobalID::Locator::RecordUnavailable"
    assert_includes classes, "ActiveRecord::StatementInvalid"

    result = check([gid("gid://#{GlobalID.app}/Edge::Unmigrated/1"), broken_serializer, missing])
    assert_equal [%w[arguments[0] AJP900], %w[arguments[1] AJP201], %w[arguments[2] AJP202]], codes(result)
    assert_equal ["tool_error", 2], [result.status, result.exit_code]
    assert_equal 2, result.exit_code(fail_on_inconclusive: true)

    # Also across fixtures: an environment failure in one outranks a
    # compatibility failure in another.
    checker = JobPayload::Checker.new
    across = JobPayload::Result.new([checker.check(fixture([broken_serializer])),
      checker.check(fixture([gid("gid://#{GlobalID.app}/Edge::Unmigrated/1")]))])
    assert_equal ["tool_error", 2], [across.status, across.exit_code]
  end

  # E7
  def test_failures_that_are_not_a_missing_record_are_ajp201
    [broken_serializer, { "_aj_serialized" => "Edge::NoSuchSerializer" }, gid("gid://#{GlobalID.app}/Edge::NoSuchModel/1")]
      .each do |argument|
        result = check([argument])
        assert_equal [%w[arguments[0] AJP201]], codes(result), argument.inspect
        assert_equal 1, result.exit_code
      end
  end

  # A GlobalID lookup that fails for a reason other than a missing record or
  # the environment (here: the model class is gone) reaches jobpayload as
  # RecordUnavailable on Rails main, and is breaking.
  def test_record_unavailable_without_a_record_missing_or_environment_cause_is_ajp201
    argument = gid("gid://#{GlobalID.app}/Edge::NoSuchModel/1")
    error = deserialize_error([argument])
    classes = chain_classes(error)
    assert_equal %w[ActiveJob::DeserializationError GlobalID::Locator::RecordUnavailable], classes.first(2)
    assert_includes classes, "NameError"
    assert_equal :failure, JobPayload::ExceptionClassifier.call(error)

    assert_equal [%w[arguments[0] AJP201]], codes(check([argument]))
  end

  # The real executable on the dummy application, snapshot and check both on
  # Rails main.
  def test_cli_on_the_dummy_application
    fixtures = JobPayloadTest.v1_fixtures
    source = JSON.parse(File.read(File.join(fixtures, "notify-user-missing-v1.json")))["source"]
    assert_equal ActiveJob.gem_version.to_s, source["active_job_version"], source.inspect

    run = lambda do |*names, env: {}, extra: []|
      args = ["check", "--boot", JobPayloadTest.app_boot("v1"), "--format", "json", *extra]
      Dir.mktmpdir do |dir|
        names.each { |name| FileUtils.cp(File.join(fixtures, "#{name}.json"), dir) }
        out, err, code = JobPayloadTest.run_cli(*args, "--fixtures", dir, env: env)
        [JSON.parse(out), code, err]
      end
    end

    document, code, err = run.call("notify-user-missing-v1", "notify-users-nested-missing-v1", "notify-user-v1")
    assert_equal 0, code, err
    assert_equal [%w[AJP202 arguments[0]], ['AJP202', 'arguments[0]["batch"][1]']],
      document["findings"].map { |f| [f["code"], f["argument_path"]] }
    assert_equal "ActiveJob::DeserializationError::RecordNotFound", document["findings"].first["exception_class"]

    _document, code, err = run.call("notify-user-missing-v1", extra: ["--fail-on-inconclusive"])
    assert_equal 1, code, err

    document, code, err = run.call("notify-user-v1", env: { "JOBPAYLOAD_TEST_NO_DB" => "1" })
    assert_equal 2, code, err
    assert_equal ["AJP900"], document["findings"].map { |f| f["code"] }
  end
end
