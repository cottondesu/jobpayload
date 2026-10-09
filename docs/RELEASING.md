# Releasing jobpayload

Releases are published by `.github/workflows/release.yml` when an annotated
`vMAJOR.MINOR.PATCH` tag is pushed for the current head of `main`. The
workflow tests the supported matrix, builds the gem twice and requires
byte-identical results, waits for a maintainer to approve the `release`
environment, pushes that exact gem to RubyGems with Trusted Publishing (OIDC,
no API key), checks the gem RubyGems serves, and only then creates the GitHub
release from the committed release notes.

The checks themselves live in `script/release/release_guard.rb` and are tested
by `test/release/release_guard_test.rb`.

> **Status:** the workflow refuses to publish until the one-time setup below is
> complete (GitHub environment, `RELEASE_GATE_READY`, RubyGems trusted
> publisher). A missing or unprotected environment fails the first job, before
> anything is tested or built. A missing `RELEASE_GATE_READY` or an
> unregistered trusted publisher is caught in the `publish` job, after
> approval and before `gem push`. Either way nothing is published.

## Contents

1. [Prerequisites](#1-prerequisites)
2. [GitHub environment and approval](#2-github-environment-and-approval)
3. [RubyGems trusted publisher](#3-rubygems-trusted-publisher)
4. [How the two must match](#4-how-the-two-must-match)
5. [Version bump](#5-version-bump)
6. [CHANGELOG](#6-changelog)
7. [Release notes](#7-release-notes)
8. [CI on the pull request](#8-ci-on-the-pull-request)
9. [Merge to main](#9-merge-to-main)
10. [Create and push the annotated tag](#10-create-and-push-the-annotated-tag)
11. [Approve the deployment](#11-approve-the-deployment)
12. [Check the gem RubyGems serves](#12-check-the-gem-rubygems-serves)
13. [Check the GitHub release](#13-check-the-github-release)
14. [Partial failures](#14-partial-failures)
15. [No API keys](#15-no-api-keys)
16. [Next releases](#16-next-releases)

Appendices: [workflow jobs](#appendix-a-workflow-jobs),
[tag policy](#appendix-b-tag-policy), [what each failure means](#appendix-c-checks).

## 1. Prerequisites

- Maintainer (admin) access to `cottondesu/jobpayload` and owner access to the
  `jobpayload` gem on rubygems.org.
- The one-time setup in sections 2 and 3, done once and left in place.
- A clean local clone of `main` with `git` able to create annotated tags.

Nothing else: no RubyGems API key, no GitHub secret, no local `gem push`.

## 2. GitHub environment and approval

Do this in **Settings → Environments** of `cottondesu/jobpayload`. Naming an
environment in a workflow does *not* protect it: if `release` does not exist,
GitHub creates it on the first run **without** any protection rules. The
workflow therefore checks the environment itself (job `validate`) and refuses
to continue unless all of the following hold.

1. **New environment** → name `release`.
2. **Required reviewers** → add `cottondesu`.
   - Leave **Prevent self-review** *off*. You push the tag and you are the only
     reviewer; with it on, nobody could approve and the workflow stops with
     "nobody could approve the deployment".
   - Turn **Allow administrators to bypass configured protection rules** *off*
     (recommended). The workflow only warns when it is on.
3. **Deployment branches and tags** → **Selected branches and tags** → **Add
   deployment branch or tag rule** → Ref type **Tag**, pattern `v*`. Add no
   branch rules. The workflow fails if any branch rule exists, if a tag rule
   does not start with `v`, or if deployments are open to all refs.
4. **Environment variables** → add `RELEASE_GATE_READY` = `true`, **last**,
   after steps 1–3 and section 3 are done.
   - Define it **only** on the `release` environment. The workflow fails if it
     is visible as a repository or organization variable.
   - It is a kill switch, not an approval: it does not replace required
     reviewers. Delete it (or set it to anything else) to stop publishing
     without touching the workflow.

Optional, recommended: a repository **ruleset** targeting tags `v*` that
restricts updates and deletions, so a release tag cannot be moved. The
workflow detects a tag that moves during a run, but cannot prevent it.

## 3. RubyGems trusted publisher

On rubygems.org, open the `jobpayload` gem → **Trusted publishers** → **Create**
→ GitHub Actions, with exactly:

| Field | Value |
| --- | --- |
| Gem | `jobpayload` |
| Repository owner | `cottondesu` |
| Repository name | `jobpayload` |
| Workflow filename | `release.yml` |
| Environment | `release` |

This is the same mechanism `cottondesu/jobcompat` uses
(`rubygems/configure-rubygems-credentials`). The gem keeps
`rubygems_mfa_required`; RubyGems accepts pushes from a trusted publisher for
such gems. If it ever does not, the `gem push` step fails and nothing is
published (see section 14).

## 4. How the two must match

RubyGems only issues a key when the OIDC token GitHub signs for the run
matches the trusted publisher: owner `cottondesu`, repository `jobpayload`,
workflow file `.github/workflows/release.yml` and environment `release`.

- Renaming the workflow file, the environment or the repository breaks
  publishing until the trusted publisher is updated. That is intended.
- Only the `publish` job has `id-token: write`, and only it runs in the
  `release` environment, so only an approved `publish` job can obtain a key.
- The action runs with `trusted-publisher: "true"`: there is no fallback to a
  stored key. If the exchange fails, the job fails.

## 5. Version bump

On a branch, change `lib/jobpayload/version.rb`:

```ruby
VERSION = "0.3.0"
```

The tag `vX.Y.Z`, `JobPayload::VERSION` and the gemspec version must be equal;
the workflow checks all three.

## 6. CHANGELOG

Add a `## X.Y.Z` section at the top of `CHANGELOG.md`.

## 7. Release notes

Add `docs/releases/vX.Y.Z.md` in the same pull request. Its first line must
be a heading that names the tag, as in `docs/releases/v0.2.0.md`:

```markdown
# jobpayload v0.3.0
```

The file must be in the tagged commit. The GitHub release body is this file,
verbatim, and its title is the version (`0.3.0`).

## 8. CI on the pull request

Open a pull request with the version bump, the CHANGELOG and the release notes.
CI must be green (Ruby 3.3 / 3.4 / 4.0 × Active Job 7.2 / 8.0 / 8.1 and the
macOS job). The Rails edge workflow is an early warning only and is not a
release gate.

## 9. Merge to main

Merge the pull request. Do not merge anything else before tagging: the tag must
point to the head of `main` (see [Appendix B](#appendix-b-tag-policy)).

## 10. Create and push the annotated tag

```sh
git switch main
git pull --ff-only
git log -1 --format='%H %s'          # the release commit, at the head of main
git tag -a v0.3.0 -m "Release v0.3.0" # annotated: -a (or -s), never a lightweight tag
git push origin v0.3.0
```

Pushing the tag starts the Release workflow. Push only that tag (not
`--tags`).

## 11. Approve the deployment

1. Open **Actions → Release** for the tag. `validate`, the nine Linux jobs,
   `macOS` and `Build and freeze gem` run first.
2. Read the run summary: the tag, commit and tree, the environment check, the
   frozen gem's SHA-256 and the package audit.
3. `Publish to RubyGems` waits for approval: **Review deployments** → `release`
   → **Approve and deploy**. Reject it to stop; nothing is published.

After approval the job re-checks the tag, `main`, RubyGems, the environment's
protection rules, that no published GitHub release exists, and the frozen gem,
before it pushes.

Before tagging, make sure no **draft** release exists for the tag: the
workflow's read-only token cannot see drafts, so a stray draft is only found
by `Create the GitHub release`, after the gem is published.

## 12. Check the gem RubyGems serves

`Verify the gem served by RubyGems` downloads
`https://rubygems.org/downloads/jobpayload-X.Y.Z.gem` and requires its SHA-256
to equal the frozen gem's (retrying read-only up to 12 times, 30 s apart, while
it propagates). To check by hand:

```sh
curl -fsSL https://rubygems.org/downloads/jobpayload-0.3.0.gem | sha256sum
curl -fsSL https://rubygems.org/api/v2/rubygems/jobpayload/versions/0.3.0.json | ruby -rjson -e 'puts JSON.parse($stdin.read)["sha"]'
```

Both must print the `.gem file SHA-256` from the build job's summary. (The
Actions artifact also has a digest; that is the digest of its zip archive, not
of the gem.)

## 13. Check the GitHub release

`Final verification` checks that the release exists for the tag, is neither a
draft nor a prerelease, is titled with the version, has the committed notes as
its body, and that RubyGems still reports the frozen SHA-256. Its summary links
the RubyGems version and the release.

## 14. Partial failures

The workflow never deletes or moves a tag, never yanks a gem and never pushes
a version twice. Re-running is safe where noted; **Re-run failed jobs** reuses
the frozen gem and the build's SHA-256, and `Publish to RubyGems` asks for
approval again.

| What happened | State | What to do |
| --- | --- | --- |
| A check before publishing failed (tag, version, environment, tests, build, audit) | Nothing published | Fix the cause. If the fix needs a new commit, delete the tag *only if nothing was published* (`git push origin :refs/tags/vX.Y.Z`), then tag the new head of `main`. |
| Approval rejected | Nothing published | Re-run when ready, or delete the tag as above. |
| `gem push` failed, job says it "appears nothing was published" | Tag kept, no gem, no release | Fix the cause (for example the trusted publisher), then **Re-run failed jobs**. |
| `gem push` failed or timed out, job says RubyGems has the frozen SHA-256 | Gem published, no release | **Do not push again.** Check the SHA (section 12), then create the release by hand (below). |
| `gem push` failed, RubyGems' state unknown | Unknown | **Do not push again.** Check RubyGems by hand (section 12) after a few minutes, then follow the matching row. |
| `Verify the gem served by RubyGems` could not download it | Gem probably published, no release | Check by hand (section 12). If it matches, **Re-run failed jobs** or create the release by hand. |
| `CRITICAL — PUBLISHED ARTIFACT MISMATCH` | RubyGems serves different bytes | Stop. Do not create the release, do not push again. Investigate (account, trusted publisher, RubyGems status). Yanking is a manual decision. |
| `Create the GitHub release` failed | Gem published and verified, no release | **Re-run failed jobs**, or create it by hand (below). Never push the gem again. |
| `Create the GitHub release` says a draft exists | Gem published and verified, no release | Delete the draft, then **Re-run failed jobs**. |
| `Version already on RubyGems` | Nothing published by this run | It says whether the published gem is byte-identical to this build. If identical and the release is missing, create it by hand. If different, treat it as CRITICAL. |

Creating the release by hand, for an existing tag, after the SHA check:

```sh
gh release create v0.3.0 --repo cottondesu/jobpayload --verify-tag \
  --title 0.3.0 --notes-file docs/releases/v0.3.0.md
```

`--verify-tag` makes `gh` refuse instead of creating a missing tag.

## 15. No API keys

There is no RubyGems API key anywhere: not in GitHub secrets, not in the
workflow, not on your machine for releases. The `publish` job refuses to run
if `GEM_HOST_API_KEY`, `RUBYGEMS_API_KEY`, `BUNDLE_GEM__PUSH_KEY` or a
RubyGems credentials file is present before the OIDC exchange, and never prints
the short-lived key it receives. Do not add a static key as a fallback.

## 16. Next releases

Once sections 2 and 3 are done, every release is sections 5–13: bump, notes,
pull request, merge, annotated tag, approve, check. Old tags are unaffected:
`v0.1.0` and `v0.2.0` point to commits without `release.yml`, so pushing them
again runs nothing, and the workflow would refuse them anyway (not the head of
`main`, already on RubyGems, release already exists).

## Appendix A: workflow jobs

```text
validate ──┬─> test (9 × Linux) ──┬─> build ──┬─> publish ──> verify-rubygems ──> github-release ──> final-verify
           └─> macos ─────────────┘           │   [environment: release, approval, OIDC]
                                              └─> duplicate-version (only if already on RubyGems; always fails)
```

| Job | Permissions | Does |
| --- | --- | --- |
| `validate` | `contents: read`, `actions: read` | Tag, version, release notes, environment protection, no GitHub release, RubyGems state |
| `test` (9) | `contents: read` | Supported matrix, randomized order, no unexpected skips (non-UTF-8 tests must run) |
| `macos` | `contents: read` | Ruby 3.4 / Active Job 8.1: file system portability, SecureFixtureReader, symlink, FIFO and race tests; only the APFS non-UTF-8 capability skips are allowed |
| `build` | `contents: read` | Two builds with `SOURCE_DATE_EPOCH` = commit time on pinned Ruby `BUILD_RUBY`, byte comparison, metadata, package audit, artifact upload |
| `duplicate-version` | `contents: read` | Read-only comparison with the published gem; always fails |
| `publish` | `contents: read`, `actions: read`, `id-token: write` | Gate, preflight (environment and release re-checked), OIDC exchange, one `gem push` |
| `verify-rubygems` | `contents: read` | Download from rubygems.org, compare SHA-256 |
| `github-release` | `contents: write` | `gh release create --verify-tag` with the committed notes |
| `final-verify` | `contents: read` | Tag, release and RubyGems agree |

Every job checks out the validated commit SHA (not the tag name) with
`persist-credentials: false`. Every action is pinned to a full commit SHA.
Workflow values reach shell scripts only through `env:`. Runs for the same tag
are queued, never cancelled (`cancel-in-progress: false`).

## Appendix B: tag policy

The tag must point to the **current head of `main`** when the workflow starts.
A tag on any older commit is refused, even if that commit is on `main`.

- Why strict: it rules out publishing an old commit by tagging it by mistake
  (or on purpose), and it means what is released is exactly what `main` shows.
- Cost: nothing else may be merged between merging the release pull request
  and pushing the tag. If something was, the workflow fails before building;
  delete the tag (nothing was published) and tag the new head.
- After approval, `publish` only requires that the commit is still in the
  history of `main` (other pull requests may have been merged while waiting),
  and that the tag still points to the same tag object and commit.

## Appendix C: checks

The workflow fails, before anything is published, when:

- the run is not a tag push in `cottondesu/jobpayload` (forks skip it);
- the tag is not `vMAJOR.MINOR.PATCH` (`v0.2`, `v0.2.1-beta`, `vtest` are refused) or is lightweight;
- the tag does not point to a commit, or not to the head of `main`;
- the tag, `JobPayload::VERSION` and the gemspec version differ, or the gem name is not `jobpayload`;
- `docs/releases/vX.Y.Z.md` is missing from the tagged commit or does not name the tag;
- the `release` environment is missing, has no required reviewers, is not limited to `v*` tags, or `RELEASE_GATE_READY` is outside it;
- a GitHub release for the tag exists;
- RubyGems cannot be read reliably (HTTP error, malformed JSON, the two APIs disagree);
- a test fails, or a test is skipped for a reason not on the allowed list;
- the two builds differ, or the package audit finds an unexpected file, a file that differs from the commit, a secret, or a dependency outside the tested matrix;
- the frozen gem's size or SHA-256 differs in the publish job;
- `RELEASE_GATE_READY` is not `true`, a static RubyGems credential is present, or the OIDC exchange gives no key.
