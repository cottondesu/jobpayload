# frozen_string_literal: true

module JobPayload
  module Formatter
    # Human-readable output. Ordering is fully determined by fixture name,
    # finding code and argument path.
    module Text
      LABELS = { breaking: "breaking", inconclusive: "inconclusive", fatal: "fatal" }.freeze

      NOTES = {
        "AJP202" => "This does not by itself prove a payload compatibility break."
      }.freeze

      module_function

      def call(result, fail_on_inconclusive: false, debug: false) # rubocop:disable Lint/UnusedMethodArgument
        blocks = result.fixture_results.flat_map do |fixture_result|
          if fixture_result.findings.empty?
            ["PASS #{fixture_result.name}\n"]
          else
            fixture_result.findings.sort_by(&:sort_key).map { |finding| finding_block(finding, debug: debug) }
          end
        end
        out = +""
        blocks.each_with_index do |block, index|
          previous = blocks[index - 1] if index.positive?
          # Keep consecutive PASS lines together; separate multi-line blocks.
          out << "\n" if previous && (multiline?(block) || multiline?(previous))
          out << block
        end
        out << "\n" << summary(result)
      end

      def multiline?(block)
        block.count("\n") > 1
      end

      def finding_block(finding, debug:)
        lines = ["#{finding.code} #{LABELS.fetch(finding.kind)} #{finding.fixture}", ""]
        if finding.job_class
          lines += ["Job:", "  #{finding.job_class}", ""]
        end
        if finding.argument_path
          lines += ["Argument:", "  #{finding.argument_path}", ""]
        end
        lines << finding.message
        if (note = NOTES[finding.code])
          lines += ["", note]
        end
        if (root = finding.cause_chain.last)
          lines += ["", "Cause:", "  #{root['class']}: #{root['message']}"]
        end
        lines += debug_lines(finding) if debug
        "#{lines.join("\n")}\n"
      end

      def debug_lines(finding)
        return [] if finding.cause_chain.empty?

        lines = ["", "Cause chain:"]
        finding.cause_chain.each_with_index do |cause, index|
          lines << "  #{index + 1}. #{cause['class']}: #{cause['message']}"
          finding.backtraces.fetch(index, []).each { |frame| lines << "       #{frame}" }
        end
        lines
      end

      def summary(result)
        counts = result.summary
        lines = [
          "#{counts['fixtures']} fixtures checked",
          "#{counts['compatible']} compatible",
          "#{counts['incompatible']} incompatible",
          "#{counts['inconclusive']} inconclusive"
        ]
        tool_errors = counts["tool_errors"]
        lines << "#{tool_errors} tool error#{'s' unless tool_errors == 1}" if tool_errors.positive?
        "#{lines.join("\n")}\n"
      end
    end
  end
end
