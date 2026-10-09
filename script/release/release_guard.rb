#!/usr/bin/env ruby
# frozen_string_literal: true

# Release guard for .github/workflows/release.yml (see docs/RELEASING.md).
#
# Every check the release workflow makes before, during and after publishing
# lives here, so that it can be tested without GitHub Actions, RubyGems or a
# real tag (test/release/release_guard_test.rb). Standard library only: it runs
# without `bundle install`.
#
#   ruby script/release/release_guard.rb <command>
#
# Inputs come from environment variables, never from the command line or from
# workflow expressions interpolated into a shell script. Every check fails
# closed: an error, an unexpected HTTP status or a malformed response is a
# failure, never "not published" or "absent". The script never prints
# credentials, never creates or moves a tag, never yanks a gem and never
# pushes a gem a second time.

require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "openssl"
require "rbconfig"
require "rubygems/package"
require "stringio"
require "tmpdir"
require "uri"
require "zlib"

module ReleaseGuard
  class Failure < StandardError; end

  # A published artifact that is not the one this workflow built and verified.
  class Critical < Failure; end

  # The network or the remote service failed; the state is unknown.
  class TransportError < Failure; end

  GEM_NAME = "jobpayload"
  REPOSITORY = "cottondesu/jobpayload"
  REPOSITORY_ID = "1402924325"
  MAIN_BRANCH = "main"
  ENVIRONMENT = "release"
  RUBYGEMS = "https://rubygems.org"
  GITHUB_API = "https://api.github.com"

  # vMAJOR.MINOR.PATCH only: no pre-release or build suffix, no leading zeros.
  TAG_PATTERN = /\Av(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\z/
  VERSION_PATTERN = /\A(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\z/
  SHA1 = /\A[0-9a-f]{40}\z/
  SHA256 = /\A[0-9a-f]{64}\z/

  # Files a release gem may contain (the gemspec's spec.files patterns).
  PACKAGE_FILE_PATTERNS = [
    %r{\Alib/(?:[a-z0-9_]+/)*[a-z0-9_]+\.rb\z},
    %r{\Aexe/jobpayload\z},
    /\AREADME\.md\z/,
    /\ACHANGELOG\.md\z/,
    /\ALICENSE\z/
  ].freeze

  SECRET_PATTERNS = {
    "RubyGems API key" => /rubygems_[0-9a-f]{48}/,
    "GitHub token" => /\bgh[pousr]_[A-Za-z0-9]{36,}/,
    "GitHub fine-grained token" => /\bgithub_pat_[A-Za-z0-9_]{40,}/,
    "private key" => /-----BEGIN [A-Z ]*PRIVATE KEY-----/,
    "AWS access key" => /\bAKIA[0-9A-Z]{16}\b/,
    "Slack token" => /\bxox[abprs]-[A-Za-z0-9-]{10,}/
  }.freeze

  STATIC_CREDENTIAL_VARIABLES = %w[GEM_HOST_API_KEY RUBYGEMS_API_KEY BUNDLE_GEM__PUSH_KEY].freeze

  # Skips the release test jobs accept. Anything else is an unexpected skip.
  CROSS_VERSION_SKIP = /\Aactive_job_(\d+\.\d+) is newer than activejob (\d+\.\d+)\z/
  NON_UTF8_SKIP = /\Afilesystem does not support non-UTF-8 (?:file|directory) names: Errno::EILSEQ\b/

  module_function

  def version_from_tag(tag)
    raise Failure, "#{tag.inspect} is not a release tag: expected vMAJOR.MINOR.PATCH (for example v0.3.0)" unless tag.is_a?(String) && TAG_PATTERN.match?(tag)

    tag.delete_prefix("v")
  end

  def sha256_hex(data)
    Digest::SHA256.hexdigest(data)
  end

  # --- Environment and GitHub Actions plumbing ------------------------------

  class Env
    def initialize(env = ENV)
      @env = env
    end

    def fetch(name)
      value = @env[name]
      raise Failure, "#{name} is not set" if value.nil? || value.empty?

      value
    end

    def [](name)
      @env[name]
    end

    def fetch_matching(name, pattern, description)
      value = fetch(name)
      raise Failure, "#{name} is not #{description}: #{value.inspect}" unless pattern.match?(value)

      value
    end
  end

  # Appends to $GITHUB_OUTPUT and $GITHUB_STEP_SUMMARY when they are set.
  class Actions
    def initialize(env = ENV, out: $stdout)
      @output = env["GITHUB_OUTPUT"]
      @summary = env["GITHUB_STEP_SUMMARY"]
      @out = out
    end

    def output(name, value)
      value = value.to_s
      raise Failure, "refusing to write a multi-line output #{name}" if value.match?(/[\r\n]/)

      File.open(@output, "a") { |f| f.puts("#{name}=#{value}") } if @output
      @out.puts("#{name}=#{value}")
    end

    def summary(markdown)
      File.open(@summary, "a") { |f| f.puts(markdown) } if @summary
    end

    def log(message)
      @out.puts(message)
    end

    def self.escape_command(message)
      message.to_s.gsub("%", "%25").gsub("\r", "%0D").gsub("\n", "%0A")
    end
  end

  # --- Processes -------------------------------------------------------------

  ProcessResult = Struct.new(:status, :output, :timed_out, keyword_init: true) do
    def success?
      !timed_out && status&.success?
    end
  end

  # Runs a command given as an argument vector (never through a shell).
  class Runner
    def initialize(grace: 5)
      @grace = grace
    end

    def call(argv, env: {}, chdir: Dir.pwd, timeout: nil)
      raise ArgumentError, "argv must be an array of strings" unless argv.is_a?(Array) && argv.all?(String)

      Open3.popen2e(env, *argv, chdir: chdir, pgroup: true) do |stdin, out, wait|
        stdin.close
        reader = Thread.new { out.read }
        timed_out = timeout && wait.join(timeout).nil?
        if timed_out
          terminate(wait.pid)
          wait.join
        end
        ProcessResult.new(status: wait.value, output: reader.value.to_s, timed_out: !!timed_out)
      end
    end

    private

    def terminate(pid)
      Process.kill("TERM", -pid)
      sleep @grace
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH
      nil
    end
  end

  class Git
    def initialize(dir: Dir.pwd, runner: Runner.new, env: {})
      @dir = dir
      @runner = runner
      @env = env
    end

    def run(*args)
      result = @runner.call(["git", *args], env: @env, chdir: @dir)
      raise Failure, "git #{args.join(' ')} failed:\n#{result.output}" unless result.success?

      result.output
    end

    def ok?(*args)
      @runner.call(["git", *args], env: @env, chdir: @dir).success?
    end

    def rev_parse(rev)
      sha = run("rev-parse", "--verify", "--quiet", "#{rev}^{object}").strip
      raise Failure, "#{rev} does not resolve to an object" unless SHA1.match?(sha)

      sha
    end

    # Fetches the remote tag and the remote main branch into private refs, so
    # that whatever a checkout did to local tags and branches does not matter.
    def fetch_release_refs(tag)
      ReleaseGuard.version_from_tag(tag) # never fetch a ref name that was not validated
      run("fetch", "--no-tags", "--no-recurse-submodules", "--force", "origin",
          "+refs/tags/#{tag}:refs/release-guard/tag",
          "+refs/heads/#{MAIN_BRANCH}:refs/release-guard/main")
    end

    def blob(commit, path)
      spec = "#{commit}:#{path}"
      return nil unless ok?("cat-file", "-e", spec)
      raise Failure, "#{path} in #{commit} is not a file" unless run("cat-file", "-t", spec).strip == "blob"

      result = @runner.call(["git", "cat-file", "blob", spec], env: @env, chdir: @dir)
      raise Failure, "cannot read #{spec}" unless result.success?

      result.output.b
    end
  end

  # --- HTTP ----------------------------------------------------------------

  Response = Struct.new(:status, :body, keyword_init: true)

  class HTTP
    MAX_BODY = 50 * 1024 * 1024
    RETRYABLE = [Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET,
                 Errno::EHOSTUNREACH, Errno::ETIMEDOUT, OpenSSL::SSL::SSLError, EOFError, IOError].freeze

    def initialize(open_timeout: 10, read_timeout: 60)
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    # Follows at most +redirects+ redirects, and only to https URLs on
    # +allowed_hosts+.
    def get(url, headers: {}, redirects: 0, allowed_hosts: nil)
      uri = URI(url)
      (redirects + 1).times do
        raise Failure, "refusing non-HTTPS URL #{uri}" unless uri.is_a?(URI::HTTPS)

        response = request(uri, headers)
        location = response["location"]
        if response.is_a?(Net::HTTPRedirection) && location && redirects.positive?
          uri = URI.join(uri.to_s, location)
          raise Failure, "refusing redirect to #{uri.host}" if allowed_hosts && !allowed_hosts.any? { |h| uri.host == h || uri.host.end_with?(".#{h}") }

          next
        end
        body = response.body.to_s.b
        raise Failure, "response from #{uri.host} is larger than #{MAX_BODY} bytes" if body.bytesize > MAX_BODY

        return Response.new(status: response.code.to_i, body: body)
      end
      raise Failure, "too many redirects for #{url}"
    end

    private

    def request(uri, headers)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: @open_timeout, read_timeout: @read_timeout) do |http|
        request = Net::HTTP::Get.new(uri)
        headers.each { |k, v| request[k] = v }
        http.request(request)
      end
    rescue *RETRYABLE => e
      raise TransportError, "#{uri.host}: #{e.class}: #{e.message}"
    end
  end

  def parse_json(body, what)
    JSON.parse(body.to_s)
  rescue JSON::ParserError => e
    raise Failure, "#{what} returned a response that is not valid JSON (#{e.message[0, 120]})"
  end

  # --- RubyGems --------------------------------------------------------------

  RubyGemsState = Struct.new(:state, :sha256, keyword_init: true) do
    def present?
      state == :present
    end
  end

  class RubyGems
    def initialize(http: HTTP.new, base: RUBYGEMS)
      @http = http
      @base = base
    end

    # Asks two independent RubyGems APIs whether +version+ is published and
    # requires them to agree. Any HTTP error, malformed body or disagreement
    # raises: it never means "not published".
    def state(version)
      raise Failure, "invalid version #{version.inspect}" unless VERSION_PATTERN.match?(version)

      listed = listed_versions(version)
      single = single_version(version)

      if listed.nil? != single.nil?
        raise Failure, "RubyGems APIs disagree about #{GEM_NAME} #{version} " \
                       "(versions list: #{listed ? 'published' : 'absent'}, version API: #{single ? 'published' : 'absent'}); state unknown"
      end
      return RubyGemsState.new(state: :absent) if listed.nil?

      if listed != single
        raise Failure, "RubyGems APIs report different SHA-256 values for #{GEM_NAME} #{version}: #{listed} vs #{single}"
      end

      RubyGemsState.new(state: :present, sha256: single)
    end

    def download(version)
      @http.get("#{@base}/downloads/#{GEM_NAME}-#{version}.gem", redirects: 3, allowed_hosts: ["rubygems.org"])
    end

    def single_version(version)
      response = @http.get("#{@base}/api/v2/rubygems/#{GEM_NAME}/versions/#{version}.json",
                           headers: { "Accept" => "application/json" })
      return nil if response.status == 404
      raise Failure, "RubyGems version API returned HTTP #{response.status} for #{GEM_NAME} #{version}; state unknown" unless response.status == 200

      document = ReleaseGuard.parse_json(response.body, "RubyGems version API")
      unless document.is_a?(Hash) && document["number"] == version && SHA256.match?(document["sha"].to_s)
        raise Failure, "RubyGems version API returned an unexpected document for #{GEM_NAME} #{version}; state unknown"
      end
      raise Failure, "#{GEM_NAME} #{version} is published for platform #{document['platform'].inspect}, not ruby" unless document["platform"] == "ruby"

      document["sha"]
    end

    private

    def listed_versions(version)
      response = @http.get("#{@base}/api/v1/versions/#{GEM_NAME}.json", headers: { "Accept" => "application/json" })
      raise Failure, "RubyGems versions API returned HTTP #{response.status}; state unknown" unless response.status == 200

      list = ReleaseGuard.parse_json(response.body, "RubyGems versions API")
      # jobpayload already has published versions, so an empty list is as
      # suspicious as a malformed one.
      unless list.is_a?(Array) && !list.empty? && list.all? { |v| v.is_a?(Hash) && v["number"].is_a?(String) }
        raise Failure, "RubyGems versions API returned an unexpected document; state unknown"
      end

      matches = list.select { |v| v["number"] == version }
      return nil if matches.empty?
      raise Failure, "#{GEM_NAME} #{version} is listed more than once (#{matches.map { |v| v['platform'] }.inspect})" unless matches.size == 1
      raise Failure, "versions API lists #{GEM_NAME} #{version} without a SHA-256" unless SHA256.match?(matches.first["sha"].to_s)

      matches.first["sha"]
    end
  end

  # --- GitHub ----------------------------------------------------------------

  class GitHub
    def initialize(http: HTTP.new, token: nil, repository: REPOSITORY)
      @http = http
      @token = token
      @repository = repository
    end

    def get(path)
      headers = { "Accept" => "application/vnd.github+json", "X-GitHub-Api-Version" => "2022-11-28" }
      headers["Authorization"] = "Bearer #{@token}" if @token && !@token.empty?
      @http.get("#{GITHUB_API}/repos/#{@repository}#{path}", headers: headers)
    end

    def get_json(path, what)
      response = get(path)
      raise Failure, "GitHub API (#{what}) returned HTTP #{response.status}" unless response.status == 200

      ReleaseGuard.parse_json(response.body, "GitHub API (#{what})")
    end

    # Published releases by tag name (never drafts).
    def release_by_tag(tag)
      response = get("/releases/tags/#{tag}")
      return nil if response.status == 404
      raise Failure, "GitHub API returned HTTP #{response.status} looking up the release for #{tag}; state unknown" unless response.status == 200

      release = ReleaseGuard.parse_json(response.body, "GitHub release")
      raise Failure, "GitHub API returned an unexpected release document for #{tag}" unless release.is_a?(Hash) && release["tag_name"] == tag

      release
    end

    # Every release, drafts included when the token can see them.
    def releases_for_tag(tag, max_pages: 20)
      found = []
      (1..max_pages).each do |page|
        list = get_json("/releases?per_page=100&page=#{page}", "releases")
        raise Failure, "GitHub API returned an unexpected releases list" unless list.is_a?(Array) && list.all?(Hash)

        found.concat(list.select { |r| r["tag_name"] == tag })
        return found if list.size < 100
      end
      raise Failure, "more than #{max_pages * 100} releases; cannot prove that #{tag} has none"
    end
  end

  # --- Checks ----------------------------------------------------------------

  class Guard
    attr_reader :actions

    def initialize(env: ENV, dir: Dir.pwd, runner: Runner.new, http: HTTP.new, actions: nil, sleeper: ->(s) { sleep(s) },
                   git_env: {})
      @env = Env.new(env)
      @dir = dir
      @runner = runner
      @http = http
      @actions = actions || Actions.new(env)
      @sleeper = sleeper
      @git = Git.new(dir: dir, runner: runner, env: git_env)
      @rubygems = RubyGems.new(http: http)
    end

    def github
      @github ||= GitHub.new(http: @http, token: @env["GH_TOKEN"], repository: REPOSITORY)
    end

    # 1. The run is a tag push of an annotated vX.Y.Z tag in this repository,
    #    and the tag's commit is the current head of main (strict policy).
    def validate_tag
      raise Failure, "event is #{@env['GITHUB_EVENT_NAME'].inspect}, not a tag push" unless @env["GITHUB_EVENT_NAME"] == "push"
      raise Failure, "ref type is #{@env['GITHUB_REF_TYPE'].inspect}, not tag" unless @env["GITHUB_REF_TYPE"] == "tag"

      repository = @env.fetch("GITHUB_REPOSITORY")
      raise Failure, "repository is #{repository}, not #{REPOSITORY}" unless repository == REPOSITORY

      repository_id = @env.fetch("GITHUB_REPOSITORY_ID")
      raise Failure, "repository id is #{repository_id}, not #{REPOSITORY_ID}" unless repository_id == REPOSITORY_ID

      tag = @env.fetch("GITHUB_REF_NAME")
      version = ReleaseGuard.version_from_tag(tag)
      raise Failure, "GITHUB_REF is #{@env['GITHUB_REF'].inspect}, not refs/tags/#{tag}" unless @env["GITHUB_REF"] == "refs/tags/#{tag}"

      sha = @env.fetch_matching("GITHUB_SHA", SHA1, "a commit SHA")
      ref = remote_tag(tag)
      raise Failure, "#{tag} points to #{ref[:commit]}, but this run was triggered for #{sha}" unless ref[:commit] == sha

      main = @git.rev_parse("refs/release-guard/main")
      unless main == ref[:commit]
        raise Failure, "#{tag} points to #{ref[:commit]}, but #{MAIN_BRANCH} is at #{main}. " \
                       "Releases are only made from the current head of #{MAIN_BRANCH} (see docs/RELEASING.md)"
      end

      head = @git.rev_parse("HEAD")
      raise Failure, "the checkout is at #{head}, not #{ref[:commit]}" unless head == ref[:commit]

      release_notes(tag, ref[:commit])
      tree = @git.rev_parse("#{ref[:commit]}^{tree}")

      {
        "tag" => tag, "version" => version, "commit" => ref[:commit], "tag_object" => ref[:object], "tree" => tree
      }.each { |k, v| @actions.output(k, v) }
      @actions.summary(<<~MD)
        ### Release tag

        | | |
        | --- | --- |
        | Tag | `#{tag}` (annotated, tag object `#{ref[:object]}`) |
        | Version | `#{version}` |
        | Commit | `#{ref[:commit]}` (head of `#{MAIN_BRANCH}`) |
        | Tree | `#{tree}` |
        | Tagger | #{ref[:tagger]} |
      MD
    end

    # Fetches the tag from origin and returns its tag object and commit.
    # Lightweight tags, tags of tags and tags whose object names another tag
    # are rejected.
    def remote_tag(tag)
      @git.fetch_release_refs(tag)
      object = @git.rev_parse("refs/release-guard/tag")
      type = @git.run("cat-file", "-t", object).strip
      raise Failure, "#{tag} is a lightweight tag (it points directly to a #{type}); releases need an annotated tag (git tag -a)" unless type == "tag"

      header = @git.run("cat-file", "tag", object).split("\n\n", 2).first.to_s
      fields = header.lines.to_h { |line| line.chomp.split(" ", 2) }
      raise Failure, "#{tag} does not point to a commit (it points to a #{fields['type']})" unless fields["type"] == "commit"
      raise Failure, "tag object #{object} is named #{fields['tag'].inspect}, not #{tag}" unless fields["tag"] == tag

      commit = fields["object"]
      raise Failure, "tag object #{object} names an invalid commit" unless SHA1.match?(commit.to_s) && @git.rev_parse("#{commit}^{commit}") == commit

      { object: object, commit: commit, tagger: fields["tagger"].to_s.sub(/ <[^>]*>/, "") }
    end

    # The release notes are docs/releases/vX.Y.Z.md as committed at the tag.
    def release_notes(tag, commit)
      path = "docs/releases/#{tag}.md"
      content = @git.blob(commit, path)
      raise Failure, "#{path} is missing from #{commit}; write the release notes before tagging" if content.nil?

      text = content.dup.force_encoding(Encoding::UTF_8)
      raise Failure, "#{path} is not valid UTF-8" unless text.valid_encoding?
      raise Failure, "#{path} is empty" if text.strip.empty?

      heading = text.lines.find { |line| !line.strip.empty? }.to_s
      raise Failure, "#{path} must start with a heading naming #{tag} (found #{heading.strip.inspect})" unless heading.start_with?("# ") && heading.include?(tag)

      text
    end

    # 2. Gem name and both version sources agree with the tag. Evaluated in a
    #    separate Ruby process so that nothing leaks into this one.
    def check_spec
      version = @env.fetch_matching("RELEASE_VERSION", VERSION_PATTERN, "a version")
      script = <<~'RUBY'
        require "json"
        load File.expand_path("lib/jobpayload/version.rb")
        spec = Gem::Specification.load(File.expand_path("jobpayload.gemspec")) or abort "jobpayload.gemspec does not load"
        puts JSON.generate("constant" => JobPayload::VERSION, "name" => spec.name, "version" => spec.version.to_s,
                           "platform" => spec.platform.to_s)
      RUBY
      result = @runner.call([RbConfig.ruby, "-e", script], env: { "RUBYOPT" => nil }, chdir: @dir)
      raise Failure, "cannot load the gemspec:\n#{result.output}" unless result.success?

      found = ReleaseGuard.parse_json(result.output.lines.last, "gemspec loader")
      raise Failure, "gem name is #{found['name'].inspect}, not #{GEM_NAME}" unless found["name"] == GEM_NAME
      raise Failure, "JobPayload::VERSION is #{found['constant'].inspect}, but the tag is v#{version}" unless found["constant"] == version
      raise Failure, "the gemspec version is #{found['version'].inspect}, but the tag is v#{version}" unless found["version"] == version
      raise Failure, "the gemspec platform is #{found['platform'].inspect}, not ruby" unless found["platform"] == "ruby"

      @actions.log("gem #{GEM_NAME} #{version}: JobPayload::VERSION and the gemspec agree with the tag")
    end

    # 3. The release environment exists and is protected (required reviewers,
    #    deployments only from tags), and the fail-closed flag is defined only
    #    on the environment.
    def check_environment
      unless @env["REPO_LEVEL_GATE"].to_s.empty?
        raise Failure, "RELEASE_GATE_READY is visible outside the #{ENVIRONMENT} environment (repository or organization variable); " \
                       "define it only as an environment variable of #{ENVIRONMENT}"
      end

      response = github.get("/environments/#{ENVIRONMENT}")
      raise Failure, "GitHub environment #{ENVIRONMENT.inspect} does not exist; create and protect it first (docs/RELEASING.md)" if response.status == 404
      raise Failure, "GitHub API returned HTTP #{response.status} for environment #{ENVIRONMENT.inspect}" unless response.status == 200

      environment = ReleaseGuard.parse_json(response.body, "GitHub environment")
      raise Failure, "unexpected environment document" unless environment.is_a?(Hash)

      rules = Array(environment["protection_rules"])
      reviewers_rule = rules.find { |r| r.is_a?(Hash) && r["type"] == "required_reviewers" }
      reviewers = Array(reviewers_rule && reviewers_rule["reviewers"])
      raise Failure, "environment #{ENVIRONMENT.inspect} has no required reviewers; publishing would not wait for approval" if reviewers.empty?

      names = reviewers.map { |r| "#{r['type']}:#{r.dig('reviewer', 'login') || r.dig('reviewer', 'slug') || r.dig('reviewer', 'name')}" }
      actor = @env["GITHUB_ACTOR"].to_s
      if reviewers_rule["prevent_self_review"] && reviewers.all? { |r| r["type"] == "User" && r.dig("reviewer", "login") == actor }
        raise Failure, "environment #{ENVIRONMENT.inspect} prevents self-review, and its only reviewer is #{actor}, who pushed this tag: " \
                       "nobody could approve the deployment"
      end

      policy = environment["deployment_branch_policy"]
      raise Failure, "environment #{ENVIRONMENT.inspect} accepts deployments from any branch or tag; restrict it to release tags" unless policy.is_a?(Hash)
      raise Failure, "environment #{ENVIRONMENT.inspect} must use selected tags, not protected branches" unless policy["custom_branch_policies"] == true

      policies = github.get_json("/environments/#{ENVIRONMENT}/deployment-branch-policies?per_page=100", "deployment policies")
      list = policies.is_a?(Hash) ? Array(policies["branch_policies"]) : []
      raise Failure, "environment #{ENVIRONMENT.inspect} has no deployment tag rule" if list.empty?

      bad = list.reject { |p| p.is_a?(Hash) && p["type"] == "tag" && p["name"].to_s.start_with?("v") }
      raise Failure, "environment #{ENVIRONMENT.inspect} allows deployments from #{bad.map { |p| "#{p['type']} #{p['name']}" }.join(', ')}; allow only release tags" unless bad.empty?

      bypass = environment["can_admins_bypass"]
      @actions.log("::warning::administrators can bypass the #{ENVIRONMENT} environment's protection rules") if bypass
      @actions.summary(<<~MD)
        ### Release environment

        | | |
        | --- | --- |
        | Required reviewers | #{names.join(', ')} |
        | Prevent self-review | #{reviewers_rule['prevent_self_review'] ? 'on' : 'off'} |
        | Deployment tags | #{list.map { |p| "`#{p['name']}`" }.join(', ')} |
        | Administrators can bypass | #{bypass.nil? ? 'unknown' : bypass} |
      MD
    end

    # 4. No GitHub release exists for the tag yet. With a token that can see
    #    drafts (contents: write), drafts count too.
    def check_github_release_absent(include_drafts: false)
      tag = tag_input
      raise Failure, "a GitHub release for #{tag} already exists" if github.release_by_tag(tag)

      if include_drafts
        found = github.releases_for_tag(tag)
        unless found.empty?
          kinds = found.map { |r| r["draft"] ? "draft" : "published" }
          hint = kinds.all?("draft") ? "; delete the draft, then re-run the failed jobs" : ""
          raise Failure, "a GitHub release for #{tag} already exists (#{kinds.join(', ')})#{hint}"
        end
      end
      @actions.log("no GitHub release exists for #{tag}")
    end

    # 5. Whether the version is on RubyGems (absent / present); errors raise.
    def rubygems_state
      version = version_input
      state = @rubygems.state(version)
      @actions.output("rubygems_state", state.state)
      if state.present?
        @actions.log("::warning::#{GEM_NAME} #{version} is already published on RubyGems (SHA-256 #{state.sha256}); this run will not publish anything")
        @actions.output("rubygems_sha256", state.sha256)
      else
        @actions.log("#{GEM_NAME} #{version} is not published on RubyGems")
      end
      state
    end

    # 6. Lists unexpected skips, failures or errors in a verbose minitest log.
    def audit_skips
      log = @env.fetch("TEST_LOG")
      platform = @env.fetch("TEST_PLATFORM")
      raise Failure, "TEST_PLATFORM must be linux or macos" unless %w[linux macos].include?(platform)

      text = File.binread(log).force_encoding(Encoding::UTF_8).scrub
      summary = text.scan(/^(\d+) runs, (\d+) assertions, (\d+) failures, (\d+) errors, (\d+) skips$/).last
      raise Failure, "no minitest summary in #{log}" unless summary

      runs, _assertions, failures, errors, skips = summary.map(&:to_i)
      raise Failure, "no tests ran" if runs.zero?
      raise Failure, "#{failures} failures and #{errors} errors" unless failures.zero? && errors.zero?

      blocks = text.scan(/^ *\d+\) Skipped:\n(\S+) \[[^\]\n]*\]:\n(.*?)(?=\n\n|\n *\d+\) |\n\d+ runs, |\z)/m)
      raise Failure, "the summary reports #{skips} skips, but #{blocks.size} skip details were found (run with --verbose)" unless blocks.size == skips

      unexpected = blocks.reject { |_name, message| expected_skip?(message.strip, platform) }
      unless unexpected.empty?
        raise Failure, "unexpected skips on #{platform}:\n" + unexpected.map { |name, message| "  #{name}: #{message.strip}" }.join("\n")
      end

      @actions.log("#{runs} runs, #{skips} skips, all expected on #{platform}")
      @actions.summary("#{runs} runs, #{skips} expected skips on #{platform}, no failures")
    end

    def expected_skip?(message, platform)
      if (m = CROSS_VERSION_SKIP.match(message))
        return Gem::Version.new(m[1]) > Gem::Version.new(m[2])
      end

      platform == "macos" && NON_UTF8_SKIP.match?(message)
    end

    # 7. Builds the gem twice from the tag's commit with the commit timestamp
    #    as SOURCE_DATE_EPOCH, requires byte-identical results and writes the
    #    gem and its metadata to OUTPUT_DIR.
    def build(builder: nil)
      version = version_input
      commit = commit_input
      out_dir = @env.fetch("OUTPUT_DIR")
      head = @git.rev_parse("HEAD")
      raise Failure, "the checkout is at #{head}, not #{commit}" unless head == commit

      dirty = @git.run("status", "--porcelain=v1", "--untracked-files=all")
      raise Failure, "the checkout has local changes:\n#{dirty}" unless dirty.strip.empty?

      epoch = @git.run("log", "-1", "--format=%ct", commit).strip
      raise Failure, "invalid commit timestamp #{epoch.inspect}" unless epoch.match?(/\A[1-9][0-9]{8,10}\z/)

      filename = "#{GEM_NAME}-#{version}.gem"
      command = ["gem", "build", "#{GEM_NAME}.gemspec", "--output"]
      builder ||= lambda do |path|
        result = @runner.call([*command, path], env: { "SOURCE_DATE_EPOCH" => epoch }, chdir: @dir)
        raise Failure, "gem build failed:\n#{result.output}" unless result.success?

        @actions.log(result.output)
      end

      builds = Dir.mktmpdir("jobpayload-release-build") do |tmp|
        2.times.map do |i|
          path = File.join(tmp, "build-#{i + 1}", filename)
          FileUtils.mkdir_p(File.dirname(path))
          builder.call(path)
          raise Failure, "build #{i + 1} did not produce #{filename}" unless File.file?(path) && !File.symlink?(path)

          File.binread(path)
        end
      end
      first, second = builds
      unless first == second
        raise Failure, "REPRODUCIBILITY MISMATCH: two builds of #{commit} differ " \
                       "(#{ReleaseGuard.sha256_hex(first)} vs #{ReleaseGuard.sha256_hex(second)}); not publishing"
      end

      FileUtils.mkdir_p(out_dir)
      gem_path = File.join(out_dir, filename)
      File.open(gem_path, File::WRONLY | File::CREAT | File::EXCL | File::BINARY) { |f| f.write(first) }

      sha = ReleaseGuard.sha256_hex(first)
      metadata = {
        "gem" => GEM_NAME,
        "version" => version,
        "tag" => tag_input,
        "source_commit" => commit,
        "source_tree" => @git.rev_parse("#{commit}^{tree}"),
        "filename" => filename,
        "size" => first.bytesize,
        "sha256" => sha,
        "source_date_epoch" => epoch.to_i,
        "ruby" => RUBY_DESCRIPTION,
        "rubygems" => Gem::VERSION,
        "bundler" => bundler_version,
        "platform" => RbConfig::CONFIG["host"],
        "runner_os" => @env["RUNNER_OS"],
        "runner_arch" => @env["RUNNER_ARCH"],
        "build_command" => "SOURCE_DATE_EPOCH=#{epoch} #{command.join(' ')} #{filename}",
        "reproducible_builds" => 2
      }
      File.write(File.join(out_dir, "release-metadata.json"), "#{JSON.pretty_generate(metadata)}\n")

      { "gem_filename" => filename, "gem_sha256" => sha, "gem_size" => first.bytesize, "source_date_epoch" => epoch }
        .each { |k, v| @actions.output(k, v) }
      @actions.summary(<<~MD)
        ### Frozen gem

        | | |
        | --- | --- |
        #{metadata.map { |k, v| "| #{k} | `#{v}` |" }.join("\n")}

        Two builds were byte-identical. This SHA-256 is of the `.gem` file itself, not of the Actions artifact archive.
      MD
      metadata
    end

    def bundler_version
      require "bundler/version"
      Bundler::VERSION
    rescue LoadError
      "unavailable"
    end

    # 8. Audits the frozen gem: identity, dependencies against the tested
    #    matrix, metadata, packaged files (each byte-identical to the tagged
    #    commit) and secrets.
    def audit_package
      version = version_input
      commit = commit_input
      gem_path = @env.fetch("GEM_FILE")
      rubies = @env.fetch("AUDIT_RUBIES").split
      activejobs = @env.fetch("AUDIT_ACTIVEJOB").split

      package = Gem::Package.new(gem_path)
      begin
        package.verify
      rescue Gem::Package::FormatError, Gem::Security::Exception => e
        raise Failure, "#{gem_path} is not a valid gem: #{e.message}"
      end
      spec = package.spec
      problems = []
      problems << "name is #{spec.name}" unless spec.name == GEM_NAME
      problems << "version is #{spec.version}" unless spec.version.to_s == version
      problems << "platform is #{spec.platform}" unless spec.platform.to_s == "ruby"
      problems << "executables are #{spec.executables.inspect}" unless spec.executables == ["jobpayload"] && spec.bindir == "exe"
      problems << "licenses are #{spec.licenses.inspect}" unless spec.licenses == ["MIT"]
      problems << "require paths are #{spec.require_paths.inspect}" unless spec.require_paths == ["lib"]
      rubies.each do |ruby|
        problems << "required_ruby_version #{spec.required_ruby_version} excludes tested Ruby #{ruby}" unless spec.required_ruby_version.satisfied_by?(Gem::Version.new("#{ruby}.0"))
      end
      runtime = spec.runtime_dependencies
      problems << "runtime dependencies are #{runtime.map(&:to_s).inspect}, expected only activejob" unless runtime.map(&:name) == ["activejob"]
      activejob = runtime.find { |d| d.name == "activejob" }
      activejobs.each do |aj|
        problems << "activejob #{activejob&.requirement} excludes tested Active Job #{aj}" unless activejob&.requirement&.satisfied_by?(Gem::Version.new("#{aj}.0"))
      end
      problems << "development dependencies are packaged: #{spec.development_dependencies.map(&:to_s).inspect}" unless spec.development_dependencies.empty?

      metadata = spec.metadata
      problems << "metadata rubygems_mfa_required is #{metadata['rubygems_mfa_required'].inspect}" unless metadata["rubygems_mfa_required"] == "true"
      %w[homepage_uri source_code_uri changelog_uri].each do |key|
        problems << "metadata #{key} is #{metadata[key].inspect}" unless metadata[key].to_s.start_with?("https://github.com/#{REPOSITORY}")
      end
      problems << "metadata allowed_push_host is #{metadata['allowed_push_host'].inspect}" unless [nil, RUBYGEMS].include?(metadata["allowed_push_host"])

      entries = package_entries(gem_path)
      files = entries.keys
      problems << "spec.files does not match the packaged files" unless spec.files.sort == files.sort
      files.each do |path|
        problems << "unexpected packaged file #{path}" unless PACKAGE_FILE_PATTERNS.any? { |p| p.match?(path) }
        source = @git.blob(commit, path)
        problems << "#{path} is not byte-identical to #{commit}:#{path}" unless source == entries[path]
        SECRET_PATTERNS.each { |name, pattern| problems << "#{path} contains what looks like a #{name}" if pattern.match?(entries[path]) }
      end
      problems << "lib/jobpayload/version.rb is not packaged" unless files.include?("lib/jobpayload/version.rb")
      problems << "exe/jobpayload is not packaged" unless files.include?("exe/jobpayload")

      raise Failure, "package audit failed:\n" + problems.map { |p| "  - #{p}" }.join("\n") unless problems.empty?

      @actions.summary(<<~MD)
        ### Package audit

        `#{spec.full_name}`: #{files.size} files, each byte-identical to `#{commit}`; executable `jobpayload`;
        `required_ruby_version #{spec.required_ruby_version}`; `activejob #{activejob.requirement}`; license MIT;
        `rubygems_mfa_required`; no secrets found.
      MD
      @actions.log("package audit passed: #{files.size} files")
    end

    # Returns { path => content } for the files in the gem's data.tar.gz,
    # rejecting anything that is not a plain relative regular file.
    def package_entries(gem_path)
      entries = {}
      top = []
      File.open(gem_path, "rb") do |io|
        Gem::Package::TarReader.new(io).each do |entry|
          top << entry.full_name
          next unless entry.full_name == "data.tar.gz"

          Zlib::GzipReader.wrap(StringIO.new(entry.read)) do |gz|
            Gem::Package::TarReader.new(gz).each do |file|
              name = file.full_name
              raise Failure, "packaged entry #{name.inspect} is not a regular file" unless file.file?
              raise Failure, "packaged entry #{name.inspect} has an unsafe path" if name.start_with?("/") || name.split("/").include?("..")
              raise Failure, "packaged entry #{name.inspect} appears twice" if entries.key?(name)

              entries[name] = file.read.to_s.b
            end
          end
        end
      end
      raise Failure, "unexpected gem layout #{top.inspect}" unless top.sort == %w[checksums.yaml.gz data.tar.gz metadata.gz]

      entries
    end

    # 9. The file is the frozen gem: expected name, a regular file, the
    #    expected size and SHA-256.
    def verify_artifact
      path = File.join(@env.fetch("GEM_DIR"), filename_input)
      expected = sha_input
      size = @env.fetch_matching("GEM_SIZE", /\A[1-9][0-9]{0,9}\z/, "a size").to_i

      raise Failure, "#{path} is missing" unless File.exist?(path) || File.symlink?(path)
      raise Failure, "#{path} is not a regular file" if File.symlink?(path) || !File.file?(path)

      data = File.binread(path)
      raise Failure, "ARTIFACT SIZE MISMATCH: #{path} is #{data.bytesize} bytes, the frozen gem is #{size}" unless data.bytesize == size

      actual = ReleaseGuard.sha256_hex(data)
      raise Failure, "ARTIFACT SHA MISMATCH: #{path} has SHA-256 #{actual}, the frozen gem has #{expected}" unless actual == expected

      metadata_path = File.join(@env.fetch("GEM_DIR"), "release-metadata.json")
      if File.exist?(metadata_path)
        metadata = ReleaseGuard.parse_json(File.read(metadata_path), "release metadata")
        raise Failure, "release-metadata.json disagrees with the frozen gem" unless metadata["sha256"] == expected && metadata["size"] == size
      end

      @actions.output("gem_path", File.expand_path(path))
      @actions.log("#{File.basename(path)}: #{size} bytes, SHA-256 #{actual} (matches the frozen gem)")
      path
    end

    # 10. Re-checks everything right before `gem push`, after approval.
    def publish_preflight
      raise Failure, "RELEASE_GATE_READY is not \"true\" in the #{ENVIRONMENT} environment; publishing is disabled (docs/RELEASING.md)" unless @env["RELEASE_GATE_READY"] == "true"

      check_no_static_credentials
      tag = tag_input
      version = version_input
      raise Failure, "#{tag} does not match version #{version}" unless ReleaseGuard.version_from_tag(tag) == version

      verify_tag_unchanged
      main = @git.rev_parse("refs/release-guard/main")
      raise Failure, "#{commit_input} is no longer in the history of #{MAIN_BRANCH} (#{main})" unless @git.ok?("merge-base", "--is-ancestor", commit_input, main)

      state = @rubygems.state(version)
      raise Failure, "#{GEM_NAME} #{version} is already on RubyGems (SHA-256 #{state.sha256}); not pushing again" if state.present?

      # Approval may have waited a long time: the environment and the GitHub
      # release are checked again (a draft cannot be seen with this token).
      check_environment
      check_github_release_absent
      verify_artifact
      @actions.log("preflight passed: #{tag} -> #{commit_input}, #{GEM_NAME} #{version} not yet on RubyGems, frozen gem verified")
    end

    def verify_tag_unchanged
      tag = tag_input
      ref = remote_tag(tag)
      raise Failure, "#{tag} changed during the release: tag object #{ref[:object]}, expected #{tag_object_input}" unless ref[:object] == tag_object_input
      raise Failure, "#{tag} now points to #{ref[:commit]}, expected #{commit_input}" unless ref[:commit] == commit_input

      ref
    end

    def check_no_static_credentials
      set = STATIC_CREDENTIAL_VARIABLES.reject { |name| @env[name].to_s.empty? }
      raise Failure, "static RubyGems credentials are configured (#{set.join(', ')}); only Trusted Publishing is allowed" unless set.empty?
      raise Failure, "RUBYGEMS_HOST is #{@env['RUBYGEMS_HOST'].inspect}; gems are only pushed to #{RUBYGEMS}" unless [nil, "", RUBYGEMS].include?(@env["RUBYGEMS_HOST"])

      home = @env["HOME"].to_s
      files = [File.join(home, ".gem", "credentials"), File.join(home, ".local", "share", "gem", "credentials")]
      found = files.select { |f| File.exist?(f) }
      raise Failure, "a RubyGems credentials file exists (#{found.join(', ')}); only Trusted Publishing is allowed" unless found.empty?
    end

    # 11. After the OIDC exchange: a short-lived key is configured. Never prints it.
    def assert_oidc_credentials
      raise Failure, "no RubyGems credentials after the Trusted Publishing exchange; is the trusted publisher registered?" if @env["GEM_HOST_API_KEY"].to_s.empty?

      @actions.log("RubyGems credentials configured by Trusted Publishing")
    end

    # 12. gem push, once. On failure or timeout it reads RubyGems' state and
    #     says what to do; it never pushes again.
    def push(timeout: 480, settle: 90)
      path = verify_artifact
      version = version_input
      result = @runner.call(["gem", "push", File.expand_path(path)], chdir: @dir, timeout: timeout)
      @actions.log(result.output.gsub(/rubygems_[0-9a-f]{48}/, "[FILTERED]"))
      return @actions.log("gem push succeeded for #{File.basename(path)}") if result.success?

      what = result.timed_out ? "gem push timed out" : "gem push failed"
      # RubyGems' version APIs are cached for about a minute: let the answer
      # the preflight saw expire before reading the state again.
      @sleeper.call(settle)
      begin
        state = @rubygems.state(version)
      rescue Failure => e
        raise Failure, "#{what}, and RubyGems' state is unknown (#{e.message}). Do NOT push again; check RubyGems by hand (docs/RELEASING.md, 'Partial failures')"
      end

      unless state.present?
        raise Failure, "#{what}; RubyGems does not list #{GEM_NAME} #{version}, so it appears nothing was published. " \
                       "Fix the cause, then re-run the failed jobs (the publish job checks RubyGems again and asks for approval again)"
      end
      if state.sha256 == sha_input
        raise Failure, "#{what}, but RubyGems now has #{GEM_NAME} #{version} with the frozen SHA-256 #{state.sha256}. " \
                       "Do NOT push again; finish the release by hand (docs/RELEASING.md, 'Partial failures')"
      end

      raise Critical, "CRITICAL — PUBLISHED ARTIFACT MISMATCH: RubyGems has #{GEM_NAME} #{version} with SHA-256 #{state.sha256}, " \
                      "the frozen gem is #{sha_input}"
    end

    # 13. Downloads the published gem from rubygems.org and requires the
    #     frozen SHA-256, retrying (read-only, bounded) while it propagates.
    def verify_published(attempts: 12, interval: 30)
      version = version_input
      expected = sha_input
      last = nil
      attempts.times do |i|
        @sleeper.call(interval) if i.positive?
        begin
          response = @rubygems.download(version)
        rescue TransportError => e
          last = e.message
          next
        end

        case response.status
        when 200
          actual = ReleaseGuard.sha256_hex(response.body)
          raise Critical, "CRITICAL — PUBLISHED ARTIFACT MISMATCH: rubygems.org serves #{GEM_NAME}-#{version}.gem with SHA-256 #{actual}, the frozen gem is #{expected}" unless actual == expected

          api_sha = begin
            @rubygems.single_version(version)
          rescue TransportError => e
            last = e.message
            next
          end
          if api_sha.nil?
            last = "the version API does not list #{version} yet"
            next
          end
          raise Critical, "CRITICAL — PUBLISHED ARTIFACT MISMATCH: the RubyGems API reports SHA-256 #{api_sha}, the frozen gem is #{expected}" unless api_sha == expected

          @actions.output("published_sha256", actual)
          @actions.summary("### RubyGems\n\n`#{GEM_NAME}-#{version}.gem` downloaded from rubygems.org: SHA-256 `#{actual}`, identical to the frozen gem.")
          return @actions.log("published gem verified: SHA-256 #{actual} (attempt #{i + 1})")
        when 403, 404, 429, 500..599
          last = "HTTP #{response.status}"
        else
          raise Failure, "rubygems.org returned HTTP #{response.status} for #{GEM_NAME}-#{version}.gem"
        end
        @actions.log("attempt #{i + 1}/#{attempts}: not available yet (#{last})")
      end
      raise Failure, "could not verify the published gem after #{attempts} attempts (last: #{last}); the GitHub release was not created. " \
                     "Check by hand (docs/RELEASING.md, 'Partial failures'); do NOT push again"
    end

    # 14. Read-only report for a version that is already on RubyGems. Always
    #     fails: an existing version is never treated as a successful release.
    def diagnose_duplicate
      version = version_input
      state = @rubygems.state(version)
      raise Failure, "#{GEM_NAME} #{version} is not on RubyGems any more; re-run the whole workflow instead" unless state.present?

      if state.sha256 == sha_input
        raise Failure, "#{GEM_NAME} #{version} is already on RubyGems and is byte-identical to this build (SHA-256 #{state.sha256}). " \
                       "Nothing was published by this run. If its GitHub release is missing, create it by hand (docs/RELEASING.md, 'Partial failures')"
      end

      raise Critical, "CRITICAL — PUBLISHED ARTIFACT MISMATCH: #{GEM_NAME} #{version} on RubyGems has SHA-256 #{state.sha256}, " \
                      "but this build of #{commit_input} is #{sha_input}. Nothing was published by this run"
    end

    # 15. Creates the GitHub release for the existing tag with the committed
    #     release notes, after RubyGems has been verified.
    def create_github_release
      tag = tag_input
      version = version_input
      verify_tag_unchanged
      notes = release_notes(tag, commit_input)
      check_github_release_absent(include_drafts: true)

      state = @rubygems.state(version)
      raise Failure, "#{GEM_NAME} #{version} is not on RubyGems with the frozen SHA-256; not creating the GitHub release" unless state.present? && state.sha256 == sha_input

      Dir.mktmpdir("jobpayload-release-notes") do |dir|
        notes_path = File.join(dir, "#{tag}.md")
        File.write(notes_path, notes)
        argv = ["gh", "release", "create", tag, "--repo", REPOSITORY, "--verify-tag", "--title", version,
                "--notes-file", notes_path, "--draft=false", "--prerelease=false"]
        result = @runner.call(argv, chdir: @dir, timeout: 300)
        @actions.log(result.output)
        unless result.success?
          raise Failure, "creating the GitHub release failed. #{GEM_NAME} #{version} IS published on RubyGems and verified; " \
                         "do not push it again and do not move the tag. Re-run the failed jobs, or create the release by hand " \
                         "(docs/RELEASING.md, 'Partial failures')"
        end
      end
      @actions.log("GitHub release #{tag} created")
    end

    # 16. Final read-only verification of the whole release.
    def final_verify
      tag = tag_input
      version = version_input
      verify_tag_unchanged
      notes = release_notes(tag, commit_input)

      release = github.release_by_tag(tag)
      raise Failure, "the GitHub release for #{tag} does not exist" unless release

      problems = []
      problems << "it is a draft" unless release["draft"] == false
      problems << "it is a prerelease" unless release["prerelease"] == false
      problems << "its title is #{release['name'].inspect}" unless release["name"] == version
      problems << "its notes differ from docs/releases/#{tag}.md" unless release["body"].to_s.gsub("\r\n", "\n").strip == notes.gsub("\r\n", "\n").strip
      raise Failure, "the GitHub release for #{tag} is wrong: #{problems.join('; ')}" unless problems.empty?

      sha = @rubygems.single_version(version)
      raise Critical, "CRITICAL — PUBLISHED ARTIFACT MISMATCH: RubyGems reports #{sha.inspect}, the frozen gem is #{sha_input}" unless sha == sha_input

      @actions.summary(<<~MD)
        ### Release #{tag} complete

        | | |
        | --- | --- |
        | RubyGems | https://rubygems.org/gems/#{GEM_NAME}/versions/#{version} |
        | SHA-256 | `#{sha}` |
        | GitHub release | #{release['html_url']} |
        | Tag | `#{tag}` → `#{commit_input}` |
      MD
      @actions.log("release #{tag} verified")
    end

    private

    def tag_input = @env.fetch_matching("RELEASE_TAG", TAG_PATTERN, "a release tag")
    def version_input = @env.fetch_matching("RELEASE_VERSION", VERSION_PATTERN, "a version")
    def commit_input = @env.fetch_matching("RELEASE_COMMIT", SHA1, "a commit SHA")
    def tag_object_input = @env.fetch_matching("RELEASE_TAG_OBJECT", SHA1, "a tag object SHA")
    def sha_input = @env.fetch_matching("GEM_SHA256", SHA256, "a SHA-256")

    def filename_input
      name = @env.fetch("GEM_FILENAME")
      raise Failure, "GEM_FILENAME is #{name.inspect}, expected #{GEM_NAME}-#{version_input}.gem" unless name == "#{GEM_NAME}-#{version_input}.gem"

      name
    end
  end

  COMMANDS = {
    "validate-tag" => :validate_tag,
    "check-spec" => :check_spec,
    "check-environment" => :check_environment,
    "check-github-release-absent" => :check_github_release_absent,
    "rubygems-state" => :rubygems_state,
    "audit-skips" => :audit_skips,
    "build" => :build,
    "audit-package" => :audit_package,
    "verify-artifact" => :verify_artifact,
    "publish-preflight" => :publish_preflight,
    "assert-oidc-credentials" => :assert_oidc_credentials,
    "push" => :push,
    "verify-published" => :verify_published,
    "diagnose-duplicate" => :diagnose_duplicate,
    "create-github-release" => :create_github_release,
    "final-verify" => :final_verify
  }.freeze

  def main(argv, guard: Guard.new, err: $stderr)
    command = argv.first
    method = COMMANDS[command]
    unless method && argv.size == 1
      err.puts("usage: release_guard.rb <#{COMMANDS.keys.join('|')}>")
      return 64
    end

    guard.public_send(method)
    0
  rescue Failure => e
    err.puts("::error title=release guard (#{command})::#{Actions.escape_command(e.message)}")
    1
  end
end

exit ReleaseGuard.main(ARGV) if $PROGRAM_NAME == __FILE__
