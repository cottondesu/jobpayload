# Changelog

All notable changes to this project are documented in this file.

## Unreleased

Changes on `main` that are not part of any released version yet.

### Added

- `jobpayload snapshot --check`: compares what the current code serializes for
  each snapshot case with the stored fixture, without writing anything.
  Statuses `identical`, `different` and `missing` (exit 1) and `invalid`
  (exit 2); the highest exit status wins. The whole `job` object is compared:
  the current payload normalized as `snapshot` writes it, the stored one as
  stored. `source` metadata, key order and whitespace are ignored. Cannot be
  combined with `--update`. Text and JSON (schema v1, `"mode": "check"`)
  output.

### Changed

- Tests and CI: macOS smoke test, capability-based skips for file names that
  are not valid UTF-8, and a separate Rails `main` GlobalID regression
  workflow. No change to runtime behaviour.

## 0.1.0

Initial release. The single question v0.1.0 answers is: *can the current
application deserialize this previously serialized Active Job payload?*

### Added

- `jobpayload snapshot`: evaluates snapshot cases declared with
  `JobPayload.define { fixture "name" { SomeJob.new(...) } }` and writes one
  JSON fixture per case from `ActiveJob::Base#serialize`.
  - Fixture schema v1 (`jobpayload_schema: 1`) with `name`, `source` versions and the
    serialized `job` hash.
  - Volatile metadata (`job_id`, `provider_job_id`, `enqueued_at`, `executions`,
    `exception_executions`, non-nil `scheduled_at`) is normalized to fixed values;
    custom keys added by a job's own `#serialize` are kept.
  - Byte-for-byte deterministic output: recursively sorted keys, fixed
    two-space layout independent of the json gem version, UTF-8, LF, final newline,
    atomic writes, fixtures processed in name order.
  - Existing fixtures are never overwritten unless `--update` is given.
- `jobpayload check`: boots the application once and, for every fixture, runs
  `ActiveJob::Base.deserialize` and `ActiveJob::Arguments.deserialize` on fresh
  copies of the payload. Jobs are never performed, enqueued or retried.
- Stable finding codes: `AJP001` fixture_invalid, `AJP101` unknown_job_class,
  `AJP102` job_deserialize_failed, `AJP201` argument_deserialize_failed,
  `AJP202` globalid_record_missing (inconclusive), `AJP900` environment_error.
- GlobalID records missing from the test database are reported as inconclusive
  (exit 0 by default, exit 1 with `--fail-on-inconclusive`). `AJP202` is only
  used when the failing argument is an Active Job GlobalID reference
  (`{"_aj_globalid": ...}`) and a record-missing exception is in the cause chain;
  any other argument failure is `AJP201`, even when `RecordNotFound` appears in
  the cause chain (for example a custom serializer's `find_by!`).
- Exception classification by class and cause chain (cycle-safe), not by message text.
- Failing argument location (`arguments[1]`, `arguments[0]["batch"][1]`, ...); every
  failing argument gets its own finding, so an inconclusive missing record cannot
  hide a breaking argument next to it.
- Text output and JSON output schema v1; `--debug` adds backtraces to text output.
  JSON vocabulary: top-level `status` is `pass` / `fail` / `tool_error`; fixture
  `status` is `pass` / `fail` / `inconclusive` / `tool_error`; finding `severity`
  is `error` (compatibility break) / `warning` (inconclusive) / `fatal`
  (tool/environment failure); `summary` counts `compatible`, `incompatible`,
  `inconclusive` and `tool_errors`. Exception messages, fixture file names and
  paths are always emitted as valid UTF-8.
- Exit codes: 0 compatible, 1 compatibility failure, 2 usage/configuration/boot/tool error.
- Options: `--boot`, `--environment` (default `test`), `--cases`, `--output`,
  `--fixtures`, `--update`, `--format text|json`, `--fail-on-inconclusive`, `--debug`.
- `require "jobpayload"` does not load Active Job; Active Job (and the json
  library) is only loaded after the host application has booted.
- Supported: Ruby 3.3, 3.4, 4.0 with Active Job 7.2, 8.0, 8.1.
