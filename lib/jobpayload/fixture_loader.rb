# frozen_string_literal: true

module JobPayload
  # Resolves --fixtures (a directory or a single file) into fixture files, in a
  # stable order that does not depend on directory enumeration order.
  #
  # Listing (.files) only touches the file system, so it runs before the host
  # application boots; parsing (.parse) needs the json library and runs after
  # boot, so the application's own json version is the one that gets loaded.
  module FixtureLoader
    module_function

    def files(path)
      files =
        if File.directory?(path)
          Dir.children(path).select { |entry| entry.end_with?(".json") }.sort.map { |entry| File.join(path, entry) }
            .select { |file| File.file?(file) }
        elsif File.file?(path)
          [path]
        else
          raise ConfigurationError, "fixture path not found: #{path}"
        end
      raise ConfigurationError, "no fixture files (*.json) found in #{path}" if files.empty?

      files
    end

    def parse(files)
      files.map { |file| Fixture.parse(file) }
    end

    def call(path)
      parse(files(path))
    end
  end
end
