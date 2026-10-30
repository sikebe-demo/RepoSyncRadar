# Docs preview compatibility watcher

The optional `Docs preview compatibility` GitHub Agentic Workflow watches
`github/docs` main for changes that may exceed RepoSyncRadar's partial
Markdown/Liquid renderer. It is repository automation, not an app setting.
It is **disabled by default** and does not merge PRs or publish releases.

## Activation and credentials

After merging the workflow into the default branch, a repository administrator
must provision these Actions secrets separately:

| Secret | Purpose |
|---|---|
| `COPILOT_GITHUB_TOKEN` | Inference credential supported by the gh-aw Copilot engine, with access to an active Copilot subscription. |
| `GH_AW_CI_TRIGGER_TOKEN` | Dedicated credential with Contents write on this repository, used only by the PR safe-output handler for an extra empty commit. |

Use the least privileges and shortest lifetime appropriate to your account and
organization. Do not copy the desktop app's DPAPI token store into CI. The
ordinary `GITHUB_TOKEN` reads evidence and publishes safe outputs; PRs created
with it alone do not start ordinary PR CI. The dedicated extra-commit credential
addresses that restriction without exposing a write token to the agent.
Repository Actions settings must permit Actions to create pull requests.

Set the repository Actions variable `PREVIEW_COMPATIBILITY_ENABLED` to exactly
`true` only after both secrets are configured and live acceptance is authorized.
The collection job fails explicitly if either credential is absent. Disable
future runs by removing the variable or setting it to `false`; an already
running publication is not cancelled. No secret provisioning or billable live
execution is part of the checked-in implementation's offline validation.

## Daily runs, checkpoints, and recovery

The compiled schedule runs daily; Actions also exposes manual dispatch. Runs
are serialized without cancelling an in-flight run. Only the default branch
can activate the watcher.

The first active run records the current upstream SHA without invoking AI.
Subsequent runs compare that SHA with a single immutable resolution of upstream
main. Ordinary prose-only changes do not invoke the agent or threat-detection
inference. A run with candidates must pass agent execution, threat detection,
safe-output publication, and a trusted report/publication verifier before its
proposed checkpoint can be used by a later run.

Checkpoints are artifacts, not commits, app database rows, or caches. Restoration
checks the exact workflow, repository, branch, event, source SHA, run ID, schema,
successful collection, and (for nonzero candidates) successful verification.
Failed or cancelled runs never advance the baseline. If an Issue was created
before a later failure, the retry searches for and reuses it.

Manual dispatch inputs:

| Inputs | Behavior |
|---|---|
| Both `base_sha` and `head_sha` | Replay a full lowercase 40-character ancestor-to-descendant upstream range. Never advance the scheduled checkpoint. |
| `reset_baseline: true` | Explicitly discard unavailable history and record current upstream main, without analysis. Cannot be combined with replay inputs. |
| No inputs | Normal bootstrap/incremental behavior. |

Expired or missing state after previous collection, invalid provenance,
inaccessible API resources, divergent upstream history, and exceeded limits fail
closed. Do not repeatedly reset to make a run green: inspect the failure
artifact, split a large range into bounded manual replays, review their findings,
and only then intentionally reset the scheduled baseline if appropriate.
A reset discards analysis of the intervening upstream changes.

## Evidence, reports, and limits

The deterministic collector performs a blob-less, sparse Git fetch of
`github/docs` at fixed SHAs with hooks, filters, LFS smudging, and credential
prompts disabled. It never builds or executes upstream programs. It first builds
the base revision's **rendering vocabulary** from all `content/**/*.md` and
`data/**` Markdown/YAML: Liquid tag names, filters, comparison operators,
`data` reference roots, octicon names and options, non-feature `ifversion`
identifiers, frontmatter `versions` keys and `layout` values, alert kinds, code
fence languages, and lowercase HTML element names outside code. Changed files
at the head revision become candidates only for constructs absent from that
vocabulary. Separately, `data/tables/**` key-path/container structure changes
and added, deleted, or renamed `src/content-render/(liquid|unified)` source files
are candidates. Prose, row values, variable/reference targets, and new articles
that use only known constructs do not invoke inference. Unrelated upstream paths
(OpenAPI, GraphQL, app components) are excluded before limits apply.

This is a conservative heuristic, not a complete parser or a guarantee of
detecting every upstream incompatibility. A known construct used in a new
combination is not detected.

Live read-only measurement against real `github/docs` history (October 2026):
a 3-day range of 430 relevant files produced 1 candidate and a 30-day range of
1,095 relevant files produced 2 candidates (a new octicon and the addition of
Mermaid inline-SVG rendering), each in about 2–3 minutes on a Windows
workstation. The previous REST-based design failed or over-reported on the
same history.

| Artifact | Contents | Retention |
|---|---|---|
| `preview-compatibility-evidence` | Schema-2 `evidence.json`, or a sanitized `failure.json` when collection fails. Candidate fingerprints, kind/token, up to five pinned occurrences with short excerpts, renderer/test mappings, and range statistics. | 30 days |
| `preview-compatibility-checkpoint` | Trusted proposed `checkpoint.json`; eligible only after the required run/job successes. | 90 days |
| `preview-compatibility-report` | Agent `report.json` and `report.md`: dispositions, confidence, expected/observed behavior, minimal reproductions, commands/results, publication references, uncertainties, and pending Windows validation. | 30 days |

Limits are declared in `scripts/PreviewCompatibility.psm1`: 5,000 relevant
changed files, 30,000 scanned files, 4 MiB per file, 20 candidates, five
occurrences per candidate, 1 MiB evidence, and 15 minutes per Git operation.
Checkpoint discovery uses at most 200 API requests, 16 MiB of responses with a
30-second read timeout, and 500 historical runs across five pages. Checkpoint
ZIPs have one bounded `checkpoint.json` entry. Limits cause explicit failures
rather than truncated successful analysis.
Repository artifact-retention policies may shorten the configured retention.

Each candidate must have exactly one disposition: `supported`,
`intentional-fallback`, `confirmed`, or `unresolved`. Unknown tags and intentional
conservative version behavior are not automatically bugs. Unresolved cases,
missing report fields, omitted fingerprints, or missing requested publications
prevent checkpoint advancement. The verifier validates report structure and
GitHub publication existence; evidence quality and claimed test results still
require reviewer judgment.

## Issues, fixes, and review

At most one aggregated Issue and one related **draft** PR can be created per run.
Findings carry stable full SHA-256 fingerprints, upstream SHAs/permalinks,
affected renderers, reproductions, and expected/observed rendering. The agent
searches open and closed Issues and PRs, including semantic matches, before
publishing. A semantic match without a fingerprint is deferred to human triage,
not duplicated or edited. Supported cases remain report-only.

A draft fix requires a recorded failing regression test before the production
change and a passing test afterward. Publication is restricted to `.cs` files
directly under Core `Services/Preview` and its matching test directory, at most
8 files and a 128 KiB patch. No app UI, auth, instructions, dependencies,
workflows, release files, or human-owned PR branches may be changed.
Unsafe or unreproducible fixes remain Issue-only.

Linux focused Core tests do not establish Windows/WPF/WebView2 correctness.
Review the evidence, regression, PR template, and Windows CI (including
installed-package E2E); perform visual smoke for visual behavior. Partial fixes
reference an Issue without closing its remaining cases. Humans own approval,
merge, and release.

## Maintenance and acceptance

The compiler version is pinned in `tools/gh-aw/go.mod` and managed by Dependabot.
CI installs that exact gh extension release rather than building it from source.
Edit the authored
`.github/workflows/docs-preview-compatibility.md`, then compile with that exact
version. Never manually edit its generated `.lock.yml` or
`.github/aw/actions-lock.json`. The separate repository
`.github/workflows/actions.lock` is regenerated with gh-actions-lock v0.2.0.
Use `--no-narrow` so it preserves compiler-generated SHA refs rather than
rewriting them to version tags and making the compiler freshness check fail.
Workflow Markdown is executable instruction content and must run CI, unlike
ordinary documentation-only edits.

Offline checks from the repository root:

```powershell
./scripts/tests/Test-PreviewCompatibility.ps1
./scripts/tests/Test-CiChangeScope.ps1
gh aw compile docs-preview-compatibility --no-check-update
./scripts/tests/Test-PreviewCompatibilityWorkflow.ps1
./scripts/Invoke-WorkflowLint.ps1
gh actions-lock --no-narrow
gh actions-lock --verify
```

CI checks compiler-output freshness and compiled policy, in addition to the
fixture suites on Linux and Windows. Full solution/installed-app checks remain
on Windows.

The lint wrapper runs ghalint against all authored workflow YAML and local
actions, using the existing configuration. Only this watcher's exact generated
lock path is excluded. gh-aw v1.0.1 forces workflow-level telemetry-secret
references, omits activation/conclusion timeouts, and persists checkout
credentials in its privileged publication job; supported source settings cannot
make these pass ghalint. Do not hand-edit the generated file or disable lint
globally. Pinned compilation/freshness, dedicated compiled-policy assertions,
and actions.lock cover the generated workflow instead. This does not provide
every ghalint rule for generated code: review compiler-update diffs explicitly.
Do not configure the optional `GH_AW_DEFAULT_OTLP_*` settings without a separate
review of where telemetry and its credentials are sent.

Before production activation, separately authorize and observe live acceptance:
baseline-only/no-AI; no-candidate/no-AI; a confirmed finding; deduplicated replay;
draft PR CI startup; and failed-publication checkpoint preservation. The live
collector measurement above covers only candidate selection, not these Actions
runtime outcomes.
