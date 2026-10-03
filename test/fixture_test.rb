# frozen_string_literal: true

require_relative "test_helper"

class FixtureTest < Minitest::Test
  VALID = {
    "jobpayload_schema" => 1,
    "name" => "ok-v1",
    "source" => { "ruby_version" => "3.3.0" },
    "job" => { "job_class" => "SomeJob", "arguments" => [1] }
  }.freeze

  def parse(content, file: "ok-v1.json")
    Dir.mktmpdir do |dir|
      path = File.join(dir, file)
      File.binwrite(path, content.is_a?(String) ? content : JSON.generate(content))
      JobPayload::Fixture.parse(path)
    end
  end

  def assert_invalid(content, pattern, file: "ok-v1.json")
    fixture = parse(content, file: file)
    assert_kind_of JobPayload::Fixture::Invalid, fixture
    assert_match pattern, fixture.reason
    assert_equal File.basename(file, ".json"), fixture.name
  end

  def test_valid_fixture
    fixture = parse(VALID)
    assert_kind_of JobPayload::Fixture, fixture
    assert_equal "ok-v1", fixture.name
    assert_equal "SomeJob", fixture.job_class
    assert_equal [1], fixture.job["arguments"]
  end

  def test_deeply_nested_arguments_are_accepted
    deep = 150.times.reduce(1) { |inner, _| [inner] }
    fixture = parse(VALID.merge("job" => { "job_class" => "SomeJob", "arguments" => [deep] }).then { |h| JSON.generate(h, max_nesting: false) })
    assert_kind_of JobPayload::Fixture, fixture
  end

  def test_invalid_json
    assert_invalid("{ not json", /invalid JSON/)
  end

  def test_invalid_utf8
    assert_invalid("{\"name\": \"\xFF\"}".b, /not valid UTF-8/)
  end

  # json versions that decode a lone surrogate escape produce a string that is
  # not valid UTF-8; others reject it as invalid JSON. Either way: AJP001.
  def test_lone_surrogate_escape_is_invalid
    content = '{"jobpayload_schema":1,"name":"ok-v1","job":{"job_class":"A\\udc80","arguments":[]}}'
    assert_invalid(content, /not valid UTF-8|invalid JSON/)
  end

  def test_every_parsed_string_and_key_must_be_valid_utf8
    check = ->(data) { JobPayload::Fixture.send(:valid_strings?, data) }
    bad = "\xED\xB2\x80".dup.force_encoding(Encoding::UTF_8)

    assert check.call(VALID)
    refute check.call(VALID.merge("job" => { "arguments" => [[{ "k" => bad }]] }))
    refute check.call({ bad => 1 })
  end

  def test_top_level_must_be_object
    assert_invalid("[1, 2]", /top-level JSON value must be an object/)
  end

  def test_missing_schema
    assert_invalid(VALID.except("jobpayload_schema"), /missing jobpayload_schema/)
  end

  def test_unknown_schema_version
    assert_invalid(VALID.merge("jobpayload_schema" => 2), /unsupported jobpayload_schema 2/)
    assert_invalid(VALID.merge("jobpayload_schema" => "1"), /unsupported jobpayload_schema "1"/)
    assert_invalid(VALID.merge("jobpayload_schema" => 1.0), /unsupported jobpayload_schema 1.0/)
  end

  def test_missing_name
    assert_invalid(VALID.except("name"), /name must be a string/)
  end

  def test_invalid_name
    assert_invalid(VALID.merge("name" => "../ok-v1"), /invalid name/)
  end

  def test_name_must_match_file_name
    assert_invalid(VALID.merge("name" => "other-v1"), /does not match file name ok-v1.json/)
  end

  def test_invalid_file_name
    assert_invalid(VALID.merge("name" => "bad name"), /invalid file name/, file: "bad name.json")
  end

  def test_file_name_that_is_not_utf8_is_reported_as_valid_utf8
    fixture = parse(VALID, file: "bad\xFFname-v1.json".b)

    assert_kind_of JobPayload::Fixture::Invalid, fixture
    assert_equal ["bad\uFFFDname-v1", Encoding::UTF_8], [fixture.name, fixture.name.encoding]
    assert fixture.reason.valid_encoding?
    json = JobPayload::Formatter::JSON.call(JobPayload::Checker.new.call([fixture]))
    assert_equal "bad\uFFFDname-v1", JSON.parse(json)["findings"].first["fixture"]
  end

  def test_missing_job
    assert_invalid(VALID.except("job"), /job must be an object/)
  end

  def test_job_must_be_object
    assert_invalid(VALID.merge("job" => []), /job must be an object/)
  end

  def test_missing_job_class
    assert_invalid(VALID.merge("job" => { "arguments" => [] }), /job_class must be a non-empty string/)
    assert_invalid(VALID.merge("job" => { "job_class" => "", "arguments" => [] }), /job_class/)
    assert_invalid(VALID.merge("job" => { "job_class" => 1, "arguments" => [] }), /job_class/)
  end

  def test_arguments_must_be_array
    assert_invalid(VALID.merge("job" => { "job_class" => "SomeJob", "arguments" => {} }), /arguments must be an array/)
    assert_invalid(VALID.merge("job" => { "job_class" => "SomeJob" }), /arguments must be an array/)
  end

  def test_source_must_be_object_when_present
    assert_invalid(VALID.merge("source" => "x"), /source must be an object/)
  end

  def test_loader_sorts_directory_entries_and_ignores_non_json
    Dir.mktmpdir do |dir|
      %w[b-v1 a-v1 c-v1].each do |name|
        File.write(File.join(dir, "#{name}.json"), JSON.generate(VALID.merge("name" => name)))
      end
      File.write(File.join(dir, "README.md"), "not a fixture")

      assert_equal %w[a-v1 b-v1 c-v1], JobPayload::FixtureLoader.call(dir).map(&:name)
      assert_equal %w[b-v1], JobPayload::FixtureLoader.call(File.join(dir, "b-v1.json")).map(&:name)
    end
  end

  def test_loader_rejects_missing_and_empty_paths
    assert_raises(JobPayload::ConfigurationError) { JobPayload::FixtureLoader.call("/nonexistent/fixtures") }
    Dir.mktmpdir do |dir|
      error = assert_raises(JobPayload::ConfigurationError) { JobPayload::FixtureLoader.call(dir) }
      assert_match(/no fixture files/, error.message)
    end
  end
end
