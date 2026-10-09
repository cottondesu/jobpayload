# frozen_string_literal: true

# Tests for script/release/release_guard.rb, the checks behind
# .github/workflows/release.yml. Nothing here talks to RubyGems or GitHub:
# HTTP is stubbed, gem push and gh are stubbed, and tags only ever exist in
# temporary repositories.

require "minitest/autorun"
require "digest"
require "fileutils"
require "json"
require "open3"
require "stringio"
require "tempfile"
require "tmpdir"
require "yaml"

require_relative "../../script/release/release_guard"

module ReleaseGuardTestSupport
  ROOT = File.expand_path("../..", __dir__)
  WORKFLOW = File.join(ROOT, ".github/workflows/release.yml")

  # Isolated from the user's and the system's git configuration.
  GIT_ENV = {
    "GIT_CONFIG_GLOBAL" => File::NULL,
    "GIT_CONFIG_NOSYSTEM" => "1",
    "GIT_AUTHOR_NAME" => "Release Test",
    "GIT_AUTHOR_EMAIL" => "release-test@example.invalid",
    "GIT_COMMITTER_NAME" => "Release Test",
    "GIT_COMMITTER_EMAIL" => "release-test@example.invalid",
    "GIT_TERMINAL_PROMPT" => "0"
  }.freeze

  # Child processes must not inherit `bundle exec` from the test run.
  CLEAN_RUBY_ENV = { "RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil,
                     "BUNDLER_SETUP" => nil, "BUNDLER_VERSION" => nil }.freeze

  RUBYGEMS_V1 = "https://rubygems.org/api/v1/versions/jobpayload.json"

  def self.v2_url(version) = "https://rubygems.org/api/v2/rubygems/jobpayload/versions/#{version}.json"
  def self.download_url(version) = "https://rubygems.org/downloads/jobpayload-#{version}.gem"
  def self.github_url(path) = "https://api.github.com/repos/cottondesu/jobpayload#{path}"

  R = ReleaseGuard::Response

  # Routes URLs to responses. A route may be a Response, an exception class or
  # instance, a Proc, or an Array consumed one element per request.
  class FakeHTTP
    attr_reader :requests

    def initialize(routes = {})
      @routes = routes
      @requests = []
    end

    def route(url, value)
      @routes[url] = value
      self
    end

    def get(url, headers: {}, redirects: 0, allowed_hosts: nil)
      @requests << [url, headers]
      raise "unexpected request #{url}" unless @routes.key?(url)

      value = @routes[url]
      value = value.length > 1 ? value.shift : value.first if value.is_a?(Array)
      value = value.call if value.is_a?(Proc)
      raise value if value.is_a?(Exception) || (value.is_a?(Class) && value <= Exception)

      value
    end
  end

  # Real processes for git and gem build; gem push and gh are stubbed.
  class FakeRunner < ReleaseGuard::Runner
    attr_reader :calls

    def initialize(stubs = {})
      super()
      @stubs = stubs
      @calls = []
    end

    def call(argv, env: {}, chdir: Dir.pwd, timeout: nil)
      key = argv.first(2).join(" ")
      key = "gh" if argv.first == "gh"
      if @stubs.key?(key)
        @calls << argv
        stub = @stubs[key]
        return stub.respond_to?(:call) ? stub.call(argv) : stub
      end
      super(argv, env: CLEAN_RUBY_ENV.merge(env), chdir: chdir, timeout: timeout)
    end
  end

  FakeStatus = Struct.new(:success?)

  def self.status(success) = FakeStatus.new(success)

  OK = ReleaseGuard::ProcessResult.new(status: status(true), output: "ok\n", timed_out: false)
  FAILED = ReleaseGuard::ProcessResult.new(status: status(false), output: "error\n", timed_out: false)
  TIMED_OUT = ReleaseGuard::ProcessResult.new(status: status(false), output: "", timed_out: true)

  def git(dir, *args)
    out, status = Open3.capture2e(GIT_ENV, "git", *args, chdir: dir)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?

    out
  end

  # A bare "origin" with main and (unless tag: nil) an annotated tag, and a
  # clone checked out at the tag, as actions/checkout would leave it.
  def release_repo(version: "0.3.0", tag: "v#{version}", annotated: true, notes: "# jobpayload v#{version}\n\nNotes.\n",
                   version_constant: version)
    root = Dir.mktmpdir("release-guard-test")
    @tmpdirs << root
    origin = File.join(root, "origin.git")
    work = File.join(root, "work")
    checkout = File.join(root, "checkout")
    git(root, "init", "--quiet", "--bare", "-b", "main", origin)
    git(root, "init", "--quiet", "-b", "main", work)

    %w[jobpayload.gemspec README.md CHANGELOG.md LICENSE].each { |f| FileUtils.cp(File.join(ROOT, f), work) }
    FileUtils.cp_r(File.join(ROOT, "lib"), work)
    FileUtils.cp_r(File.join(ROOT, "exe"), work)
    File.write(File.join(work, "lib/jobpayload/version.rb"),
               "# frozen_string_literal: true\n\nmodule JobPayload\n  VERSION = \"#{version_constant}\"\nend\n")
    if notes
      FileUtils.mkdir_p(File.join(work, "docs/releases"))
      File.write(File.join(work, "docs/releases/#{tag || "v#{version}"}.md"), notes)
    end
    git(work, "add", "-A")
    git(work, "commit", "--quiet", "-m", "Release #{version}")
    git(work, "remote", "add", "origin", origin)
    git(work, "push", "--quiet", "origin", "main")
    if tag
      annotated ? git(work, "tag", "-a", tag, "-m", "Release #{tag}") : git(work, "tag", tag)
      git(work, "push", "--quiet", "origin", "refs/tags/#{tag}")
    end
    git(root, "clone", "--quiet", origin, checkout)
    commit = git(work, "rev-parse", "HEAD").strip
    git(checkout, "checkout", "--quiet", "--detach", commit)
    { root: root, origin: origin, work: work, checkout: checkout, commit: commit, tag: tag, version: version }
  end

  def github_env(repo, **overrides)
    {
      "GITHUB_EVENT_NAME" => "push",
      "GITHUB_REF_TYPE" => "tag",
      "GITHUB_REF" => "refs/tags/#{repo[:tag]}",
      "GITHUB_REF_NAME" => repo[:tag],
      "GITHUB_REPOSITORY" => "cottondesu/jobpayload",
      "GITHUB_REPOSITORY_ID" => "1402924325",
      "GITHUB_SHA" => repo[:commit],
      "GITHUB_ACTOR" => "cottondesu"
    }.merge(overrides.transform_keys(&:to_s))
  end

  def guard(env: {}, dir: Dir.pwd, http: FakeHTTP.new, runner: FakeRunner.new, sleeper: nil)
    @out = StringIO.new
    @sleeps = []
    ReleaseGuard::Guard.new(env: env, dir: dir, runner: runner, http: http, actions: ReleaseGuard::Actions.new({}, out: @out),
                            sleeper: sleeper || ->(s) { @sleeps << s }, git_env: GIT_ENV)
  end

  def rubygems(version, sha: nil, v1: :auto, v2: :auto)
    listed = [{ "number" => "0.2.0", "platform" => "ruby", "sha" => "a" * 64 }]
    listed << { "number" => version, "platform" => "ruby", "sha" => sha } if sha
    v1 = R.new(status: 200, body: JSON.generate(listed)) if v1 == :auto
    if v2 == :auto
      v2 = sha ? R.new(status: 200, body: JSON.generate("number" => version, "platform" => "ruby", "sha" => sha)) : R.new(status: 404, body: "This version could not be found.")
    end
    FakeHTTP.new(RUBYGEMS_V1 => v1, ReleaseGuardTestSupport.v2_url(version) => v2)
  end

  def assert_fails(pattern, klass = ReleaseGuard::Failure, &block)
    error = assert_raises(klass, &block)
    assert_match pattern, error.message
    error
  end
end

class ReleaseGuardTagTest < Minitest::Test
  include ReleaseGuardTestSupport

  def setup = @tmpdirs = []
  def teardown = @tmpdirs.each { |d| FileUtils.rm_rf(d) }

  def test_release_tag_format
    %w[v0.2.1 v0.3.0 v1.0.0 v10.20.30].each { |t| assert_equal t.delete_prefix("v"), ReleaseGuard.version_from_tag(t) }
    ["v0.2", "v0.2.1-beta", "vtest", "0.2.1", "v01.2.3", "v1.2.3.4", "v1.2.3\n", "v1.2.3 ", "V1.2.3", "v1.2.3+build",
     "v$(id).0.0", "v1.2.3;rm", ""].each do |t|
      assert_fails(/not a release tag/) { ReleaseGuard.version_from_tag(t) }
    end
  end

  def test_valid_annotated_tag_at_head_of_main
    repo = release_repo
    g = guard(env: github_env(repo), dir: repo[:checkout])
    g.validate_tag
    out = @out.string
    assert_includes out, "tag=v0.3.0\n"
    assert_includes out, "version=0.3.0\n"
    assert_includes out, "commit=#{repo[:commit]}\n"
    assert_match(/^tag_object=[0-9a-f]{40}$/, out)
    refute_includes out, "tag_object=#{repo[:commit]}"
  end

  def test_invalid_tag_format_is_rejected_before_git
    repo = release_repo(tag: "v0.3.0")
    env = github_env(repo, GITHUB_REF_NAME: "v0.3", GITHUB_REF: "refs/tags/v0.3")
    assert_fails(/not a release tag/) { guard(env: env, dir: repo[:checkout]).validate_tag }
  end

  def test_lightweight_tag_is_rejected
    repo = release_repo(annotated: false)
    assert_fails(/lightweight tag/) { guard(env: github_env(repo), dir: repo[:checkout]).validate_tag }
  end

  def test_wrong_repository_is_rejected
    repo = release_repo
    assert_fails(/not cottondesu\/jobpayload/) { guard(env: github_env(repo, GITHUB_REPOSITORY: "someone/jobpayload"), dir: repo[:checkout]).validate_tag }
    assert_fails(/repository id/) { guard(env: github_env(repo, GITHUB_REPOSITORY_ID: "1"), dir: repo[:checkout]).validate_tag }
  end

  def test_only_tag_pushes_are_accepted
    repo = release_repo
    assert_fails(/not a tag push/) { guard(env: github_env(repo, GITHUB_EVENT_NAME: "workflow_dispatch"), dir: repo[:checkout]).validate_tag }
    assert_fails(/not tag/) { guard(env: github_env(repo, GITHUB_REF_TYPE: "branch"), dir: repo[:checkout]).validate_tag }
    assert_fails(/GITHUB_REF/) { guard(env: github_env(repo, GITHUB_REF: "refs/heads/v0.3.0"), dir: repo[:checkout]).validate_tag }
  end

  def test_tag_on_an_old_commit_is_rejected
    repo = release_repo
    File.write(File.join(repo[:work], "README.md"), "changed after tagging\n", mode: "a")
    git(repo[:work], "commit", "--quiet", "-am", "later change")
    git(repo[:work], "push", "--quiet", "origin", "main")
    assert_fails(/but main is at/) { guard(env: github_env(repo), dir: repo[:checkout]).validate_tag }
  end

  def test_run_for_a_different_commit_is_rejected
    repo = release_repo
    assert_fails(/triggered for/) { guard(env: github_env(repo, GITHUB_SHA: "0" * 40), dir: repo[:checkout]).validate_tag }
  end

  def test_tag_of_a_tag_is_rejected
    repo = release_repo
    git(repo[:work], "tag", "-a", "inner", "-m", "inner")
    git(repo[:work], "tag", "-a", "v0.3.1", "inner", "-m", "nested")
    git(repo[:work], "push", "--quiet", "origin", "refs/tags/v0.3.1")
    env = github_env(repo, GITHUB_REF_NAME: "v0.3.1", GITHUB_REF: "refs/tags/v0.3.1")
    assert_fails(/does not point to a commit/) { guard(env: env, dir: repo[:checkout]).validate_tag }
  end

  def test_missing_release_notes_are_rejected
    repo = release_repo(notes: nil)
    assert_fails(%r{docs/releases/v0.3.0.md is missing}) { guard(env: github_env(repo), dir: repo[:checkout]).validate_tag }
  end

  def test_release_notes_for_another_version_are_rejected
    repo = release_repo(notes: "# jobpayload v0.2.0\n")
    assert_fails(/must start with a heading naming v0.3.0/) { guard(env: github_env(repo), dir: repo[:checkout]).validate_tag }
  end

  def test_tag_and_version_must_match
    repo = release_repo(version: "0.3.0", version_constant: "0.2.9")
    assert_fails(/JobPayload::VERSION is "0.2.9", but the tag is v0.3.0/) do
      guard(env: { "RELEASE_VERSION" => "0.3.0" }, dir: repo[:checkout]).check_spec
    end
    guard(env: { "RELEASE_VERSION" => "0.2.9" }, dir: repo[:checkout]).check_spec
    assert_includes @out.string, "agree with the tag"
  end

  def test_tag_moved_before_publishing_is_rejected
    repo = release_repo
    g = guard(env: github_env(repo), dir: repo[:checkout])
    g.validate_tag
    tag_object = @out.string[/^tag_object=(\h+)$/, 1]
    git(repo[:work], "tag", "-f", "-a", "v0.3.0", "-m", "moved")
    git(repo[:work], "push", "--quiet", "--force", "origin", "refs/tags/v0.3.0")

    env = { "RELEASE_TAG" => "v0.3.0", "RELEASE_VERSION" => "0.3.0", "RELEASE_COMMIT" => repo[:commit], "RELEASE_TAG_OBJECT" => tag_object }
    assert_fails(/changed during the release/) { guard(env: env, dir: repo[:checkout]).verify_tag_unchanged }
  end
end

class ReleaseGuardRemoteStateTest < Minitest::Test
  include ReleaseGuardTestSupport

  def setup = @tmpdirs = []
  def teardown = @tmpdirs.each { |d| FileUtils.rm_rf(d) }

  def test_rubygems_absent_and_present
    g = guard(env: { "RELEASE_VERSION" => "0.3.0" }, http: rubygems("0.3.0"))
    assert_equal :absent, g.rubygems_state.state
    assert_includes @out.string, "rubygems_state=absent"

    g = guard(env: { "RELEASE_VERSION" => "0.3.0" }, http: rubygems("0.3.0", sha: "b" * 64))
    state = g.rubygems_state
    assert_equal [:present, "b" * 64], [state.state, state.sha256]
    assert_includes @out.string, "rubygems_state=present"
  end

  def test_rubygems_api_failures_never_mean_absent
    cases = {
      "HTTP 500" => rubygems("0.3.0", v1: R.new(status: 500, body: "")),
      "invalid JSON" => rubygems("0.3.0", v1: R.new(status: 200, body: "[{\"number\":")),
      "unexpected document" => rubygems("0.3.0", v1: R.new(status: 200, body: "{}")),
      "empty list" => rubygems("0.3.0", v1: R.new(status: 200, body: "[]")),
      "version API HTTP 503" => rubygems("0.3.0", v2: R.new(status: 503, body: "")),
      "version API garbage" => rubygems("0.3.0", v2: R.new(status: 200, body: "<html>")),
      "disagreement" => rubygems("0.3.0", v2: R.new(status: 200, body: JSON.generate("number" => "0.3.0", "platform" => "ruby", "sha" => "c" * 64))),
      "timeout" => FakeHTTP.new(RUBYGEMS_V1 => ReleaseGuard::TransportError.new("rubygems.org: Net::ReadTimeout"))
    }
    cases.each do |name, http|
      g = guard(env: { "RELEASE_VERSION" => "0.3.0" }, http: http)
      assert_raises(ReleaseGuard::Failure, name) { g.rubygems_state }
      refute_includes @out.string, "rubygems_state=absent", name
    end
  end

  def test_github_release_absent_present_and_errors
    url = ReleaseGuardTestSupport.github_url("/releases/tags/v0.3.0")
    env = { "RELEASE_TAG" => "v0.3.0", "GH_TOKEN" => "token-value" }
    http = FakeHTTP.new(url => R.new(status: 404, body: "{}"))
    guard(env: env, http: http).check_github_release_absent
    assert_equal "Bearer token-value", http.requests.first[1]["Authorization"]

    present = FakeHTTP.new(url => R.new(status: 200, body: JSON.generate("tag_name" => "v0.3.0")))
    assert_fails(/already exists/) { guard(env: env, http: present).check_github_release_absent }

    error = FakeHTTP.new(url => R.new(status: 502, body: ""))
    assert_fails(/HTTP 502/) { guard(env: env, http: error).check_github_release_absent }
  end

  def test_draft_release_counts_as_existing
    http = FakeHTTP.new(
      ReleaseGuardTestSupport.github_url("/releases/tags/v0.3.0") => R.new(status: 404, body: "{}"),
      ReleaseGuardTestSupport.github_url("/releases?per_page=100&page=1") => R.new(status: 200, body: JSON.generate([{ "tag_name" => "v0.3.0", "draft" => true }]))
    )
    assert_fails(/already exists \(draft\); delete the draft, then re-run the failed jobs/) do
      guard(env: { "RELEASE_TAG" => "v0.3.0" }, http: http).check_github_release_absent(include_drafts: true)
    end
  end
end

class ReleaseGuardEnvironmentTest < Minitest::Test
  include ReleaseGuardTestSupport

  ENV_URL = ReleaseGuardTestSupport.github_url("/environments/release")
  POLICY_URL = ReleaseGuardTestSupport.github_url("/environments/release/deployment-branch-policies?per_page=100")

  def environment(reviewers: [{ "type" => "User", "reviewer" => { "login" => "cottondesu" } }], prevent_self_review: false,
                  policy: { "protected_branches" => false, "custom_branch_policies" => true })
    rules = reviewers ? [{ "type" => "required_reviewers", "prevent_self_review" => prevent_self_review, "reviewers" => reviewers }] : []
    R.new(status: 200, body: JSON.generate("name" => "release", "can_admins_bypass" => false, "protection_rules" => rules,
                                           "deployment_branch_policy" => policy))
  end

  def policies(*list)
    R.new(status: 200, body: JSON.generate("total_count" => list.size, "branch_policies" => list))
  end

  def check(env_response, policy_response = policies({ "name" => "v*", "type" => "tag" }), env: {})
    http = FakeHTTP.new(ENV_URL => env_response, POLICY_URL => policy_response)
    guard(env: { "GITHUB_ACTOR" => "cottondesu" }.merge(env), http: http).check_environment
  end

  def test_protected_environment_passes
    check(environment)
    refute_includes @out.string, "::warning::"
  end

  def test_missing_environment_fails
    assert_fails(/does not exist/) { check(R.new(status: 404, body: "{}")) }
  end

  def test_environment_api_error_fails
    assert_fails(/HTTP 403/) { check(R.new(status: 403, body: "{}")) }
  end

  def test_environment_without_reviewers_fails
    assert_fails(/no required reviewers/) { check(environment(reviewers: nil)) }
    assert_fails(/no required reviewers/) { check(environment(reviewers: [])) }
  end

  def test_environment_open_to_all_refs_fails
    assert_fails(/any branch or tag/) { check(environment(policy: nil)) }
    assert_fails(/protected branches/) { check(environment(policy: { "protected_branches" => true, "custom_branch_policies" => false })) }
  end

  def test_environment_must_allow_only_release_tags
    assert_fails(/no deployment tag rule/) { check(environment, policies) }
    assert_fails(/branch main/) { check(environment, policies({ "name" => "v*", "type" => "tag" }, { "name" => "main", "type" => "branch" })) }
    assert_fails(/tag \*/) { check(environment, policies({ "name" => "*", "type" => "tag" })) }
  end

  def test_self_review_prevention_with_a_solo_reviewer_fails
    assert_fails(/nobody could approve/) { check(environment(prevent_self_review: true)) }
    check(environment(prevent_self_review: true), env: { "GITHUB_ACTOR" => "someone-else" })
  end

  def test_gate_flag_outside_the_environment_fails
    assert_fails(/visible outside the release environment/) { check(environment, env: { "REPO_LEVEL_GATE" => "true" }) }
  end
end

class ReleaseGuardSkipAuditTest < Minitest::Test
  include ReleaseGuardTestSupport

  def audit(log, platform)
    Tempfile.create("test-log") do |f|
      f.write(log)
      f.flush
      guard(env: { "TEST_LOG" => f.path, "TEST_PLATFORM" => platform }).audit_skips
    end
  end

  def log(skips, failures: 0, errors: 0)
    details = skips.each_with_index.map { |(name, message), i| "  #{i + 1}) Skipped:\n#{name} [test/x_test.rb:1]:\n#{message}\n" }.join("\n")
    "Run options: --verbose --seed 1\n\n# Running:\n\n#{details}\n196 runs, 1000 assertions, #{failures} failures, #{errors} errors, #{skips.size} skips\n"
  end

  CROSS = ["CrossVersionTest#test_active_job_8_1_payloads_on_v1", "active_job_8.1 is newer than activejob 7.2"].freeze
  NON_UTF8 = ["CLITest#test_non_utf8", "filesystem does not support non-UTF-8 directory names: Errno::EILSEQ (\"Illegal byte sequence\") creating \"out\\xFF\""].freeze

  def test_expected_skips_pass
    audit(log([CROSS]), "linux")
    audit(log([CROSS, NON_UTF8]), "macos")
    audit(log([]), "linux")
  end

  def test_unexpected_skips_fail
    assert_fails(/unexpected skips on linux/) { audit(log([NON_UTF8]), "linux") }
    assert_fails(/unexpected skips on macos/) { audit(log([["FooTest#test_bar", "not implemented yet"]]), "macos") }
    assert_fails(/unexpected skips/) { audit(log([["CrossVersionTest#x", "active_job_7.2 is newer than activejob 8.1"]]), "linux") }
  end

  def test_test_failures_fail
    assert_fails(/1 failures and 0 errors/) { audit(log([], failures: 1), "linux") }
    assert_fails(/no minitest summary/) { audit("Interrupted\n", "linux") }
    assert_fails(/but 0 skip details/) { audit("196 runs, 1 assertions, 0 failures, 0 errors, 2 skips\n", "linux") }
  end
end

class ReleaseGuardBuildTest < Minitest::Test
  include ReleaseGuardTestSupport

  def setup = @tmpdirs = []
  def teardown = @tmpdirs.each { |d| FileUtils.rm_rf(d) }

  def build_env(repo, out)
    { "RELEASE_TAG" => repo[:tag], "RELEASE_VERSION" => repo[:version], "RELEASE_COMMIT" => repo[:commit], "OUTPUT_DIR" => out }
  end

  def build(repo)
    out = File.join(repo[:root], "out")
    metadata = guard(env: build_env(repo, out), dir: repo[:checkout]).build
    [out, metadata]
  end

  def audit_env(repo, gem_path, commit: repo[:commit])
    { "RELEASE_VERSION" => repo[:version], "RELEASE_COMMIT" => commit, "GEM_FILE" => gem_path,
      "AUDIT_RUBIES" => "3.3 3.4 4.0", "AUDIT_ACTIVEJOB" => "7.2 8.0 8.1" }
  end

  def test_reproducible_build_and_package_audit
    repo = release_repo
    out, metadata = build(repo)
    gem_path = File.join(out, "jobpayload-0.3.0.gem")
    data = File.binread(gem_path)

    assert_equal Digest::SHA256.hexdigest(data), metadata["sha256"]
    assert_equal data.bytesize, metadata["size"]
    assert_equal repo[:commit], metadata["source_commit"]
    assert_equal git(repo[:checkout], "log", "-1", "--format=%ct").to_i, metadata["source_date_epoch"]
    assert_equal metadata, JSON.parse(File.read(File.join(out, "release-metadata.json")))
    %w[ruby rubygems bundler source_tree build_command].each { |k| refute_nil metadata[k], k }
    assert_includes @out.string, "gem_sha256=#{metadata['sha256']}"

    guard(env: audit_env(repo, gem_path), dir: repo[:checkout]).audit_package
    assert_includes @out.string, "package audit passed"
  end

  def test_reproducibility_mismatch_fails
    repo = release_repo
    builder = ->(path) { File.binwrite(path, Random.bytes(64)) }
    assert_fails(/REPRODUCIBILITY MISMATCH/) do
      guard(env: build_env(repo, File.join(repo[:root], "out")), dir: repo[:checkout]).build(builder: builder)
    end
    refute File.exist?(File.join(repo[:root], "out", "jobpayload-0.3.0.gem"))
  end

  def test_build_failure_fails
    repo = release_repo
    File.write(File.join(repo[:work], "jobpayload.gemspec"), "raise 'broken gemspec'\n")
    git(repo[:work], "commit", "--quiet", "-am", "break the gemspec")
    commit = git(repo[:work], "rev-parse", "HEAD").strip
    git(repo[:work], "push", "--quiet", "origin", "main")
    git(repo[:checkout], "fetch", "--quiet", "origin")
    git(repo[:checkout], "checkout", "--quiet", "--detach", commit)
    assert_fails(/gem build failed/) { guard(env: build_env(repo.merge(commit: commit), File.join(repo[:root], "out")), dir: repo[:checkout]).build }
  end

  def test_dirty_checkout_fails
    repo = release_repo
    File.write(File.join(repo[:checkout], "lib/jobpayload/extra.rb"), "# not committed\n")
    assert_fails(/local changes/) { build(repo) }
  end

  def test_package_with_unexpected_or_secret_content_fails
    repo = release_repo
    fake_key = "rubygems_#{'0' * 48}" # built at run time so no scanner sees a literal key
    File.write(File.join(repo[:work], "lib/jobpayload/leak.rb"), "# #{fake_key}\n")
    git(repo[:work], "add", "-A")
    git(repo[:work], "commit", "--quiet", "-m", "leak")
    git(repo[:work], "push", "--quiet", "origin", "main")
    commit = git(repo[:work], "rev-parse", "HEAD").strip
    git(repo[:checkout], "fetch", "--quiet", "origin")
    git(repo[:checkout], "checkout", "--quiet", "--detach", commit)
    repo = repo.merge(commit: commit)
    out, = build(repo)
    gem_path = File.join(out, "jobpayload-0.3.0.gem")

    assert_fails(/leak\.rb contains what looks like a RubyGems API key/) { guard(env: audit_env(repo, gem_path), dir: repo[:checkout]).audit_package }
    # The same gem audited against an older commit: files differ from the source.
    first = git(repo[:work], "rev-parse", "HEAD~1").strip
    assert_fails(/not byte-identical/) { guard(env: audit_env(repo, gem_path, commit: first), dir: repo[:checkout]).audit_package }
  end

  def test_package_outside_the_tested_matrix_fails
    repo = release_repo
    out, = build(repo)
    env = audit_env(repo, File.join(out, "jobpayload-0.3.0.gem")).merge("AUDIT_RUBIES" => "3.2 3.3", "AUDIT_ACTIVEJOB" => "7.1 8.1")
    error = assert_fails(/package audit failed/) { guard(env: env, dir: repo[:checkout]).audit_package }
    assert_includes error.message, "excludes tested Ruby 3.2"
    assert_includes error.message, "excludes tested Active Job 7.1"
  end
end

class ReleaseGuardArtifactTest < Minitest::Test
  include ReleaseGuardTestSupport

  def setup
    @dir = Dir.mktmpdir("release-guard-artifact")
    @data = "frozen gem bytes".b
    @sha = Digest::SHA256.hexdigest(@data)
    File.binwrite(File.join(@dir, "jobpayload-0.3.0.gem"), @data)
  end

  def teardown = FileUtils.rm_rf(@dir)

  def env(**overrides)
    { "RELEASE_VERSION" => "0.3.0", "GEM_DIR" => @dir, "GEM_FILENAME" => "jobpayload-0.3.0.gem", "GEM_SHA256" => @sha,
      "GEM_SIZE" => @data.bytesize.to_s }.merge(overrides.transform_keys(&:to_s))
  end

  def test_frozen_artifact_passes
    guard(env: env).verify_artifact
    assert_includes @out.string, "gem_path=#{File.join(@dir, 'jobpayload-0.3.0.gem')}"
  end

  def test_sha_mismatch_fails
    assert_fails(/ARTIFACT SHA MISMATCH/) { guard(env: env(GEM_SHA256: "f" * 64)).verify_artifact }
  end

  def test_size_mismatch_fails
    assert_fails(/ARTIFACT SIZE MISMATCH/) { guard(env: env(GEM_SIZE: "1")).verify_artifact }
  end

  def test_wrong_name_missing_file_and_symlink_fail
    assert_fails(/GEM_FILENAME/) { guard(env: env(GEM_FILENAME: "../jobpayload-0.3.0.gem")).verify_artifact }
    FileUtils.mv(File.join(@dir, "jobpayload-0.3.0.gem"), File.join(@dir, "real.gem"))
    assert_fails(/is missing/) { guard(env: env).verify_artifact }
    File.symlink(File.join(@dir, "real.gem"), File.join(@dir, "jobpayload-0.3.0.gem"))
    assert_fails(/not a regular file/) { guard(env: env).verify_artifact }
  end

  def test_metadata_disagreement_fails
    File.write(File.join(@dir, "release-metadata.json"), JSON.generate("sha256" => "e" * 64, "size" => @data.bytesize))
    assert_fails(/release-metadata.json disagrees/) { guard(env: env).verify_artifact }
  end
end

class ReleaseGuardPublishTest < Minitest::Test
  include ReleaseGuardTestSupport

  def setup
    @tmpdirs = []
    @repo = release_repo
    guard(env: github_env(@repo), dir: @repo[:checkout]).validate_tag
    @tag_object = @out.string[/^tag_object=(\h+)$/, 1]
    @gem_dir = File.join(@repo[:root], "gem")
    FileUtils.mkdir_p(@gem_dir)
    @data = "frozen gem bytes".b
    @sha = Digest::SHA256.hexdigest(@data)
    File.binwrite(File.join(@gem_dir, "jobpayload-0.3.0.gem"), @data)
  end

  def teardown = @tmpdirs.each { |d| FileUtils.rm_rf(d) }

  def env(**overrides)
    { "RELEASE_GATE_READY" => "true", "RELEASE_TAG" => "v0.3.0", "RELEASE_VERSION" => "0.3.0", "RELEASE_COMMIT" => @repo[:commit],
      "RELEASE_TAG_OBJECT" => @tag_object, "GEM_DIR" => @gem_dir, "GEM_FILENAME" => "jobpayload-0.3.0.gem", "GEM_SHA256" => @sha,
      "GEM_SIZE" => @data.bytesize.to_s, "HOME" => @repo[:root] }.merge(overrides.transform_keys(&:to_s))
  end

  def protected_github(http, release: R.new(status: 404, body: "{}"), reviewers: [{ "type" => "User", "reviewer" => { "login" => "cottondesu" } }])
    environment = { "protection_rules" => [{ "type" => "required_reviewers", "prevent_self_review" => false, "reviewers" => reviewers }],
                    "deployment_branch_policy" => { "protected_branches" => false, "custom_branch_policies" => true } }
    http.route(ReleaseGuardTestSupport.github_url("/environments/release"), R.new(status: 200, body: JSON.generate(environment)))
        .route(ReleaseGuardTestSupport.github_url("/environments/release/deployment-branch-policies?per_page=100"),
               R.new(status: 200, body: JSON.generate("branch_policies" => [{ "name" => "v*", "type" => "tag" }])))
        .route(ReleaseGuardTestSupport.github_url("/releases/tags/v0.3.0"), release)
  end

  def test_preflight_passes
    guard(env: env, dir: @repo[:checkout], http: protected_github(rubygems("0.3.0"))).publish_preflight
    assert_includes @out.string, "preflight passed"
  end

  def test_preflight_rechecks_the_environment_and_the_github_release
    assert_fails(/no required reviewers/) do
      guard(env: env, dir: @repo[:checkout], http: protected_github(rubygems("0.3.0"), reviewers: [])).publish_preflight
    end
    released = R.new(status: 200, body: JSON.generate("tag_name" => "v0.3.0"))
    assert_fails(/already exists/) do
      guard(env: env, dir: @repo[:checkout], http: protected_github(rubygems("0.3.0"), release: released)).publish_preflight
    end
  end

  def test_missing_gate_fails
    assert_fails(/RELEASE_GATE_READY/) { guard(env: env(RELEASE_GATE_READY: nil), dir: @repo[:checkout]).publish_preflight }
    assert_fails(/RELEASE_GATE_READY/) { guard(env: env(RELEASE_GATE_READY: "yes"), dir: @repo[:checkout]).publish_preflight }
  end

  def test_static_credentials_fail
    assert_fails(/static RubyGems credentials/) { guard(env: env(GEM_HOST_API_KEY: "x"), dir: @repo[:checkout]).publish_preflight }
    assert_fails(/RUBYGEMS_HOST/) { guard(env: env(RUBYGEMS_HOST: "https://evil.example"), dir: @repo[:checkout]).publish_preflight }
    FileUtils.mkdir_p(File.join(@repo[:root], ".gem"))
    File.write(File.join(@repo[:root], ".gem/credentials"), "---\n")
    assert_fails(/credentials file/) { guard(env: env, dir: @repo[:checkout]).publish_preflight }
  end

  def test_version_already_on_rubygems_fails
    assert_fails(/already on RubyGems/) { guard(env: env, dir: @repo[:checkout], http: rubygems("0.3.0", sha: @sha)).publish_preflight }
  end

  def test_rubygems_api_failure_fails
    http = rubygems("0.3.0", v1: R.new(status: 500, body: ""))
    assert_fails(/state unknown/) { guard(env: env, dir: @repo[:checkout], http: http).publish_preflight }
  end

  def test_artifact_sha_mismatch_fails
    assert_fails(/ARTIFACT SHA MISMATCH/) do
      guard(env: env(GEM_SHA256: "0" * 64), dir: @repo[:checkout], http: protected_github(rubygems("0.3.0"))).publish_preflight
    end
  end

  def test_rewritten_main_fails
    git(@repo[:work], "checkout", "--quiet", "--orphan", "other")
    git(@repo[:work], "commit", "--quiet", "--allow-empty", "-m", "unrelated")
    git(@repo[:work], "push", "--quiet", "--force", "origin", "other:main")
    assert_fails(/no longer in the history of main/) { guard(env: env, dir: @repo[:checkout], http: rubygems("0.3.0")).publish_preflight }
  end

  def test_oidc_credentials_must_be_present_and_are_not_printed
    assert_fails(/no RubyGems credentials/) { guard(env: {}).assert_oidc_credentials }
    guard(env: { "GEM_HOST_API_KEY" => "short-lived-secret" }).assert_oidc_credentials
    refute_includes @out.string, "short-lived-secret"
  end

  def push(result, http)
    runner = FakeRunner.new("gem push" => result)
    g = guard(env: env, dir: @repo[:checkout], http: http, runner: runner)
    [g, runner]
  end

  def test_push_succeeds_once
    g, runner = push(OK, FakeHTTP.new)
    g.push
    assert_equal [["gem", "push", File.join(@gem_dir, "jobpayload-0.3.0.gem")]], runner.calls
  end

  def test_push_failure_with_nothing_published
    g, runner = push(FAILED, rubygems("0.3.0"))
    assert_fails(/appears nothing was published/) { g.push }
    assert_equal 1, runner.calls.size
    assert_equal [90], @sleeps, "waits for the RubyGems API cache before reading the state"
  end

  def test_push_failure_but_identical_gem_published
    g, runner = push(TIMED_OUT, rubygems("0.3.0", sha: @sha))
    assert_fails(/timed out, but RubyGems now has jobpayload 0.3.0 with the frozen SHA-256.*Do NOT push again/) { g.push }
    assert_equal 1, runner.calls.size
  end

  def test_push_failure_with_a_different_gem_published_is_critical
    g, = push(FAILED, rubygems("0.3.0", sha: "d" * 64))
    assert_fails(/CRITICAL — PUBLISHED ARTIFACT MISMATCH/, ReleaseGuard::Critical) { g.push }
  end

  def test_push_failure_with_unknown_state
    g, runner = push(FAILED, rubygems("0.3.0", v1: R.new(status: 502, body: "")))
    assert_fails(/state is unknown.*Do NOT push again/) { g.push }
    assert_equal 1, runner.calls.size
  end

  def test_create_github_release
    runner = FakeRunner.new("gh" => OK)
    http = rubygems("0.3.0", sha: @sha)
      .route(ReleaseGuardTestSupport.github_url("/releases/tags/v0.3.0"), R.new(status: 404, body: "{}"))
      .route(ReleaseGuardTestSupport.github_url("/releases?per_page=100&page=1"), R.new(status: 200, body: "[]"))
    guard(env: env, dir: @repo[:checkout], http: http, runner: runner).create_github_release
    argv = runner.calls.first
    assert_equal %w[gh release create v0.3.0 --repo cottondesu/jobpayload --verify-tag --title 0.3.0 --notes-file], argv.first(10)
    assert_includes argv, "--draft=false"
    assert_includes argv, "--prerelease=false"
  end

  def test_github_release_failure_keeps_everything_and_says_so
    runner = FakeRunner.new("gh" => FAILED)
    http = rubygems("0.3.0", sha: @sha)
      .route(ReleaseGuardTestSupport.github_url("/releases/tags/v0.3.0"), R.new(status: 404, body: "{}"))
      .route(ReleaseGuardTestSupport.github_url("/releases?per_page=100&page=1"), R.new(status: 200, body: "[]"))
    assert_fails(/IS published on RubyGems.*do not push it again/) do
      guard(env: env, dir: @repo[:checkout], http: http, runner: runner).create_github_release
    end
  end

  def test_github_release_not_created_unless_rubygems_has_the_frozen_gem
    runner = FakeRunner.new("gh" => OK)
    http = rubygems("0.3.0", sha: "d" * 64)
      .route(ReleaseGuardTestSupport.github_url("/releases/tags/v0.3.0"), R.new(status: 404, body: "{}"))
      .route(ReleaseGuardTestSupport.github_url("/releases?per_page=100&page=1"), R.new(status: 200, body: "[]"))
    assert_fails(/not creating the GitHub release/) { guard(env: env, dir: @repo[:checkout], http: http, runner: runner).create_github_release }
    assert_empty runner.calls
  end

  def test_final_verification
    release = { "tag_name" => "v0.3.0", "name" => "0.3.0", "draft" => false, "prerelease" => false,
                "body" => "# jobpayload v0.3.0\r\n\r\nNotes.", "html_url" => "https://github.com/cottondesu/jobpayload/releases/tag/v0.3.0" }
    url = ReleaseGuardTestSupport.github_url("/releases/tags/v0.3.0")
    guard(env: env, dir: @repo[:checkout], http: rubygems("0.3.0", sha: @sha).route(url, R.new(status: 200, body: JSON.generate(release)))).final_verify
    assert_includes @out.string, "release v0.3.0 verified"

    prerelease = release.merge("prerelease" => true, "name" => "v0.3.0")
    http = rubygems("0.3.0", sha: @sha).route(url, R.new(status: 200, body: JSON.generate(prerelease)))
    assert_fails(/it is a prerelease; its title is "v0.3.0"/) { guard(env: env, dir: @repo[:checkout], http: http).final_verify }
  end
end

class ReleaseGuardPublishedGemTest < Minitest::Test
  include ReleaseGuardTestSupport

  DATA = "frozen gem bytes".b
  SHA = Digest::SHA256.hexdigest(DATA)
  ENV_VARS = { "RELEASE_VERSION" => "0.3.0", "RELEASE_COMMIT" => "1" * 40, "GEM_SHA256" => SHA }.freeze

  def http(downloads, v2: R.new(status: 200, body: JSON.generate("number" => "0.3.0", "platform" => "ruby", "sha" => SHA)))
    FakeHTTP.new(ReleaseGuardTestSupport.download_url("0.3.0") => downloads, ReleaseGuardTestSupport.v2_url("0.3.0") => v2)
  end

  def test_published_gem_matches
    guard(env: ENV_VARS, http: http([R.new(status: 200, body: DATA)])).verify_published
    assert_includes @out.string, "published_sha256=#{SHA}"
    assert_empty @sleeps
  end

  def test_propagation_delay_is_retried_with_a_bound
    downloads = [R.new(status: 403, body: ""), ReleaseGuard::TransportError.new("reset"), R.new(status: 404, body: ""), R.new(status: 200, body: DATA)]
    guard(env: ENV_VARS, http: http(downloads)).verify_published(attempts: 5, interval: 7)
    assert_equal [7, 7, 7], @sleeps

    assert_fails(/after 4 attempts/) { guard(env: ENV_VARS, http: http([R.new(status: 404, body: "")])).verify_published(attempts: 4, interval: 1) }
    assert_equal [1, 1, 1], @sleeps
  end

  def test_published_gem_mismatch_is_critical
    assert_fails(/CRITICAL — PUBLISHED ARTIFACT MISMATCH/, ReleaseGuard::Critical) do
      guard(env: ENV_VARS, http: http([R.new(status: 200, body: "tampered".b)])).verify_published
    end
    other = R.new(status: 200, body: JSON.generate("number" => "0.3.0", "platform" => "ruby", "sha" => "9" * 64))
    assert_fails(/CRITICAL — PUBLISHED ARTIFACT MISMATCH/, ReleaseGuard::Critical) do
      guard(env: ENV_VARS, http: http([R.new(status: 200, body: DATA)], v2: other)).verify_published
    end
  end

  def test_unexpected_http_status_fails
    assert_fails(/HTTP 400/) { guard(env: ENV_VARS, http: http([R.new(status: 400, body: "")])).verify_published }
  end

  def test_duplicate_version_is_never_a_success
    identical = rubygems("0.3.0", sha: SHA)
    assert_fails(/byte-identical to this build.*Nothing was published/) { guard(env: ENV_VARS, http: identical).diagnose_duplicate }
    different = rubygems("0.3.0", sha: "8" * 64)
    assert_fails(/CRITICAL — PUBLISHED ARTIFACT MISMATCH/, ReleaseGuard::Critical) { guard(env: ENV_VARS, http: different).diagnose_duplicate }
  end
end

class ReleaseGuardCommandLineTest < Minitest::Test
  include ReleaseGuardTestSupport

  def test_failures_become_annotations_and_exit_1
    err = StringIO.new
    failing = Object.new.tap { |o| o.define_singleton_method(:verify_artifact) { raise ReleaseGuard::Failure, "line one\nline two 100%" } }
    assert_equal 1, ReleaseGuard.main(["verify-artifact"], guard: failing, err: err)
    assert_equal "::error title=release guard (verify-artifact)::line one%0Aline two 100%25\n", err.string
  end

  def test_unknown_command_is_a_usage_error
    assert_equal 64, ReleaseGuard.main(["publish-everything"], guard: Object.new, err: StringIO.new)
    assert_equal 64, ReleaseGuard.main([], guard: Object.new, err: StringIO.new)
  end

  def test_runner_kills_a_command_that_times_out
    result = ReleaseGuard::Runner.new(grace: 0.1).call(["sleep", "30"], timeout: 0.2)
    assert result.timed_out
    refute result.success?
  end

  def test_actions_outputs_are_single_line
    Tempfile.create("output") do |f|
      actions = ReleaseGuard::Actions.new({ "GITHUB_OUTPUT" => f.path }, out: StringIO.new)
      actions.output("version", "0.3.0")
      assert_raises(ReleaseGuard::Failure) { actions.output("version", "0.3.0\nextra=1") }
      assert_equal "version=0.3.0\n", File.read(f.path)
    end
  end
end

# Static checks of the workflow itself.
class ReleaseWorkflowTest < Minitest::Test
  WORKFLOW = YAML.safe_load_file(ReleaseGuardTestSupport::WORKFLOW, aliases: false)
  CI = YAML.safe_load_file(File.join(ReleaseGuardTestSupport::ROOT, ".github/workflows/ci.yml"), aliases: false)
  JOBS = WORKFLOW.fetch("jobs")

  def steps = JOBS.flat_map { |name, job| job.fetch("steps").map { |s| [name, s] } }

  def ancestors(job)
    Array(JOBS.fetch(job)["needs"]).flat_map { |n| [n, *ancestors(n)] }.uniq
  end

  def test_only_release_tag_pushes_trigger_it
    triggers = WORKFLOW["on"] || WORKFLOW[true]
    assert_equal({ "push" => { "tags" => ["v*"] } }, triggers)
  end

  def test_permissions_are_least_privilege
    assert_equal({}, WORKFLOW["permissions"])
    JOBS.each { |name, job| refute_nil job["permissions"], "#{name} must declare its permissions" }
    with_id_token = JOBS.select { |_, job| job["permissions"]["id-token"] }.keys
    assert_equal ["publish"], with_id_token
    assert_equal({ "contents" => "read", "actions" => "read", "id-token" => "write" }, JOBS["publish"]["permissions"])
    writers = JOBS.select { |_, job| job["permissions"].values.include?("write") && job["permissions"]["id-token"].nil? }.keys
    assert_equal ["github-release"], writers
    assert_equal({ "contents" => "write" }, JOBS["github-release"]["permissions"])
  end

  def test_publish_requires_the_release_environment
    with_env = JOBS.select { |_, job| job["environment"] }.keys
    assert_equal ["publish"], with_env
    assert_equal "release", JOBS["publish"]["environment"]["name"]
  end

  def test_actions_are_pinned_to_full_commit_shas
    uses = steps.filter_map { |_, s| s["uses"] }
    refute_empty uses
    uses.each { |u| assert_match(/\A[a-z0-9-]+\/[a-z0-9-]+@[0-9a-f]{40}\z/, u) }
    File.read(ReleaseGuardTestSupport::WORKFLOW, encoding: "UTF-8").scan(/uses: (\S+)(.*)$/).each do |use, comment|
      assert_match(/\A # v\d+\.\d+\.\d+\z/, comment, "#{use} needs a version comment")
    end
  end

  def test_checkouts_do_not_persist_credentials_and_use_the_validated_commit
    steps.select { |_, s| s["uses"].to_s.start_with?("actions/checkout@") }.each do |job, s|
      assert_equal false, s.dig("with", "persist-credentials"), job
      assert_equal "${{ needs.validate.outputs.commit }}", s.dig("with", "ref"), job unless job == "validate"
    end
  end

  def test_no_expressions_inside_shell_scripts
    steps.each do |job, s|
      next unless s["run"]

      refute_includes s["run"], "${{", "#{job}: pass values through env, not into the script"
    end
  end

  def test_publishing_waits_for_every_gate
    assert_equal %w[build macos test validate], (ancestors("publish") & %w[validate test macos build]).sort
    assert_includes ancestors("verify-rubygems"), "publish"
    assert_includes ancestors("github-release"), "verify-rubygems"
    assert_includes ancestors("final-verify"), "github-release"
    assert_equal "needs.validate.outputs.rubygems_state == 'absent'", JOBS["publish"]["if"]
    assert_equal "needs.validate.outputs.rubygems_state == 'present'", JOBS["duplicate-version"]["if"]
    JOBS.each_value { |job| refute_match(/always\(\)|cancelled\(\)|failure\(\)/, job["if"].to_s) }
    refute JOBS.values.any? { |job| job["continue-on-error"] || job.fetch("steps").any? { |s| s["continue-on-error"] } }
  end

  def test_runs_are_never_cancelled_mid_release
    assert_equal false, WORKFLOW.dig("concurrency", "cancel-in-progress")
    assert_equal "release-${{ github.ref }}", WORKFLOW.dig("concurrency", "group")
  end

  def test_trusted_publishing_only_in_the_publish_job
    oidc = steps.select { |_, s| s["uses"].to_s.start_with?("rubygems/configure-rubygems-credentials@") }
    assert_equal ["publish"], oidc.map(&:first)
    assert_equal({ "trusted-publisher" => "true" }, oidc.first.last["with"])
    pushes = steps.select { |_, s| s["run"].to_s.include?(" push") || s["run"].to_s.include?("gem push") }
    assert_equal [["publish", 'ruby "$GUARD" push']], pushes.map { |job, s| [job, s["run"].strip] }
    refute_match(/secrets\./, File.read(ReleaseGuardTestSupport::WORKFLOW, encoding: "UTF-8"))
  end

  def test_matrix_matches_ci_and_the_package_audit
    matrix = JOBS["test"]["strategy"]["matrix"]
    assert_equal CI["jobs"]["test"]["strategy"]["matrix"], matrix
    audit = JOBS["build"]["steps"].find { |s| s["run"].to_s.include?("audit-package") }["env"]
    assert_equal matrix["ruby"].join(" "), audit["AUDIT_RUBIES"]
    assert_equal matrix["activejob"].join(" "), audit["AUDIT_ACTIVEJOB"]
    assert_equal "1", JOBS["test"]["env"]["JOBPAYLOAD_REQUIRE_NON_UTF8_FILENAMES"]
    assert_equal "macos-latest", JOBS["macos"]["runs-on"]
  end

  def test_rails_edge_is_not_a_release_gate
    refute_includes JOBS.keys.join(" "), "edge"
    refute_includes File.read(ReleaseGuardTestSupport::WORKFLOW, encoding: "UTF-8"), "rails_edge"
  end
end
