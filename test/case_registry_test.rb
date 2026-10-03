# frozen_string_literal: true

require_relative "test_helper"

class CaseRegistryTest < Minitest::Test
  def with_cases(source)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "cases.rb")
      File.write(path, source)
      yield path
    end
  end

  def test_cases_are_sorted_by_name
    with_cases(<<~RUBY) do |path|
      JobPayload.define do
        fixture("b-case") { :b }
        fixture("a-case") { :a }
      end
      JobPayload.define do
        fixture("c.case_1") { :c }
      end
    RUBY
      registry = JobPayload::CaseRegistry.load(path)

      assert_equal %w[a-case b-case c.case_1], registry.cases.map(&:name)
      assert_equal :a, registry.cases.first.block.call
      assert_match(/cases\.rb:3\z/, registry.cases.first.location)
    end
  end

  def test_duplicate_fixture_names_are_rejected
    with_cases(<<~RUBY) do |path|
      JobPayload.define do
        fixture("same") { 1 }
        fixture("same") { 2 }
      end
    RUBY
      error = assert_raises(JobPayload::ConfigurationError) { JobPayload::CaseRegistry.load(path) }
      assert_match(/duplicate fixture name "same"/, error.message)
    end
  end

  def test_names_differing_only_in_case_are_duplicates
    with_cases(<<~RUBY) do |path|
      JobPayload.define do
        fixture("Billing-v1") { 1 }
        fixture("billing-v1") { 2 }
      end
    RUBY
      error = assert_raises(JobPayload::ConfigurationError) { JobPayload::CaseRegistry.load(path) }
      assert_match(/duplicate fixture name "billing-v1".*unique ignoring case/, error.message)
    end
  end

  def test_errors_in_the_cases_file_are_configuration_errors
    with_cases("JobPayload.define do\n") do |path|
      error = assert_raises(JobPayload::ConfigurationError) { JobPayload::CaseRegistry.load(path) }
      assert_match(/failed to load cases file .*SyntaxError/, error.message)
    end
    with_cases("UndefinedThing.call\n") do |path|
      error = assert_raises(JobPayload::ConfigurationError) { JobPayload::CaseRegistry.load(path) }
      assert_match(/failed to load cases file .*NameError/, error.message)
    end
  end

  def test_invalid_fixture_names_are_rejected
    ["../escape", "a/b", ".hidden", "-dash", "", "with space", "a..b", "x\n"].each do |name|
      with_cases("JobPayload.define { fixture(#{name.inspect}) { 1 } }\n") do |path|
        error = assert_raises(JobPayload::ConfigurationError, name.inspect) { JobPayload::CaseRegistry.load(path) }
        assert_match(/invalid fixture name/, error.message)
      end
    end
  end

  def test_non_string_names_are_rejected
    with_cases("JobPayload.define { fixture(:sym) { 1 } }\n") do |path|
      assert_raises(JobPayload::ConfigurationError) { JobPayload::CaseRegistry.load(path) }
    end
  end

  def test_empty_cases_file_is_an_error
    with_cases("# nothing\n") do |path|
      error = assert_raises(JobPayload::ConfigurationError) { JobPayload::CaseRegistry.load(path) }
      assert_match(/no fixtures defined/, error.message)
    end
  end

  def test_missing_cases_file_is_an_error
    error = assert_raises(JobPayload::ConfigurationError) { JobPayload::CaseRegistry.load("/nonexistent/cases.rb") }
    assert_match(/cases file not found/, error.message)
  end

  def test_define_outside_a_cases_file_is_an_error
    assert_raises(JobPayload::ConfigurationError) { JobPayload.define { fixture("x") { 1 } } }
  end

  def test_registry_is_not_left_active_after_a_failing_load
    with_cases("JobPayload.define { raise 'boom' }\n") do |path|
      assert_raises(JobPayload::ConfigurationError) { JobPayload::CaseRegistry.load(path) }
    end
    assert_nil Thread.current[JobPayload::CaseRegistry::CURRENT_KEY]
  end
end
