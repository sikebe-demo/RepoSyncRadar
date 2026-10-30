# RepoSyncRadar Copilot Instructions

RepoSyncRadar is a Windows desktop app for monitoring `github/docs` Repo sync PRs, triaging important documentation changes with the GitHub Copilot SDK, previewing rendered docs changes, and generating sharing drafts for Twitter and customer-facing notices. The solution is C#/.NET with WPF, BlazorWebView, MudBlazor, WebView2, EF Core SQLite, Octokit, and `GitHub.Copilot.SDK`.

Use these repository instructions as the starting point. When code or validated behavior contradicts them, follow the verified source and update this file after confirming the rule is stable.

## Layout

- `src/RepoSyncRadar.App`: WPF startup assembly, Blazor components, Copilot SDK orchestration, preview coordination, app settings, authentication, and UI CSS under `wwwroot/css/app.css`.
- `src/RepoSyncRadar.Core`: EF Core models and `RadarDbContext`, options, service interfaces, GitHub/docs API clients, preview rendering utilities, path-to-URL resolution, and sanitization helpers.
- `tests/RepoSyncRadar.App.Tests`: bUnit/component tests, Copilot workflow tests, auth tests, preview tests, and style/contrast tests.
- `tests/RepoSyncRadar.Core.Tests`: model, data, service, resolver, preview rendering, and sanitization tests.
- `tests/RepoSyncRadar.Integrations.Tests`: integration tests for external-facing service behavior.
- `tests/RepoSyncRadar.App.E2E.Tests`: Playwright/WebView-oriented end-to-end tests. Manual tests are marked with `Category=Manual`.
- `docs`: design, usage, implementation plan, and migration notes. Read `docs/DESIGN.md` for product intent and `docs/USAGE.md` for user-visible behavior.

## Build And Test

- The pinned SDK is in `global.json`: .NET SDK `11.0.100-rc.3.26522.148` with `rollForward: latestFeature`, `allowPrerelease: true`, and the `Microsoft.Testing.Platform` test runner.
- Restore/build from the repo root. Prefer PowerShell on Windows.
- Validate ordinary changes with:
  - `dotnet build RepoSyncRadar.sln -warnaserror`
  - `dotnet test RepoSyncRadar.sln --timeout 10m -- --filter-not-trait Category=Manual`
- Validate GitHub Actions workflow changes with `./scripts/Invoke-WorkflowLint.ps1`; CI installs the ghalint version tracked in `tools/ghalint/go.mod` so Dependabot can update it. Only the exact compiler-owned preview watcher lock is excluded from ghalint (compiler-required telemetry env, timeouts, and publication credentials); its pinned regeneration/freshness and `Test-PreviewCompatibilityWorkflow.ps1` policy checks remain mandatory. Review generated diffs on compiler updates.
- Workflow dependencies use `.github/workflows/actions.lock`. After changing workflows or local actions, regenerate locally with `gh actions-lock --no-narrow` and validate with `gh actions-lock --verify` using `github/gh-actions-lock` `v0.2.0`; CI does not install or run the extension. `--no-narrow` preserves gh-aw's compiler-generated SHA refs so recompilation remains identical. Never edit the lockfile by hand. Keep `.github/ghalint.yaml` SHA-rule exceptions limited to explicitly migrated actions; the lockfile supplies their immutable commits and repository identities.
- The APM CLI used by `.github/workflows/apm-update.yml` is pinned in `tools/apm/requirements.txt`; Dependabot manages that pip dependency, and the workflow must install from this file.
- Preview compatibility automation is opt-in; see `docs/PREVIEW_COMPATIBILITY_WATCHER.md`. Edit its workflow Markdown and compile with the version pinned in `tools/gh-aw/go.mod`; never hand-edit the generated `.lock.yml` or `.github/aw/actions-lock.json`. Workflow Markdown changes must run CI even though ordinary documentation-only edits can skip it.
- For focused test runs under xUnit v3/Microsoft.Testing.Platform, put filters after `--`. Examples:
  - `dotnet test tests/RepoSyncRadar.App.Tests/RepoSyncRadar.App.Tests.csproj -- --filter-class RepoSyncRadar.App.Tests.Components.AppHeaderTests`
  - `dotnet test tests/RepoSyncRadar.App.E2E.Tests -- --filter-trait Category=E2E`
- Do not use legacy `dotnet test --filter "Category!=Manual"`; this repo uses Microsoft.Testing.Platform and that form can produce MTP warnings or failures.
- If App.Tests appears stale or keeps reporting an old selector, run `dotnet clean tests/RepoSyncRadar.App.Tests/RepoSyncRadar.App.Tests.csproj` and retry the focused test.
- Some tests locate the repo root from `AppContext.BaseDirectory`; when avoiding locked `bin/`, use repo-local ignored `artifacts/...` output paths, not `%TEMP%`.

## Coding Rules

- Warnings are errors. `Directory.Build.props` enables nullable, analyzers, .NET 10 recommended analysis, SDK vulnerability/EOL checks via `CheckSdkVulnerabilities`, and code style enforcement. Keep the analyzer baseline stable during .NET 11 previews unless the PR intentionally addresses the resulting style churn.
- The app/package version is managed by `RepoSyncRadarVersion` in `Directory.Build.props`. The GitHub Actions release workflow reads that property and is intentionally manual-only (`workflow_dispatch`), so tag pushes or manually publishing an existing GitHub Release must not trigger another release build. Local one-off packaging may override it with `-p:RepoSyncRadarVersion=<semver>` through `scripts/Build-VelopackRelease.ps1`; do not set ad hoc `<Version>` values in individual projects.
- Official release assets are installer/update-feed only: pass `-NoPortable -NoLegacyManifest` to `scripts/Build-VelopackRelease.ps1` so unvalidated portable bundles and legacy Squirrel `RELEASES-*` manifests are not published.
- `scripts/Build-VelopackRelease.ps1` defaults to `-PublishMode SelfContainedPartialTrim`, which bundles .NET and asks Velopack to bootstrap only WebView2. It is not Native AOT; it uses the unsupported WPF partial-trim workaround from dotnet/wpf#3811 and needs installed-package smoke validation before broad use. Keep this mode multi-file and copy `ijwhost.dll` beside WPF's `DirectWriteForwarder.dll`; .NET 11 Preview 5 single-file payloads fail installed WebView E2E startup with `DirectWriteForwarder.dll` load errors. Pass `-PublishMode FrameworkDependent` only for explicit shared-runtime comparison builds.
- Velopack packages should explicitly pass `--icon src/RepoSyncRadar.App/Assets/AppIcon.ico` and `--shortcuts StartMenuRoot`, and installed-package smoke must verify both `current\RepoSyncRadar.exe` and the Start Menu shortcut so Windows search can find the installed app.
- Installed-package smoke cleanup must run the Velopack uninstaller before deleting `%LOCALAPPDATA%\SIkebe.RepoSyncRadar`; removing files directly can leave an orphaned Installed apps registry entry without a searchable Start Menu shortcut. Because the smoke package uses the production Velopack identity, `Test-VelopackInstalledE2E.ps1` must refuse to run when a local installation already exists unless the caller explicitly passes `-AllowLocalInstalledAppReplacement`; prefer a disposable Windows environment.
- GitHub Releases are treated as immutable once published. The Release workflow uploads Velopack assets without `--clobber`, uses draft releases for asset attachment, and can publish an existing asset-bearing draft only after validating the expected asset names. Its preflight needs `contents: write` because a read-only `GITHUB_TOKEN` cannot see draft releases; only an explicit HTTP 404 means the release is absent. Correct bad published assets with a new `RepoSyncRadarVersion` and tag.
- Write git commit messages in English.
- Before creating or updating a pull request, read `.github/pull_request_template.md` and use every section in the PR body. Keep PR descriptions in English, and resolve each validation line by checking it or replacing it with `N/A - <reason>`. When the PR closes or resolves an issue, include the matching `Closes #...`, `Fixes #...`, or `Resolves #...` line explicitly in the Related Issues section.
- Logging must use source-generated `[LoggerMessage]`. Do not call `_logger.LogDebug/LogInformation/LogWarning(...)` extension methods directly. Use `partial sealed class` methods such as `private static partial void LogXxx(ILogger logger, ...)`.
- In xUnit tests, pass `TestContext.Current.CancellationToken` when calling cancellable APIs. For NSubstitute `Received`/`DidNotReceive`, use `Arg.Any<CancellationToken>()` or the real token.
- WPF E2E fixtures should pass a dummy `COPILOT_GITHUB_TOKEN` into the App child process so eager startup sign-in does not enter GitHub OAuth Device Flow on CI.
- E2E hosts must isolate the DPAPI store with `REPOSYNCRADAR_GITHUB_TOKEN_PATH`. Signed-in UI tests also need a dummy stored token and configured OAuth client ID; `COPILOT_GITHUB_TOKEN` alone does not set the UI auth state.
- Automated policy UI tests must not send fixture tokens to live `managedSettings.resolve` endpoints. Keep WebView availability checks offline; verify policy success, failure, and redaction with injected component-test responses.
- Keep every WPF/WebView2 E2E class in the shared `E2ETests` collection backed by `SeededAppHostFixture`. Starting separate app hosts in one test run can leave WebView2 process state behind and make a later CDP endpoint time out.
- A WebView2 CDP endpoint answering `/json/version` does not mean Blazor has rendered. `SeededAppHostFixture` waits for the shell once via `E2EPageHelpers.GetBlazorPageAsync`, which rescans contexts/pages and allows a multi-minute cold-start budget; do not shrink that budget to a few tens of seconds or CI runners will fail intermittently with "Blazor page not found over CDP".
- Keep the WPF Dispatcher running while asynchronously stopping and disposing the generic host. Cancel the first `MainWindow.Closing`, finish host cleanup, then close again; awaiting host disposal from `Application.OnExit` can deadlock WebView/DI cleanup and leave `dotnet run` running after the window disappears.
- Automated WPF/WebView2 tests should use `Category=E2E` only; reserve `Category=Manual` for human-operated smoke tests, not automated E2E gates.
- PR CI and release packaging should smoke-test the installed win-x64 Velopack package by setting `REPOSYNCRADAR_E2E_APP_EXE_PATH` to the installed `current\RepoSyncRadar.exe` before running the WebView E2E tests.
- App internals are already visible to `RepoSyncRadar.App.Tests` through `InternalsVisibleTo` in the App project.
- Projects hosting the native Copilot runtime must reference `GitHub.Copilot.SDK` directly. Build targets invalidate untracked native aliases and publish targets refresh the complete bundle when the bundled version changes because equal archive timestamps and file lengths can retain older payloads even with a direct reference. Cover repeated publishing into the same directory, not just clean output. Verify `copilot_runtime.dll` against the adjacent `runtime.node` hash and `GetStatusAsync().Version`, not just ping; remove the workaround when upstream refreshes aliases reliably.
- `Microsoft.NET.Sdk.Razor` does not implicitly include `System.IO` or `System.Net.Http`; add explicit `using` directives when using `File`, `Path`, `Directory`, `IOException`, `HttpClient`, or `HttpResponseMessage`.
- Do not add `System.Security.Cryptography.ProtectedData` as a package; it is already available in the target framework. Use `[SupportedOSPlatform("windows")]` where DPAPI requires it.
- Avoid `using var _ = ...`; `_` is a real variable in that context and can conflict with later discard assignments.
- C# 15 union types are enabled with `LangVersion=15.0`. Use them only for small closed internal payload choices where exhaustive pattern matching removes duplicated event/result handling.
- Runtime Async is enabled repository-wide through `Features=runtime-async=on`. If an individual method reports `CS9328`, prefer a documented `RuntimeAsyncMethodGeneration(false)` opt-out on that method over disabling the feature globally.
- Before finishing C# edits, check language-server diagnostics or run a focused build so IDE naming rules such as IDE1006 are caught before handoff.

## Copilot SDK And Auth

### SDK API

- The app must read Copilot SDK final assistant text from `response?.Data?.Content`, not `response?.ToString()`.
- For Copilot tool metadata such as `skip_permission` and `defer`, prefer `CopilotTool.DefineTool(..., new CopilotToolOptions { ... }, ...)` over magic-string `AdditionalProperties`. Keep RepoSyncRadar's small radar tool set pre-loaded with `CopilotToolDefer.Never`.
- Restrict sessions to the registered radar tools and explicitly disable all skills with `EnableSkills = false` as well as tool search, ambient custom instructions, repository-origin file hooks (`EnableFileHooks = false`), org-level custom agents, coauthor trailers, scheduler integration, experimental mode, session memory, and the cross-session store unless a feature deliberately needs them. Leave `SessionConfig.TrustWorkingDirectory` unset; trusting the workspace lets the runtime load repository hooks and hook settings. `IncludedBuiltinSkills = []` alone excludes only bundled skills, not ambient or provider-backed skills. Inject managed permission settings that disable bypass and AI-assisted permission approval, and deny shell access, so user-owned approval remains manual.
- Keep experimental API warning suppressions local to the integration that requires them.
- Leave `SessionConfig.ExcludedManagedSettings` unset so fetched, device, and policy-helper restrictions are not selectively bypassed; app-injected permissions remain separate.
- RepoSyncRadar uses `RuntimeConnection.ForInProcess()` exclusively; it does not support per-client SDK `Telemetry`, `Environment`, or `WorkingDirectory`. Verify native runtime startup, a model turn, and shutdown in installed-package smoke before a release.
- Keep session file-change tracking disabled until RepoSyncRadar has a user-visible rewind flow; current radar tools do not edit workspace files.
- Treat SDK capabilities as unavailable until confirmed in the installed package's public API. Do not rely on runtime internals or prompt-only structured-output guarantees.
- Promote `model.call_final_result` failure codes only for root `session.error` events with `errorType: "query"`; consume the pending result so unrelated errors cannot reuse it.
- Managed-policy UI must use safe display DTOs, distinguish missing from empty/false, preserve per-source allowlist intersection, and cover the bundled runtime schema. Use SDK effective model/effort/context/Fusion values and per-control provenance; never replace an explicit `unmanaged` with legacy Auto. Label runtime `fusionTier` projections from legacy Auto when the returned layers establish that no layer supplies `fusionTier`; do not infer that origin when layers are absent. Policy preferences do not prove execution support. Redact originally requested values through the same allowlist. Bound each entry to 32 values plus one trailing omission marker across nested values and sources. Show app-injected restrictions separately using the shared session configuration, not a duplicated policy definition.
- The SDK downloads a SHA-256-verified GitHub Release native runtime bundle. Published builds must preserve every SDK-generated runtime asset, including `copilot_runtime.dll`, `runtime.node`, hidden marker files, and nested runtime dependencies; a standalone `copilot.exe` is not a substitute.

### Client And Telemetry

- Wire configured diagnostics through SDK options, and report session usage from SDK events/metrics. The in-process transport rejects client-level `Telemetry`; never log tokens, prompts, or responses.
- Report AI Credits only from SDK usage events (`CopilotUsage.TotalNanoAiu`) or session metrics. The SDK has no metrics event/call coverage boundary, and usage may arrive after idle: never add events to cumulative metrics by arrival time. Retain cumulative event totals independently of the 50-record history, deduplicate by session/call ID (event ID fallback), and use per-session per-counter maxima as conservative observed totals. Incomplete event history can temporarily underreport later usage until metrics refresh succeeds. Request versions reject stale/pre-reset metrics responses only; they do not establish coverage. Never estimate from model pricing.

### Auth Resolution

- `CopilotSessionFactory` auth resolution order is `COPILOT_GITHUB_TOKEN` debug override, in-memory cache, `IGitHubTokenStore` DPAPI store, then GitHub Device Flow. Do not read `GH_TOKEN` or `GITHUB_TOKEN` for Copilot auth.
- Release builds should ship a public, non-secret `Copilot:OAuthClientId` in `appsettings.json`; users only override it for forks or organization-managed OAuth Apps.
- Always set `CopilotClientOptions.UseLoggedInUser = false` so the app does not depend on global GitHub sign-in state.
- If `OAuthClientId` is missing and there is no stored or env token, fail clearly with `InvalidOperationException` rather than silently falling back.

### Triage Workflow

- Morning Triage is triggered from `AppHeader` through `ICopilotAgent.RunMorningTriageAsync()`. Triage/Maintenance sessions register `RadarTools.CreateAll()` and `RadarWriteTools.CreateAll()`; write-like tools are permission-gated except `radar_score_commit`, which `RadarPermissionPolicy` pre-approves for scoring persistence. Final review decisions (`radar_save_review`) are user-owned and must not be auto-written by Morning Triage, but registered Ignore rules still auto-mark future matching commits as `Rejected` during ingestion.
- `radar_score_commit` auto-marks still-unreviewed commits with score `0.44` or lower as `ReviewStatus.Rejected` with reason `auto-low-score`. Do not overwrite user-owned review states such as `Adopted`, `Later`, `Archived`, or existing `Rejected` rows.
- Triage sends need the longer `MorningTriageSession.TriageSendTimeout` through `ICopilotSession.SendAsync(prompt, timeout, ct)`; the SDK default one-minute wait is too short.
- Adoption draft/explanation generation needs `AdoptionSession.DraftSendTimeout`; docs diffs plus URL fetches can exceed the SDK default one-minute wait and leave regenerated drafts empty.
- Adoption drafts require SDK typed structured output for every selected model, including fallback models. Validate returned fields before persisting, and surface errors rather than silently resending failed structured turns.

## UI And Product Behavior

- Keep WPF/Blazor UI dense, operational, and scannable. This is an internal work tool, not a marketing page.
- Match existing CSS and component patterns before adding new abstractions. Do not nest decorative cards inside cards.
- For user-facing sharing drafts, Twitter and customer-facing text must include official `docs.github.com` URLs when a publishable docs URL is known. If Copilot omits the URL, preserve safety by appending it before saving.
- Commit detail should show the useful first commit message line only. Do not surface `Co-authored-by`, `Signed-off-by`, `Reviewed-by`, or `Acked-by` trailers as prominent UI text.
- Copilot usage UI must label units explicitly: AI Credits as `credits`, Premium Request cost as `PR`, request counts as `requests`, and token counts as `tokens`.
- Copilot usage UI should show AI Credits only from SDK usage events or `Usage.GetMetricsAsync()` session metrics; when SDK AI Credits are absent, leave credits unreported rather than estimating from a model pricing table.
- For Copilot fallback models, prefer currently supported non-retiring models. Check GitHub Changelog plus the supported-models docs before hardcoding model IDs; avoid `GPT-4.1`, `GPT-5`, `GPT-5.2`, and `GPT-5.2-Codex` as preferred fallbacks because they are retired or scheduled for retirement.
- Never switch Copilot models silently. When `CopilotSessionFactory` activates a process-wide fallback model, publish it through `ICopilotModelFallbackTracker` so the header and Settings Copilot usage show the configured model, fallback model, time, and purpose until restart.

## Preview And WebView

### Preview Infrastructure

- Official `docs.github.com` may already match a Repo sync PR if deployed. Visual comparison should use local preview of parent SHA vs PR HEAD, not production pages.
- Markdown preview should use existing `PreviewCoordinator`, `DocsWorktreeManager`, `LocalPreviewContentServer`, and `PreviewPortAllocator` patterns instead of ad hoc git/object reading or local HTTP hosting. `NextDevServerProcessCleaner` remains only for cleaning up legacy worktrees that may be locked by old Next dev servers.
- Startup docs preview prewarm is opt-in via `DocsRepository:PrewarmOnStartup`; the default must not clone/fetch `github/docs` until a preview action or predictive prewarm needs it.
- After a Markdown comparison opens, pre-render only the next previewable file and keep the speculative HTML cache bounded. Predictive file rendering must not replace the pages or asset roots currently hosted by `LocalPreviewContentServer`.
- A changed reusable can affect multiple `content/**/*.md` pages. Reusable preview must expose every discovered usage page instead of silently choosing only the first, and version changes must preserve the selected usage page.

### WebView2 Behavior

- WebView2 `Source` assignment is a no-op for identical URIs. Markdown preview URLs must include content-affecting dimensions such as docs version and file path in the query. `LocalPreviewContentServer.NormalizeRoute` strips query strings for route lookup.
- The right-pane WebView opens GitHub PR/commit pages and may also host GitHub.com Copilot Chat. Keep `WebView.AllowedUrlHosts` separate from Copilot tool URL permissions, and include the GitHub Copilot Chat API hosts (`api.githubcopilot.com`, `api.business.githubcopilot.com`, and `api.enterprise.githubcopilot.com`) so chat preflight requests are not blocked as `Chat failed to load`.
- WebView2 may raise stale `NavigationCompleted` failures such as `ConnectionAborted` for a previous navigation after the app has already started a new one; gate completion handling by `NavigationId` when showing load-failure overlays, and do not accept completions before the expected `NavigationId` is known. For GitHub single-page loads, retry transient `ConnectionAborted` / `OperationCanceled` once via `about:blank`.
- Synchronized preview scrolling must refresh its local `lastScrollTop` after every programmatic peer scroll. Disable browser scroll anchoring, apply identical wrapping to corresponding code blocks before measuring gaps, hide entire synthetic table rows while remeasuring, keep synthetic gap cells at `width: auto` so they do not redistribute table columns, correct table-gap height from the anchor's actual post-insertion displacement, and reconcile both panes to the lower post-layout `scrollTop`; otherwise resize reflow or clamping can leave the panes at different positions. Initial and user-requested diff navigation may calculate target centers independently, but must reconcile both panes to one absolute `scrollTop` before committing the navigation. Diff navigation overlays must not extend vertically beyond their targets into adjacent callouts.
- Wide preview `table`/`pre` blocks keep their own overflow box. The renderer pins a proxy horizontal scrollbar (`#rsr-horizontal-scrollbar`) while the block's native scrollbar is below the viewport, and cross-pane horizontal sync maps the same element kind/index only when both panes have equal counts, recording applied offsets so the peer scroll is not echoed back.
- For WebView2 UI validation, connect directly to the app's CDP endpoints instead of assuming Node Playwright is installed. Use the `REPOSYNCRADAR_BLAZOR_CDP_PORT` and `REPOSYNCRADAR_DOCS_CDP_PORT` targets with the Chrome DevTools Protocol to inspect/click the Blazor shell and docs preview DOM.
- For preview UI regressions tied to a specific commit, validate in the real app with `REPOSYNCRADAR_BLAZOR_CDP_PORT` and `REPOSYNCRADAR_DOCS_CDP_PORT`: select the exact commit row, open `WebView2 で開く`, inspect the docs WebView DOM for the reported artifact, and capture a screenshot under `artifacts/` before claiming the fix works.

### Markdown/Liquid Rendering

- Markdown/Liquid preview should mimic github/docs rendering. Render `{% octicon "name" ... %}` as Primer Octicons inline SVG with appropriate classes/attributes. Preserve data tag indentation, alert blocks, tool/platform blocks, prompt blocks, code tab blocks, and Copilot links where practical.
- Keep Markdown table cells top-aligned to match github/docs and prevent row labels from centering in tall rows. Keep inline diff spans inline inside cells; blockifying each span breaks text flow and inflates table rows.
- Markdown comparison preview should read Markdown and referenced Liquid inputs from the bare clone by SHA (`git show`/`git ls-tree`) instead of creating full worktrees. For binary or static assets referenced by Markdown, extract only the needed files from the same commit into the preview asset cache so screenshots do not break.
- Markdown preview Liquid context must stay lazy but complete for the clicked file: load referenced reusables, AUTOTITLE targets, and referenced `data/**/*.yml` sequence files used by `for` loops such as `tables.copilot.models-and-pricing`; do not fall back to all-repo reusable/content scans for interactivity.
- Markdown preview should also load referenced `data/tables/**/*.yml` mapping objects and the GHES `enterpriseServerReleases` object when pages use Liquid mapping loops, `assign`, `case/when`, dynamic bracket lookups, or release-date tables.
- Markdown preview `ifversion` evaluation should load referenced `data/features/*.yml` files so known feature flags use their real `versions` mapping; unknown feature flags should remain conservatively visible.
- Rewrite relative and root-relative links in rendered Markdown to version-aware official `docs.github.com` URLs; never leave page links targeting unregistered localhost preview routes.
- Rendered Markdown comparison should show a visible marker in both panes when possible; for pure additions/removals, use a small gap marker at the stable adjacent text on the side where the changed prose is absent.

### Cache And Theme

- Cache cleanup should detach/rename large worktree directories quickly and let physical deletion continue in the background so the Blazor UI is not blocked by hundreds of MB of file deletes.
- Dark-theme docs preview must keep text readable; diff highlights should be low-alpha tints with borders/outlines and `color: inherit`.

## Maintaining These Instructions

- Treat this file as living repository knowledge. During normal work, if you discover a repo-wide rule, command, SDK behavior, test workaround, UI convention, or failure mode that would save future agents time, update this file in the same change when it is stable and broadly useful.
- Treat invoked skills as living workflow knowledge too. If a task exposes a stable improvement, missing guardrail, or recurring pitfall in a relevant `.github/skills/*/SKILL.md`, update that skill in the same change without waiting for an explicit request.
- Keep additions concise and non-task-specific. Do not record one-off task details, secrets, machine-local absolute paths beyond repo examples, or temporary failures that are unlikely to recur.
- Prefer updating an existing bullet over adding a duplicate. Remove or correct instructions that become false.
- After changing this file, run at least a focused validation relevant to the change. For code changes in the same task, still run the normal build/test gate above.
