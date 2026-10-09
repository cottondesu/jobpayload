# Changelog

All notable changes to this project are documented in this file.

## 0.2.0

0.2.0 adds snapshot drift detection. Everything 0.1.0 does is unchanged:
`snapshot`, `snapshot --update` and `check` behave as before, and the fixture
schema (`jobpayload_schema: 1`), the JSON output schema (`schema_version: 1`),
finding codes and exit codes are the same. There are no breaking changes.

### Added

- `jobpayload snapshot --check`: serializes every snapshot case with the
  current code and compares it with the baseline fixture already stored in
  `--output`, to catch unintended changes to the payloads new code enqueues.
  - **Read-only:** nothing in `--output` is written, created, renamed or
    deleted, not even a missing `--output` directory. Cannot be combined with
    `--update`.
  - **Comparison:** the whole `job` object, as canonical JSON. The current
    payload is normalized as `snapshot` writes it; the stored baseline is
    compared as stored (never re-normalized), so any edit to it, volatile
    metadata included, is reported. `source` metadata, key order, whitespace
    and equivalent JSON spellings are ignored; value types (`1` vs `1.0`) and
    array order are not.
  - **Statuses and exit codes:** `identical` (0), `different` (1), `missing`
    (1) and `invalid` (2); the highest exit status wins (2 > 1 > 0). A
    baseline is `invalid` when it is not valid schema v1 JSON, is a symbolic
    link (never followed), is not a regular file, cannot be read, or holds a
    `job` that `snapshot` could never have written. Fixtures with no matching
    case are ignored.
  - **Output:** deterministic text, or JSON (`schema_version: 1`,
    `"mode": "check"`). It reports whether each baseline differs, not where
    (no field-level diff).

### Security

- `snapshot --check` reads baselines in a way that resists the fixture's
  directory entry being replaced during the check: after `lstat`, the file
  is opened read-only with `O_NOFOLLOW` and `O_NONBLOCK`, verified with
  `fstat` to be the same regular file (device and inode), and read only from
  that descriptor. An entry swapped for a symlink, FIFO, directory or another
  file, or removed, is `invalid` (exit 2) and never read, so it cannot leak
  file contents into the output, block the check, or make it pass. Platforms
  without these flags fail closed. This protects the final path component
  only; see README "Race-safe baseline reading" for what is not covered.
  The hardening was made before `snapshot --check` was released, so no
  released version is affected. `jobpayload check` is unchanged (it reads by
  path and follows symbolic links, as in 0.1.0).

### Changed

- Internal: `JobPayload::Fixture.parse_content` parses fixture bytes the
  caller has already read; `Fixture.parse` keeps its behaviour and shares the
  same validation.
- Tests and CI (no runtime change): tests for `snapshot --check` and its
  race-safe reads (deterministic lstat/open races, FIFO deadlines, descriptor
  leaks, real-process runs); a macOS smoke job; capability-based skips for
  file names that are not valid UTF-8; and a separate Rails `main` GlobalID
  regression workflow (not a supported version).
- README: documents `snapshot --check`, its security boundaries and the
  updated version references.

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
