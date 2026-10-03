# frozen_string_literal: true

require_relative "test_helper"

class CanonicalTest < Minitest::Test
  def test_generate_sorts_keys_recursively_and_ends_with_newline
    a = { "b" => 1, "a" => { "z" => [{ "y" => 1, "x" => 2 }], "c" => nil } }
    b = { "a" => { "c" => nil, "z" => [{ "x" => 2, "y" => 1 }] }, "b" => 1 }
    json = JobPayload::Canonical.generate(a)

    assert_equal json, JobPayload::Canonical.generate(b)
    assert json.end_with?("}\n")
    refute_includes json, "\r"
    assert_equal Encoding::UTF_8, json.encoding
    assert_equal %w[a b], JSON.parse(json).keys
    assert_equal %w[c z], JSON.parse(json)["a"].keys
  end

  def test_generate_keeps_array_order
    assert_equal "[\n  3,\n  1,\n  2\n]\n", JobPayload::Canonical.generate([3, 1, 2])
  end

  def test_layout_is_fixed_independent_of_the_json_gem
    value = { "s" => "✓ \"q\" \n", "e" => {}, "a" => [], "n" => nil, "f" => 1.5, "i" => -2, "t" => true,
              "nested" => { "list" => [{}, []] } }
    expected = <<~JSON
      {
        "a": [],
        "e": {},
        "f": 1.5,
        "i": -2,
        "n": null,
        "nested": {
          "list": [
            {},
            []
          ]
        },
        "s": "✓ \\"q\\" \\n",
        "t": true
      }
    JSON
    assert_equal expected, JobPayload::Canonical.generate(value)
    assert_equal value, JSON.parse(expected)
  end

  def test_rejects_non_json_values
    assert_raises(ArgumentError) { JobPayload::Canonical.generate({ "t" => Time.now }) }
  end

  def test_pretty_keeps_given_key_order
    assert_equal "{\n  \"b\": 1,\n  \"a\": 2\n}\n", JobPayload::Canonical.pretty({ "b" => 1, "a" => 2 })
  end

  def test_deep_copy_is_independent
    original = { "a" => [{ "b" => "str" }], "n" => 1 }
    copy = JobPayload::Canonical.deep_copy(original)
    copy["a"][0]["b"] << "!"
    copy["a"] << 2

    assert_equal({ "a" => [{ "b" => "str" }], "n" => 1 }, original)
  end

  def test_atomic_write_replaces_file_without_leaving_temp_files
    Dir.mktmpdir do |dir|
      path = File.join(dir, "x.json")
      JobPayload::Canonical.atomic_write(path, "one\n")
      JobPayload::Canonical.atomic_write(path, "two\n")

      assert_equal "two\n", File.binread(path)
      assert_equal ["x.json"], Dir.children(dir)
    end
  end
end
