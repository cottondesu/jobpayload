# frozen_string_literal: true

require "json"

module JobPayload
  # Helpers for JSON-compatible data: deterministic serialization and deep copies.
  module Canonical
    module_function

    # Returns a copy of +value+ with every Hash's keys sorted (recursively), so
    # output never depends on Hash insertion order.
    def sort_keys(value)
      case value
      when Hash
        value.keys.sort_by(&:to_s).each_with_object({}) { |key, sorted| sorted[key] = sort_keys(value[key]) }
      when Array
        value.map { |element| sort_keys(element) }
      else
        value
      end
    end

    # Pretty printed, key-sorted, UTF-8 JSON with LF newlines and a final newline.
    def generate(value)
      pretty(sort_keys(value))
    end

    # Pretty prints JSON-compatible data with two-space indentation, keeping
    # Hash key order as given. The layout is produced here rather than by
    # JSON.pretty_generate so the bytes do not depend on the json gem version
    # (for example, older versions render an empty object as "{\n}").
    def pretty(value)
      "#{dump(value, 0)}\n".encode(Encoding::UTF_8)
    end

    def dump(value, depth)
      indent = "  " * (depth + 1)
      closing = "  " * depth
      case value
      when Hash
        return "{}" if value.empty?

        members = value.map { |key, element| "#{indent}#{::JSON.generate(key.to_s)}: #{dump(element, depth + 1)}" }
        "{\n#{members.join(",\n")}\n#{closing}}"
      when Array
        return "[]" if value.empty?

        "[\n#{value.map { |element| "#{indent}#{dump(element, depth + 1)}" }.join(",\n")}\n#{closing}]"
      when String, Integer, Float, true, false, nil
        ::JSON.generate(value)
      else
        raise ArgumentError, "not a JSON-compatible value: #{value.class}"
      end
    end

    # Recursive copy of a parsed JSON structure (Hash/Array/String/scalars).
    # Each check phase gets its own copy so a deserializer that mutates its
    # input cannot influence another phase.
    def deep_copy(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, element), copy| copy[deep_copy(key)] = deep_copy(element) }
      when Array
        value.map { |element| deep_copy(element) }
      when String
        value.dup
      else
        value
      end
    end

    # Writes +content+ to +path+ atomically (temporary file in the same
    # directory, then rename).
    def atomic_write(path, content)
      dir = File.dirname(path)
      temp = File.join(dir, ".#{File.basename(path)}.#{Process.pid}.#{rand(1 << 32)}.tmp")
      File.open(temp, "wb") do |file|
        file.write(content)
        file.flush
        file.fsync
      end
      File.rename(temp, path)
    ensure
      File.unlink(temp) if temp && File.exist?(temp)
    end
  end
end
