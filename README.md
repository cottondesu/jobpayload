# jobpayload

Checks that Active Job payloads written by an **old** version of your
application can still be deserialized by the **new** version.

> **`jobpayload` does not execute jobs.** It never calls `perform`,
> `perform_now`, `perform_later`, `enqueue` or `retry_job`. It only runs
> `ActiveJob::Base.deserialize` and `ActiveJob::Arguments.deserialize`.

> **`jobpayload` checks Active Job's serialized job data, not
> Sidekiq/GoodJob/Solid Queue backend-specific storage formats.**

- [What jobpayload checks](#what-jobpayload-checks)
- [Why queued payload compatibility matters](#why-queued-payload-compatibility-matters)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Creating snapshot cases](#creating-snapshot-cases)
- [Generating baseline fixtures](#generating-baseline-fixtures)
- [Checking old fixtures on new code](#checking-old-fixtures-on-new-code)
- [Two-way rolling-deploy checking](#two-way-rolling-deploy-checking)
- [GlobalID / inconclusive semantics](#globalid--inconclusive-semantics)
- [Finding codes](#finding-codes)
- [Exit codes](#exit-codes)
- [Human output](#human-output)
- [JSON output](#json-output)
- [CI example](#ci-example)
- [Supported Ruby / Active Job versions](#supported-ruby--active-job-versions)
- [Non-goals](#non-goals)
- [Known limitations](#known-limitations)
- [Security / safety notes](#security--safety-notes)

## What jobpayload checks

The compatibility contract is the payload Active Job actually stores
(`ActiveJob::Base#serialize`), not the shape of your source code.

A baseline fixture is compatible with the current application when:

1. **The fixture is valid** (schema v1 wrapper, see [Fixture files](#fixture-files)).
2. **The job can be restored**: the payload's `job_class` resolves to an
   `ActiveJob::Base` subclass and `ActiveJob::Base.deserialize(job_data)`
   succeeds. This exercises job class resolution, any `deserialize(job_data)`
   override and custom job metadata added by `serialize` overrides.
3. **The arguments can be restored**:
   `ActiveJob::Arguments.deserialize(job_data["arguments"])` succeeds. This
   exercises built-in serializers, custom `ActiveJob::Serializers::ObjectSerializer`
   subclasses, nested arrays/hashes and GlobalID lookups, in your real
   (test) environment.

v0.1.0 checks **backward-read compatibility only**: old payload → new code.

## Why queued payload compatibility matters

Jobs outlive deploys. A job enqueued by v1 of your app may be picked up by a
v2 worker minutes or days later (scheduled jobs, retries, backlogs):

```
v1 application ──serialize──▶ queue ──deploy──▶ v2 worker ──deserialize──▶ 💥
```

Typical breaks:

- a job class was renamed or removed
- a custom serializer class was renamed or removed
- a custom serializer's `deserialize` no longer understands the old payload
- a job's own `deserialize(job_data)` requires a field old payloads lack
- a model referenced by a GlobalID was renamed or removed

These break at runtime in production, usually after the old code is gone.
`jobpayload` turns them into a failing CI check.

## Installation

Add it to the `test` (or `development`) group of your Gemfile:

```ruby
group :test do
  gem "jobpayload", require: false
end
```

`require: false` matters: the CLI boots your application itself.
(Requiring the gem never loads Active Job anyway, so it cannot change your
initializer or serializer registration order. Nothing jobpayload does before
booting your app loads the json library either, so the app's own gem versions win.)

Run it with `bundle exec jobpayload ...` so it uses your application's bundle.

Runtime dependency: `activejob >= 7.2, < 9`. Nothing else.

## Quick start

```sh
# 1. Describe the jobs you care about
$EDITOR test/jobpayload_cases.rb

# 2. Write baseline fixtures (and commit them)
bundle exec jobpayload snapshot
git add test/jobpayload_fixtures

# 3. Later, on new code: can the new code still read the old payloads?
bundle exec jobpayload check
```

## Creating snapshot cases

Snapshot cases live in `test/jobpayload_cases.rb` (override with `--cases`).
Each `fixture` block must return an **`ActiveJob::Base` instance** (not
enqueued). Returning anything else is an error.

```ruby
# test/jobpayload_cases.rb
JobPayload.define do
  fixture "billing-money-v1" do
    BillingJob.new(Money.new(1_250, "USD"))
  end

  fixture "notify-user-v1" do
    user = User.find_or_create_by!(email: "jobpayload@example.test")
    NotifyUserJob.new(user)
  end

  fixture "tenant-reindex-v1" do
    TenantJob.new("reindex").tap { |job| job.tenant_id = 42 }
  end
end
```

Rules:

- Names must be unique (ignoring case, so fixtures do not collide on
  case-insensitive file systems) and match `[A-Za-z0-9][A-Za-z0-9._-]*`
  (no `/`, no `..`). The name is also the fixture file name (`<name>.json`).
- Blocks are plain Ruby run inside your booted application, so they may create
  records (in the test database) or build any objects your jobs accept.
- Treat a fixture as an immutable record of "what v1 wrote". When the payload
  format intentionally changes, add a new case (`billing-money-v2`) and keep
  the old fixture: queues may still contain v1 payloads.

## Generating baseline fixtures

```sh
bundle exec jobpayload snapshot [options]
```

| Option | Default | Meaning |
| --- | --- | --- |
| `--cases PATH` | `test/jobpayload_cases.rb` | Snapshot cases file |
| `--output DIR` | `test/jobpayload_fixtures` | Where fixtures are written |
| `--boot PATH` | `config/environment.rb` | File required to boot the app |
| `--environment NAME` | `test` | Value assigned to `RAILS_ENV` before booting |
| `--update` | off | Replace existing fixtures whose content changed |
| `--check` | off | Compare with existing fixtures without writing (see [Detecting snapshot drift](#detecting-snapshot-drift-snapshot---check)) |
| `--format text\|json` | `text` | Output format |

Behaviour:

- The source of truth is `ActiveJob::Base#serialize`. No adapter-specific
  conversion is applied.
- **Existing fixtures are never overwritten by default.** A fixture whose
  content would change is reported as `skipped`; pass `--update` to replace it.
  Fixtures with no matching case are never deleted.
- All cases are evaluated before anything is written; if any case raises or
  returns a non-job, nothing is written and the command exits 2.
- Statuses: `created`, `updated`, `identical`, `skipped`.

### Fixture files

One JSON file per fixture, schema v1:

```json
{
  "job": {
    "arguments": [
      {
        "_aj_serialized": "MoneySerializer",
        "amount": 1250,
        "currency": "USD"
      }
    ],
    "enqueued_at": "2000-01-01T00:00:00.000000000Z",
    "exception_executions": {},
    "executions": 0,
    "job_class": "BillingJob",
    "job_id": "00000000-0000-0000-0000-000000000000",
    "locale": "en",
    "priority": null,
    "provider_job_id": null,
    "queue_name": "default",
    "scheduled_at": null,
    "timezone": "UTC"
  },
  "jobpayload_schema": 1,
  "name": "billing-money-v1",
  "source": {
    "active_job_version": "8.1.4",
    "jobpayload_version": "0.1.0",
    "rails_version": "8.1.4",
    "ruby_version": "3.4.8"
  }
}
```

- `source` records where the fixture came from (`rails_version` is `null` when
  Rails is not loaded). It is informational.
- Volatile metadata is normalized so snapshots do not churn in `git diff`:
  `job_id` → `00000000-0000-0000-0000-000000000000`, `provider_job_id` → `null`,
  `enqueued_at` → `2000-01-01T00:00:00.000000000Z`, `executions` → `0`,
  `exception_executions` → `{}`, and a non-null `scheduled_at` →
  `2000-01-01T00:00:00.000000000Z`. Keys are only normalized when present.
- `job_class`, `queue_name`, `priority`, `arguments`, `locale`, `timezone` and
  **every custom key added by a job's `serialize` override** are kept as-is.
- Output is byte-for-byte deterministic: object keys sorted recursively, a fixed
  two-space layout (independent of the json gem version), UTF-8, LF line endings,
  a final newline, written atomically (temp file + rename).

### Detecting snapshot drift (`snapshot --check`)

```sh
bundle exec jobpayload snapshot --check [options]
```

`--check` serializes every snapshot case with the current code, exactly as
`snapshot` would, and compares the result with the fixture already stored in
`--output`. It answers "did the payload this code writes change?", so an
unintended change to what new code enqueues fails CI before it ships. It is
**read-only for the fixtures**: nothing in `--output` is written, replaced,
created or deleted, not even a missing `--output` directory. (Like `snapshot`,
it still boots your application and runs your cases file, which may write to
the test database.) `--check` and `--update` cannot be combined.

Only the `job` object is compared, and every key in it counts. The current
payload is normalized exactly as `snapshot` writes it (fixed `job_id`,
`enqueued_at` and so on); the stored `job` is compared as stored, so any edit
to a fixture's `job`, volatile metadata included, is reported as `different`.
`source` metadata, key order, whitespace and equivalent JSON spellings
(`"\u00e9"` and `"é"`, `1.0e2` and `100.0`) are ignored. Value types and array
order are kept: `1` and `1.0`, or `null` and a missing key, are different
payloads.

| Status | Meaning | Exit |
| --- | --- | --- |
| `identical` | The stored `job` matches what the current code serializes | 0 |
| `different` | The payload the current code writes differs from the stored `job` | 1 |
| `missing` | No fixture file for the case | 1 |
| `invalid` | The fixture cannot be used: invalid JSON or UTF-8, wrong schema, name mismatch, a symbolic link (never followed, even when it points to a valid fixture), not a regular file (such as a directory or FIFO), unreadable or inaccessible (for example an unsearchable directory), or a `job` that `snapshot` could never have written (a non-finite number such as `1e400`, or nesting deeper than `snapshot`'s limit of 100) | 2 |

The exit status is the highest that applies (`2` > `1` > `0`). Case errors,
boot errors and usage errors exit 2 as for `snapshot`. Fixtures with no
matching case are ignored. A `--output` directory that does not exist is not an
error: every case is reported `missing` (exit 1), so check the path if
everything is missing. Only the fixture file entry itself must not be a symbolic
link; `--output` may be one.

Text output has one line per case, in name order, and a summary. The status
says whether a fixture differs, not where; compare the files (for example
with `git diff` after `snapshot --update`) to see the change:

```text
identical billing-legacy-money-v1  test/jobpayload_fixtures/billing-legacy-money-v1.json
different billing-money-v1  test/jobpayload_fixtures/billing-money-v1.json
missing   scheduled-v1  test/jobpayload_fixtures/scheduled-v1.json

3 fixtures: 1 identical, 1 different, 1 missing, 0 invalid
```

With `--format json` the document (schema v1) is:

```json
{
  "schema_version": 1,
  "tool_version": "0.1.0",
  "mode": "check",
  "status": "fail",
  "summary": {
    "fixtures": 1,
    "identical": 0,
    "different": 1,
    "missing": 0,
    "invalid": 0
  },
  "fixtures": [
    {
      "name": "billing-money-v1",
      "path": "test/jobpayload_fixtures/billing-money-v1.json",
      "status": "different",
      "reason": null
    }
  ]
}
```

`status` is `pass`, `fail` or `tool_error` for exit 0, 1 and 2. `reason` is
set only for `invalid`.
Text and JSON output are deterministic for the same input.

A `different` result is not a compatibility failure by itself: it means the
new code writes a different payload than the fixture records. Add a new case
for the new format (keeping the old fixture for `check`), or re-run
`snapshot --update` if the fixture was meant to follow the code.

## Checking old fixtures on new code

```sh
bundle exec jobpayload check [options]
```

| Option | Default | Meaning |
| --- | --- | --- |
| `--fixtures PATH` | `test/jobpayload_fixtures` | Fixture directory (all `*.json`, sorted) or a single fixture file |
| `--boot PATH` | `config/environment.rb` | File required to boot the app |
| `--environment NAME` | `test` | Value assigned to `RAILS_ENV` before booting |
| `--format text\|json` | `text` | Output format |
| `--fail-on-inconclusive` | off | Exit 1 when any fixture is inconclusive |
| `--debug` | off | Add cause chains with backtraces to text output |

For each fixture, in order:

- **Phase A (parse)**: JSON parse and schema validation. Problems are
  reported as `AJP001` (an input error, not a compatibility failure).
- **Phase B (job)**: resolve `job_class`, then
  `ActiveJob::Base.deserialize(copy_of_job_data)`.
- **Phase C (arguments)**:
  `ActiveJob::Arguments.deserialize(copy_of_arguments)`. The full call is the
  source of truth for *whether* the arguments are readable. When it fails,
  every argument is retried on its own (descending into plain arrays/hashes)
  to report *each* failing argument with its own finding. Active Job stops at
  the first error, so this keeps an inconclusive missing GlobalID record in
  `arguments[0]` from hiding a broken serializer in `arguments[1]`. A plain
  array/hash whose children fail is also retried with those children blanked
  out, so a missing record inside it cannot hide a problem with the container
  itself.

Each phase gets its own deep copy of the payload. Phase C runs even when
Phase B fails, so one run reports every problem.

The application is booted **once per process**, before any fixture is
checked. Startup order is always: parse options → boot the app → use Active
Job APIs. Non-Rails apps can point `--boot` at any Ruby file that loads their
jobs, for example `--boot spec/dummy/config/environment.rb`.

## Two-way rolling-deploy checking

During a rolling deploy, old and new workers run side by side, so payloads
flow in both directions. jobpayload itself only checks one direction (old
payload → current code) and does not check out Git refs, but you can run it
twice from two checkouts:

```sh
# base = main, head = your branch, each in its own checkout with its own bundle
(cd head && bundle exec jobpayload snapshot --output tmp/head_fixtures)
(cd base && bundle exec jobpayload snapshot --output tmp/base_fixtures)

# old payloads → new workers
(cd head && bundle exec jobpayload check --fixtures ../base/tmp/base_fixtures)
# new payloads → old workers (still running mid-deploy)
(cd base && bundle exec jobpayload check --fixtures ../head/tmp/head_fixtures)
```

Note that the same snapshot cases file must work on both checkouts.

## GlobalID / inconclusive semantics

A fixture holding `gid://app/User/123` cannot be deserialized when user 123
does not exist in the test database. That makes the *job* unrunnable, but it
does not prove the *payload format* is incompatible. So:

- An argument is **inconclusive** (`AJP202`) only when all of these hold:
  1. `ActiveJob::Arguments.deserialize` fails for it,
  2. the failing serialized value is an Active Job GlobalID reference
     (exactly `{"_aj_globalid": "gid://..."}`, the form Active Job writes),
     and
  3. the cause chain contains a "record does not exist" exception
     (`ActiveRecord::RecordNotFound`, `GlobalID::Locator::RecordNotFound`, or
     subclasses; also `Mongoid::Errors::DocumentNotFound`).

  Exit code stays 0 unless `--fail-on-inconclusive` is given.
- Any other argument failure is a normal **compatibility failure**
  (`AJP201`), **even when `RecordNotFound` is in the cause chain**. For
  example, a custom serializer whose `deserialize` now does
  `User.find_by!(email: hash["email_address"])` cannot read an old
  `{"_aj_serialized": "UserEmailSerializer", "email": "..."}` payload: that
  is a broken payload, not a missing record. The same applies when the model
  constant is gone, the GlobalID class cannot be resolved, or a custom
  locator raises.
- A `RecordNotFound` raised by a job's own `deserialize(job_data)` override is
  `AJP102` (breaking): only GlobalID arguments can be inconclusive.
- If the database is unusable (connection errors, missing database or database
  configuration, `ActiveRecord::StatementInvalid` such as a schema that was
  never loaded), the check environment is broken: `AJP900`, exit 2.

Classification uses exception classes (by name, including ancestors, so it
works whether or not Active Record is loaded) along the full cause chain, never
message text. Make the records your fixtures reference exist in the test
database (seeds, fixtures, or a boot file) to get a conclusive answer.

## Finding codes

Finding codes are a stable API for 0.1.x.

| Code | Name | Kind | Meaning |
| --- | --- | --- | --- |
| `AJP001` | `fixture_invalid` | fatal | Fixture file is invalid (bad JSON, unknown schema, missing `name`/`job`/`job_class`, `arguments` not an array, invalid name, name ≠ file name). Input/config error, not a compatibility result. |
| `AJP101` | `unknown_job_class` | breaking | `job_class` cannot be resolved to an `ActiveJob::Base` subclass. |
| `AJP102` | `job_deserialize_failed` | breaking | The class exists but `ActiveJob::Base.deserialize(job_data)` (including your `deserialize(job_data)` override) raised. |
| `AJP201` | `argument_deserialize_failed` | breaking | `ActiveJob::Arguments.deserialize` raised: serializer removed/renamed, old field missing, type expectation changed, malformed representation, GlobalID model removed... |
| `AJP202` | `globalid_record_missing` | inconclusive | A GlobalID argument (`{"_aj_globalid": ...}`) points at a record that does not exist in the test environment. Never used for custom serializers or job-level `deserialize`. |
| `AJP900` | `environment_error` | fatal | Boot failure, database unavailable, the Ruby stack exhausted by a pathologically deep payload, or another problem with the check environment itself. |

## Exit codes

| Exit | Meaning |
| --- | --- |
| `0` | All fixtures compatible (inconclusive fixtures allowed unless `--fail-on-inconclusive`) |
| `1` | At least one compatibility failure (or an inconclusive fixture with `--fail-on-inconclusive`) |
| `2` | Usage, configuration, boot or tool error (`AJP001`, `AJP900`, unknown command/option, missing files) |

When several apply, the highest priority wins: `2` > `1` > `0`.

These are the exit statuses of `check`. `snapshot --check` uses the same
`2` > `1` > `0` precedence with its own meanings; see
[Detecting snapshot drift](#detecting-snapshot-drift-snapshot---check).

Results are written to **stdout**. Usage, configuration and boot errors are
written to **stderr** (and nothing is written to stdout in that case).
jobpayload itself writes nothing else to stdout. While booting and
deserializing, `$stdout` is pointed at stderr, so anything your application
prints with `puts`/`print` (or a logger built on `$stdout`) goes to stderr.
Writes that bypass `$stdout`, such as `STDOUT.puts`, `Logger.new(STDOUT)` or
writing to file descriptor 1 directly, are **not** redirected and would end up
in front of the JSON document; keep them out of the environment you boot for
jobpayload. If application code calls `exit` or `abort`, or raises an
exception that does not inherit from `StandardError`, jobpayload exits 2.

Long options must be spelled out in full (`--fail-on-inconclusive`, not `--fail`).

## Human output

All fixtures compatible:

```
PASS billing-money-v1
PASS invoice-period-v1

2 fixtures checked
2 compatible
0 incompatible
0 inconclusive
```

A failure:

```
AJP201 breaking billing-money-v1

Job:
  BillingJob

Argument:
  arguments[0]

Old payload cannot be deserialized by the current application.

Cause:
  ArgumentError: Serializer MoneySerializer is not known
```

An inconclusive GlobalID:

```
AJP202 inconclusive notify-user-v1

Job:
  NotifyUserJob

Argument:
  arguments[0]

GlobalID target record was not found in the current test environment.

This does not by itself prove a payload compatibility break.

Cause:
  ActiveRecord::RecordNotFound: Couldn't find User with 'id'=123
```

`Cause` shows the innermost exception of the cause chain. With `--debug`, the
whole chain and backtraces are printed as well. Fixtures appear in name order,
findings in code / argument-path order, so the output is deterministic.
A summary line `N tool error(s)` is added when fixtures had fatal findings.

## JSON output

This section describes `check --format json`. The `snapshot --check` document
is described in [Detecting snapshot drift](#detecting-snapshot-drift-snapshot---check).

```sh
bundle exec jobpayload check --format json
```

```json
{
  "schema_version": 1,
  "tool_version": "0.1.0",
  "status": "fail",
  "summary": {
    "fixtures": 3,
    "compatible": 1,
    "incompatible": 1,
    "inconclusive": 1,
    "tool_errors": 0
  },
  "fixtures": [
    { "name": "billing-money-v1", "status": "fail" },
    { "name": "invoice-period-v1", "status": "pass" },
    { "name": "notify-user-v1", "status": "inconclusive" }
  ],
  "findings": [
    {
      "code": "AJP201",
      "name": "argument_deserialize_failed",
      "severity": "error",
      "fixture": "billing-money-v1",
      "job_class": "BillingJob",
      "argument_path": "arguments[0]",
      "message": "Old payload cannot be deserialized by the current application.",
      "exception_class": "ActiveJob::DeserializationError",
      "exception_message": "Error while trying to deserialize arguments: Serializer MoneySerializer is not known",
      "cause_chain": [
        {
          "class": "ActiveJob::DeserializationError",
          "message": "Error while trying to deserialize arguments: Serializer MoneySerializer is not known"
        },
        { "class": "ArgumentError", "message": "Serializer MoneySerializer is not known" }
      ]
    },
    {
      "code": "AJP202",
      "name": "globalid_record_missing",
      "severity": "warning",
      "fixture": "notify-user-v1",
      "job_class": "NotifyUserJob",
      "argument_path": "arguments[0]",
      "message": "GlobalID target record was not found in the current test environment.",
      "exception_class": "ActiveJob::DeserializationError",
      "exception_message": "Error while trying to deserialize arguments: Couldn't find User with 'id'=123",
      "cause_chain": [
        {
          "class": "ActiveJob::DeserializationError",
          "message": "Error while trying to deserialize arguments: Couldn't find User with 'id'=123"
        },
        { "class": "ActiveRecord::RecordNotFound", "message": "Couldn't find User with 'id'=123" }
      ]
    }
  ]
}
```

(The real output uses the same two-space layout as fixtures, one value per line.)

| Field | Meaning |
| --- | --- |
| `schema_version` | JSON output schema version. Always `1` in 0.1.x. |
| `tool_version` | jobpayload version. |
| `status` | `"pass"` (exit 0), `"fail"` (exit 1) or `"tool_error"` (exit 2). With `--fail-on-inconclusive`, inconclusive fixtures make it `"fail"`. |
| `summary.fixtures` | Number of fixture files checked. |
| `summary.compatible` / `incompatible` / `inconclusive` / `tool_errors` | Number of fixtures whose status is `pass` / `fail` / `inconclusive` / `tool_error`. |
| `fixtures[]` | `{name, status}` for every fixture, sorted by name. `status` is the fixture's worst finding: `"tool_error"` (a `fatal` finding) > `"fail"` (an `error` finding) > `"inconclusive"` (a `warning` finding) > `"pass"` (no findings). `--fail-on-inconclusive` does not change fixture statuses. |
| `findings[]` | Sorted by `fixture`, then `code`, then `argument_path`. |
| `findings[].code` / `name` | Finding code and its stable name (see [Finding codes](#finding-codes)). |
| `findings[].severity` | `"error"` (compatibility break), `"warning"` (inconclusive) or `"fatal"` (tool/environment failure). |
| `findings[].fixture` | Fixture name (file name without `.json` for unparseable fixtures). |
| `findings[].job_class` | `job_class` from the payload, or `null`. |
| `findings[].argument_path` | Failing argument, e.g. `arguments[1]` or `arguments[0]["batch"][1]`; `arguments` when no single argument fails on its own; `null` for job-level findings. |
| `findings[].message` | Human-readable explanation. |
| `findings[].exception_class` / `exception_message` | Outermost exception, or `null`. |
| `findings[].cause_chain` | `[{class, message}]`, outermost first, following `Exception#cause` (cycle-safe). |

Backtraces are never included in JSON output. The same input always produces
byte-identical JSON. Exception messages, fixture file names and paths are
emitted as valid UTF-8 (invalid bytes become U+FFFD).

**Stability policy.** Within `schema_version: 1` (all 0.1.x releases),
existing fields are never removed or renamed, and the meaning and allowed
values of existing fields do not change. New fields may be added, so consumers
should ignore fields they do not know. Any incompatible change bumps
`schema_version`.

## CI example

Commit baseline fixtures, then run `check` on every pull request. A breaking
payload change makes the job fail with exit 1.

```yaml
# .github/workflows/jobpayload.yml
name: jobpayload
on: [pull_request]
jobs:
  payload-compatibility:
    runs-on: ubuntu-latest
    env:
      RAILS_ENV: test
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true
      - run: bin/rails db:prepare
      - run: bundle exec jobpayload check
      # Optional: fail when the code changes the payloads it writes.
      - run: bundle exec jobpayload snapshot --check
```

For two-way checking, check out both the base and the head revision (for
example two `actions/checkout` steps with different `path:` and `ref:`), then
run `check` twice: base fixtures → head app, and head fixtures → base app, as
shown in [Two-way rolling-deploy checking](#two-way-rolling-deploy-checking).
jobpayload 0.1.0 does not orchestrate checkouts itself.

## Supported Ruby / Active Job versions

| | Active Job 7.2 | Active Job 8.0 | Active Job 8.1 |
| --- | --- | --- | --- |
| Ruby 3.3 | ✅ | ✅ | ✅ |
| Ruby 3.4 | ✅ | ✅ | ✅ |
| Ruby 4.0 | ✅ | ✅ | ✅ |

Every combination is tested in CI (`gemfiles/activejob_*.gemfile`). Active
Job < 7.2 and Ruby < 3.3 are not supported.

Fixtures written under an older supported Active Job version are checked
under newer versions (`test/fixtures/active_job_*`). Checking payloads written
by a *newer* Active Job version on an older one is not covered.

Version-specific types: `ActionController::Parameters` arguments
(serializable since Active Job 8.1) need Action Pack and are not part of the
built-in fixture set.

## Non-goals

v0.1.0 deliberately does **not**:

- execute `perform` or any job business logic, enqueue, or retry jobs
- check `perform` arity or execution semantics. A successful deserialize does
  not prove the result is *semantically* right: a serializer that now reads a
  renamed key with `hash["new_key"]` gets `nil` and still passes. Read old
  keys with `fetch` (or validate) if you want jobpayload to catch renames.
- parse Sidekiq, GoodJob, Solid Queue, Resque or Delayed Job storage formats
- connect to queue backends or dump jobs from real queues
- check out Git refs, create worktrees, or fetch base/head automatically
- analyse Ruby source (no Prism / AST analysis)
- analyse retry safety
- orchestrate forward/two-way compatibility automatically
- re-serialize deserialized arguments (round-trip / re-enqueue compatibility)
- provide ignore/suppression lists or a configuration file

## Known limitations

- **Pathologically deep payloads.** Fixtures nested deeply enough to exhaust
  the Ruby stack are not supported: with Ruby's default stack size that can
  start at roughly 2,000 levels of nested arrays/hashes (`snapshot` itself
  never writes more than 100). Such a fixture is reported as `AJP900` with a
  `SystemStackError` cause, or the check stops with an internal error; either
  way the exit status is 2, never 0 or 1.
  `snapshot --check` reports a baseline nested deeper than 100 levels as
  `invalid` (exit 2).
- **GlobalIDs inside custom serializer payloads.** Only a top-level or
  plain-array/hash GlobalID argument can be inconclusive. If a custom
  serializer's own payload contains a GlobalID whose record is missing, the
  failing value is the custom serializer's payload, so it is reported as
  `AJP201` (breaking). Seed that record in the test database to get a
  conclusive answer.
- **Direct writes to stdout.** Output written through the `STDOUT` constant or
  file descriptor 1 bypasses the redirection described in
  [Exit codes](#exit-codes) and can corrupt `--format json` output.
- **Semantic changes** that still deserialize successfully pass (see
  [Non-goals](#non-goals)).
- **File names that are not valid UTF-8.** jobpayload passes the exact bytes
  it is given for `--output`, `--fixtures`, `--cases` and `--boot` to the file
  system, and only replaces invalid bytes with U+FFFD in text and JSON output.
  Whether such a name can exist at all depends on the file system: most Linux
  file systems accept any bytes, while macOS (APFS) rejects names that are
  not valid UTF-8, so jobpayload cannot create them there. Ordinary UTF-8
  paths work on every platform.
- **Database errors during GlobalID lookup** (`ActiveRecord::StatementInvalid`,
  for example a column or table that the current schema no longer has) are
  reported as `AJP900` with exit 2, not as `AJP201`. The run still fails.

## Security / safety notes

**jobpayload runs trusted application code in your test environment.**

- `check` itself does not enqueue, perform or retry jobs, connect to queues,
  write to the database, make HTTP requests, run shell commands or modify Git.
  However, booting your application and running your serializers, GlobalID
  locators and `deserialize` overrides executes *your* code, which can do
  anything. Only check fixtures against code you trust.
- Fixtures are data, but deserializing them calls whatever serializer or
  locator classes they name. Treat fixture files like code: review them and do
  not check untrusted fixtures.
- `snapshot` evaluates your cases file, which may create database records
  (for example `find_or_create_by!`) in the environment it boots.
- The default environment is `test`. `production` is never booted implicitly;
  passing `--environment production` prints a warning. Do not point jobpayload
  at production databases. Note that a `DATABASE_URL` set in your shell is
  still used by Rails in the `test` environment.

## Development

```sh
bundle install
bundle exec rake test     # Minitest; randomized order
bundle exec rake build    # pkg/jobpayload-0.1.0.gem

# Another Active Job version:
BUNDLE_GEMFILE=gemfiles/activejob_7.2.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/activejob_7.2.gemfile bundle exec rake test
```

The test suite boots small Rails-free applications from `test/apps` (Active
Job + Active Record on in-memory SQLite) in subprocesses: `v1` writes baseline
fixtures, `v2_compatible` and `v2_breaking` model later versions of the same app.

Tests that need file names which are not valid UTF-8 probe the file system
of their own temporary directory and are skipped, with the reason, only when
it rejects such names (as on macOS).

CI runs:

- **Linux matrix** (`.github/workflows/ci.yml`): the full suite for every
  supported Ruby / Active Job combination above.
- **macOS smoke test** (same workflow): the full suite on Ruby 3.4 / Active
  Job 8.1.
- **Rails edge** (`.github/workflows/rails-edge.yml`, on pull requests,
  weekly and on demand): GlobalID classification regression tests
  (`test/edge`) against Rails `main` (`gemfiles/rails_edge.gemfile`), as a
  separate workflow and check. This is an early warning about upstream
  changes, not a supported version; its result is independent of the matrix
  above, and a failure is reported as a failure.

```sh
BUNDLE_GEMFILE=gemfiles/rails_edge.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/rails_edge.gemfile bundle exec rake test:rails_edge
```

## License

MIT. See [LICENSE](LICENSE).
