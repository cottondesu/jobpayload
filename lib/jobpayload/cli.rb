# frozen_string_literal: true

require "optparse"

module JobPayload
  # Command line interface.
  #
  # Order of operations is fixed: parse options, boot the host application
  # (once), then use Active Job APIs. Results go to stdout; usage, configuration
  # and boot errors go to stderr.
  class CLI
    EXIT_SUCCESS = 0
    EXIT_FAILURE = 1
    EXIT_ERROR = 2

    DEFAULT_CASES = "test/jobpayload_cases.rb"
    DEFAULT_FIXTURES = "test/jobpayload_fixtures"

    USAGE = <<~TEXT
      Usage: jobpayload COMMAND [options]

      Commands:
        snapshot    Write baseline fixtures from snapshot cases (ActiveJob::Base#serialize)
        check       Check that fixtures can be deserialized by the current application

      Options:
        -v, --version   Print the version
        -h, --help      Print this help

      Run `jobpayload COMMAND --help` for command options.
    TEXT

    def initialize(argv, stdout: $stdout, stderr: $stderr)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @debug = false
    end

    def run
      command = @argv.shift
      case command
      when "snapshot" then with_stdout_redirected { snapshot }
      when "check" then with_stdout_redirected { check }
      when "-v", "--version", "version"
        @stdout.puts("jobpayload v#{VERSION}")
        EXIT_SUCCESS
      when "-h", "--help", "help"
        @stdout.print(USAGE)
        EXIT_SUCCESS
      when nil
        usage_error("no command given")
      else
        usage_error("unknown command #{command.inspect}")
      end
    rescue OptionParser::ParseError => e
      usage_error(e.message)
    rescue SystemExit => e
      # Application code (boot file, initializers, serializers, case blocks)
      # called exit/abort. Never let its status masquerade as exit 0 or 1.
      error(Error.new("the application exited with status #{e.status} while jobpayload was running"))
    rescue Error => e
      error(e)
    rescue Interrupt, SignalException
      raise
    rescue Exception => e # rubocop:disable Lint/RescueException
      # Anything else (SystemStackError from pathologically deep fixtures, or
      # an application exception that does not inherit from StandardError)
      # is a tool error: exit 2, never the compatibility-failure status 1.
      error(e, prefix: "internal error: #{e.class}: ")
    end

    private

    # The host application (boot file, initializers, serializers, case blocks)
    # may print with puts/print. Send that to stderr so stdout only carries
    # jobpayload's own result (which is written to @stdout directly).
    def with_stdout_redirected
      saved = $stdout
      $stdout = @stderr
      yield
    ensure
      $stdout = saved
    end

    def snapshot
      options = {
        cases: DEFAULT_CASES, output: DEFAULT_FIXTURES, boot: Boot::DEFAULT_PATH,
        environment: Boot::DEFAULT_ENVIRONMENT, update: false, format: "text"
      }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: jobpayload snapshot [options]"
        opts.on("--cases PATH", "Snapshot cases file (default: #{DEFAULT_CASES})") { |v| options[:cases] = v }
        opts.on("--output DIR", "Fixture output directory (default: #{DEFAULT_FIXTURES})") { |v| options[:output] = v }
        boot_options(opts, options)
        opts.on("--update", "Replace existing fixtures whose content changed") { options[:update] = true }
        format_option(opts, options)
      end
      return EXIT_SUCCESS if parse(parser)

      formatter_name = options[:format]
      raise ConfigurationError, "cases file not found: #{options[:cases]}" unless File.file?(options[:cases])
      if File.exist?(options[:output]) && !File.directory?(options[:output])
        raise ConfigurationError, "output path is not a directory: #{options[:output]}"
      end

      boot(options)
      registry = CaseRegistry.load(options[:cases])
      entries = Snapshotter.new(registry: registry, output_dir: options[:output], update: options[:update]).call
      @stdout.print(formatter_name == "json" ? snapshot_json(entries) : snapshot_text(entries))
      EXIT_SUCCESS
    end

    def check
      options = {
        fixtures: DEFAULT_FIXTURES, boot: Boot::DEFAULT_PATH, environment: Boot::DEFAULT_ENVIRONMENT,
        format: "text", fail_on_inconclusive: false
      }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: jobpayload check [options]"
        opts.on("--fixtures PATH", "Fixture directory or file (default: #{DEFAULT_FIXTURES})") { |v| options[:fixtures] = v }
        boot_options(opts, options)
        format_option(opts, options)
        opts.on("--fail-on-inconclusive", "Exit 1 when any fixture is inconclusive") { options[:fail_on_inconclusive] = true }
        opts.on("--debug", "Show exception backtraces in text output") { @debug = true }
      end
      return EXIT_SUCCESS if parse(parser)

      files = FixtureLoader.files(options[:fixtures])
      boot(options)
      formatter = Formatter.for(options[:format])
      result = Checker.new.call(FixtureLoader.parse(files))
      @stdout.print(formatter.call(result, fail_on_inconclusive: options[:fail_on_inconclusive], debug: @debug))
      result.exit_code(fail_on_inconclusive: options[:fail_on_inconclusive])
    end

    # Returns true when help or the version was printed (nothing else to do).
    def parse(parser)
      done = false
      parser.on("-h", "--help", "Print this help") do
        @stdout.print(parser.help)
        done = true
      end
      # Replaces OptionParser's built-in --version, which would print
      # "version unknown" and exit 1 (the compatibility-failure status).
      parser.on("-v", "--version", "Print the version") do
        @stdout.puts("jobpayload v#{VERSION}")
        done = true
      end
      # Reject abbreviations such as --fail or --up: the option surface is a contract.
      parser.require_exact = true
      rest = parser.parse(@argv)
      raise UsageError, "unexpected argument #{rest.first.inspect}" unless rest.empty? || done

      done
    end

    def boot_options(opts, options)
      opts.on("--boot PATH", "Application boot file (default: #{Boot::DEFAULT_PATH})") { |v| options[:boot] = v }
      opts.on("--environment NAME", "RAILS_ENV to boot (default: #{Boot::DEFAULT_ENVIRONMENT})") do |v|
        options[:environment] = v
      end
    end

    def format_option(opts, options)
      opts.on("--format FORMAT", Formatter::FORMATS, "Output format: #{Formatter::FORMATS.join('|')} (default: text)") do |v|
        options[:format] = v
      end
    end

    def boot(options)
      if options[:environment] == "production"
        @stderr.puts("jobpayload: warning: booting the production environment")
      end
      Boot.call(path: options[:boot], environment: options[:environment])
    end

    def snapshot_text(entries)
      lines = entries.map do |entry|
        line = format("%-9s %s  %s", entry.status, entry.name, entry.path)
        entry.status == :skipped ? "#{line}  (exists and differs; pass --update to replace)" : line
      end
      counts = entries.map(&:status).tally
      summary = %i[created updated identical skipped].map { |status| "#{counts.fetch(status, 0)} #{status}" }.join(", ")
      "#{lines.join("\n")}\n\n#{entries.size} fixtures: #{summary}\n"
    end

    def snapshot_json(entries)
      counts = entries.map(&:status).tally
      document = {
        "schema_version" => 1,
        "tool_version" => VERSION,
        "summary" => %i[created updated identical skipped].to_h { |status| [status.to_s, counts.fetch(status, 0)] },
        "fixtures" => entries.map { |e| { "name" => e.name, "path" => JobPayload.scrub_utf8(e.path), "status" => e.status.to_s } }
      }
      Canonical.pretty(document)
    end

    def usage_error(message)
      @stderr.puts("jobpayload: #{message}")
      @stderr.puts("Run `jobpayload --help` for usage.")
      EXIT_ERROR
    end

    def error(exception, prefix: "")
      label = exception.is_a?(BootError) ? "AJP900 environment_error: " : ""
      @stderr.puts("jobpayload: error: #{label}#{prefix}#{exception.message}")
      if @debug
        ExceptionClassifier.cause_chain(exception).each do |e|
          @stderr.puts("  #{e.class}: #{e.message}")
          Array(e.backtrace).each { |frame| @stderr.puts("      #{frame}") }
        end
      end
      EXIT_ERROR
    end
  end
end
