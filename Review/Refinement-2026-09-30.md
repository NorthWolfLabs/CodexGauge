# Companion refinement — September 30, 2026

The development beta is installed and running, and the development relay is updated. Mobile acceptance and source review are complete within the scope below. The native Mac visual check remains blocked; cloud-only Work telemetry, verified account handles and live compaction are unavailable from the reviewed supported sources. This is a development checkpoint, not a release candidate or store submission.

## Feedback evidence

All mobile screenshots below are synthetic fixtures rendered in the dedicated iPhone17Pro/iOS27 simulator `98F554DE-F267-4C9C-965A-5B98D180093D`. They are not screenshots of the owner's real account. Human reference screenshots were reviewed separately at `/Users/george/Documents/Codex/2026-09-30/task-5/references/reference-1.png` through `reference-5.png`. `screenshots.json` records original result-bundle attachments for the 26 copied screenshots.

| Feedback | Outcome | Evidence and limits |
| --- | --- | --- |
| 1. Cloud-only task capture | Feasibility blocker | Supported codex cloud list returned no tasks; public local app-server schema does not establish Work-cloud telemetry. No private app tools/stores shipped.. Source: `CodexGauge/HelpView.swift` |
| 2. Primary mobile context percentage | Implemented and verified within recorded scope | task-summary-light.png; task-large-type-dark.png; linkedAgentMetricsUseTheSameActiveRepresentative. Source: `Companion/iOS/CompanionHome.swift` |
| 3. Current turn elapsed | Implemented and verified within recorded scope | task-summary-light.png; task-large-type-dark.png; live-small-running-light.png. Source: `Companion/iOS/CompanionHome.swift` |
| 4. Compaction phase | Feasibility blocker | Passive rollout source lacks reliable live start/end; historical compaction item never treated as currently compacting.. Source: `CodexGauge/LocalSessionMonitor.swift` |
| 5. Tool calls and zero rate | Implemented and verified within recorded scope | Mac9 correlated-tool/input/silence tests; Core5 legacy-rate and known-zero tests; explicit unknown output phase. Source: `CodexGauge/LocalSessionMonitor.swift` |
| 6. Mobile task statistics parity | Implemented and verified within recorded scope | task-stats-light.png; task-token-mix-light.png; UI5 asserts expanded Input/Output rows. Source: `Companion/iOS/CompanionHome.swift` |
| 7. Mac overview allowance, credits, banked resets | Implemented; Mac9/build/signature pass; native visual check blocked | DashboardView overview and ContentView balances; exact Sky native pipe failure; post-relaunch PID20553 window inventory empty; no focus takeover for capture. Source: `CodexGauge/DashboardView.swift` |
| 8. Allowances grouped by account | Implemented and verified within recorded scope | overview-light.png; Core5 sharedAllowanceIsAnObservationNotASum/differentAccountsRemainSeparate. Source: `CodexGauge/AppState.swift` |
| 9. Tasks grouped by machine | Implemented and verified within recorded scope | cold-task-link-dark.png; revocation-isolation-dark.png; UI4 multi-Mac same-task-ID ownership. Source: `Companion/Shared/CompanionModels.swift` |
| 10. Handle and duplicate machine footer | Implemented with source limitation | Removed repeated machine/time footer. Public account schema lacks verified handle; generic Pro allowances used, no hardcoded screenshot handle/email export.. Source: `Companion/iOS/CompanionHome.swift` |
| 11. Mobile title spacing | Implemented and verified within recorded scope | overview-light.png; overview-large-type-dark.png; task-large-type-dark.png. Source: `Companion/iOS/CompanionHome.swift` |
| 12. Link a Mac location | Implemented and verified within recorded scope | overview-empty-light.png; settings-light.png; UI4/UI5 no linked-overview pairing CTA. Source: `Companion/iOS/CompanionHome.swift` |
| 13. Limits navigation | Implemented and verified within recorded scope | limits-light.png; UI4/UI5 allowance opens Limits in existing Overview stack. Source: `Companion/iOS/CompanionHome.swift` |
| 14. Activity information parity | Implemented and verified within recorded scope | activity-chart-light.png; activity-stats-light.png; UI4 selectable ranges/day assertions; Core5 missing-vs-zero days. Source: `Companion/Shared/CompanionChartData.swift` |
| 15. Settings navigation review | Implemented and verified within recorded scope | settings-light.png; settings-dark.png; UI4/UI5 gear on root/detail, three tabs, pairing returns to Settings. Source: `Companion/iOS/CompanionHome.swift` |
| 16. Pairing sheet polish | Implemented and verified within recorded scope | pairing-light.png; pairing-invalid-light.png; overview-waiting-light.png. Source: `Companion/iOS/CompanionHome.swift` |
| 17. QR scan and paste fallback | Implemented; simulator fallback verified; camera hardware unverified | pairing-light.png; UI4/UI5 explicit scan action shows unsupported-camera fallback; source requests permission only in beginScan. Source: `Companion/iOS/CompanionHome.swift` |
| 18. Redundant Enabled alert line | Implemented and verified within recorded scope | CompanionHome.settingsView suppresses status equal to Enabled; source inspection. Source: `Companion/iOS/CompanionHome.swift` |
| 19. Send test notification polish | Implemented and verified within recorded scope | settings-light.png; source gates diagnostics and test/results behind DEBUG DisclosureGroup. Source: `Companion/iOS/CompanionHome.swift` |
| 20. Live Activity refinement | Implemented and verified within recorded scope | live-small-running-light.png; live-small-stale-dark.png; Core5 stable-selection/evidence-age and immediate-recovery tests. Source: `Companion/Shared/CompanionLiveState.swift` |
| 21. CarPlay refinement | Implemented; shared small renderer reviewed; hardware unverified | Actual shared small renderer in UI4/UI5; iOS18+ supplemental small/medium registration; iOS17 fallback compile; no hardware CarPlay test. Source: `Companion/Shared/CompanionLiveCard.swift` |

## Correctness changes

Explicit running/input/approval states survive silence; silence never fabricates task completion. Tool requests and outputs correlate by call ID, including concurrent calls and explicit user-input responses. A returned tool output becomes an unknown phase unless another observed event establishes a phase. Arguments, output bodies, prompt/reply text and raw account identities are not published.

Phase, model, context, elapsed and last-observation time come from one stable representative: the root when equally active, otherwise the earliest active agent. Missing agent model and last-turn duration no longer inherit unrelated root metadata. A new turn clears its prior input/context pairing. Agent context is labeled on Mac and mobile; recorded aggregate token totals carry a completeness flag. Absent observation differs from an observed zero, including legacy cached values. Missing account-history dates do not become zero days; averages state that they cover observed days.

Live Activity selection stays stable within its priority until completion or an attention task takes priority. Fresh aggregate counts do not renew old task evidence. Stale elapsed freezes at the last task observation; genuine recovery sends an immediate update without treating every heartbeat as a priority transition. The small renderer includes state, task, Mac, counts and elapsed, and has no remote control actions or browser launch. Both variants share the renderer; iOS17 retains the legacy configuration rather than registering duplicate ActivityKit configurations.

## Final checks

| Check | Result / artifact |
| --- | --- |
| Mac9 unit suite | 106 distinct tests passed, one existing signing-dependent skip; 107 passed executions including the parameterized case. `mac9-summary.json`, `.build/simulator-acceptance/refinement-mac9.log` |
| Core5 | 23 Swift tests, 36 relay tests, TypeScript check and deployment dry-run passed. `.build/simulator-acceptance/refinement-core5.log` |
| UI4, dark / large type | Seven tests passed, no failures/skips. `ui4-summary.json`, `.build/simulator-acceptance/refinement-ui4.xcresult` |
| UI5, light / empty / loading / error | Four tests passed, no failures/skips, including explicit Input/Output visibility after token-mix expansion. `ui5-summary.json`, `.build/simulator-acceptance/refinement-ui5.xcresult` |
| Unique native acceptance cases | Eight distinct cases across UI4/UI5 (11 executions, three overlaps). Includes multi-Mac ownership, cold/warm/repeated links, revoked access, usage-only replacement, stale/recovered/completed details, charts, pairing and constrained layout |
| Final simulator app/widget build | Passed; iOS17 deployment target retained. `.build/simulator-acceptance/refinement-build21.log` |
| Signed Debug Mac beta | Passed; installed app deep/strict signature passes. `.build/dev-beta-refinement/build-final.log`, `installed-signature-check.log`, final `installed-signature-final.log` |
| Deployed development relay | 16 integration tests passed, no failures/skips; disposable feeds deleted. `.build/simulator-acceptance/refinement-remote-relay.log` |
| New optional wire fields | Live metadata round trip and usage-only redaction passed against dev endpoint; 37ms measured socket delivery in one disposable probe, not a latency guarantee. Feed deleted. `.build/simulator-acceptance/refinement-optional-wire-final.log` |
| Repository whitespace | `git diff --check` passed |

Mobile pixel checks cover normal light/dark, large type, empty overview, waiting-for-first-feed, invalid-link correction, allowance drilldown, account activity, expanded task metrics, long names, stale/completed tasks and the actual shared small Live Activity renderer. Independent reviewers accepted the UI4/UI5 images. The small preview is a shared-renderer test, not an operating-system or hardware CarPlay test.

## Earlier failures and their resolution

- UI2 failed old chart wording and missing Settings on task detail. Chart assertions were updated to observed-day copy, and the actual detail toolbar now exposes Settings.
- UI3 failed after revocation because the test tried to navigate the underlying tab bar while Settings was still presented. The corrected test dismisses Settings first; UI4 proves the other Mac stays visible. A trailing successful runner segment did not supersede UI3's earlier failure. UI3 result collection later stalled and its owned runner was terminated; its log is diagnostic only.
- The earlier expanded-mix probe used an incomplete disclosure label. UI5 uses the exact observed label and asserts both expanded Input and Output rows, so the capture cannot silently skip expansion.
- Mac6's new-turn regression fixture omitted required TokenUsage fields, so its payload did not decode. Completing the synthetic payload made the 80% → unknown → 10% assertions pass without changing implementation or timing. Mac7 and final Mac9 pass.
- An offscreen Mac capture helper first failed compilation because it omitted the view's clock. Its initial narrow filter selected zero tests. A full opt-in run produced PNGs with missing composited layers; those were rejected and the helper removed. Mac9 excludes that helper. Diagnostic images remain only under `.build/simulator-acceptance/invalid-offscreen-mac`; they are not acceptance evidence.
- A final restricted reviewer signature check reported an invalid signature while unable to bind Info.plist/authority. Both direct unrestricted verification and the independent reviewer’s unrestricted repeat passed with the expected Developer ID chain and timestamp. The install was not changed. `installed-signature-final.log` records the full deep/strict result; the source artifact separately passed the same check.
- A normal-launch font override was found and removed. The app follows system Dynamic Type; only an explicit Debug test argument forces accessibility size.

## Supported-source limits

The official cloud CLI probe `codex cloud list --json --limit 20` returned `{"tasks":[],"cursor":null}` for the reviewed account; it did not expose the cloud-only Work chat in the reference. The distributed app does not use private Codex app tools or internal cloud stores as an API. Local activity remains the supported source, and Help explains its coverage. See the official [developer commands](https://learn.chatgpt.com/docs/developer-commands?surface=cli).

The public `account/read` schema supplies account type, email and plan, but no verified display handle. Grouping uses a salted verified account identity; unavailable identity falls back to one Mac, rather than merging unrelated accounts. The screenshot handle is never hardcoded and raw email is not exported. Redundant adjacent Mac/timestamp allowance footers are removed.

The official app-server has compaction item start/completion lifecycle events, but the passive local rollout source does not establish that live window. A historical compaction entry is not evidence of current compaction. That phase is not inferred. See the [app-server documentation](https://learn.chatgpt.com/docs/app-server).

Apple documents custom small-family presentation for Watch and CarPlay in [Creating custom views for Live Activities](https://developer.apple.com/documentation/activitykit/creating-custom-views-for-live-activities). Current proof covers SDK registration and the shared renderer on iOS27 only. No physical iPhone, watch, CarPlay, iOS17 runtime or Intel runtime interaction occurred in this refinement; earlier proofs in `Simulator-Acceptance-2026-09-30.md` and `2026-09-30.md` are labeled earlier evidence.

## Native Mac visual gate

Selecting `/Applications/CodexGauge Beta.app` through CUA failed with the exact error **“Sky Computer Use native pipe closed before response”**, including a runtime-reset retry. The first bundle-ID selection was ambiguous because local development copies share the beta identifier; the absolute installed path removed that ambiguity but did not restore the pipe.

After the new beta launched in the background, PID20553 was positively identified at `/Applications/CodexGauge Beta.app/Contents/MacOS/CodexGaugeBeta`. A read-only CoreGraphics inventory found no owned native windows (`.build/simulator-acceptance/refinement-beta-windows.json` is empty). No dashboard was opened to take over focus during the owner's separate app review. The overview additions therefore have source/unit/build evidence but no accepted current native Mac screenshot. No permissions, Screen Recording settings or unrelated services were changed.

## Installed identity and cleanup

- Mac beta: `com.northwolflabs.CodexGauge.beta`, version1.2.0/build9, Debug; Developer ID Application: North Wolf Labs LLC, teamALPX923Y54. Relaunched in the background. Previous installed app retained at `.build/dev-beta-refinement/installed-before-update.app`.
- Development endpoint: `https://codexgauge-relay-dev.north-wolf-labs.workers.dev`; version `7c849ffe-75e3-4765-8b3f-88d4a6d2a93e`. Existing APNs secret retained; no key was printed or placed in source.
- Mixed dirty checkout preserved, with no commit of unrelated work, new tag, RC, production deployment or store submission.
- The owned local relay on8798 and core fixture on8794 are stopped. Disposable remote test feeds were removed. The dedicated simulator is left on the clearly labeled demo overview in dark appearance; physical devices are untouched.
- A reusable widget-availability recipe was added to `/Users/george/NorthWolfLabs/macOS-Recipes/recipes/widget-bundle-availability/README.md`, with a standalone failing-before/passing-after compiler probe and explicit SDK/runtime limits. It is not a runtime dependency.

## Source fingerprint

`source-manifest.json` hashes 104 source/configuration files plus the two installed Mac executable artifacts. It records the baseline Git commit and branch, but identifies the uncommitted source as a mixed working tree, not an immutable release commit. Its source identity is:

`fa5fbc72f69a688018a9518b9cfed228aca7d0826415a06a24f51db2e0f77784`

Installed Mac main binary: `135a05f7e8e4eb09db35f42d866fb9fae9d4d1f91d797aa99f7daf5dd4f51d5c`.

Installed Mac Debug implementation: `0d67aa4bcafe308c6f8fe1f78eff7b35137a05ceecfa7aa357f69a6bd20bec8e`.

The manifest states the canonical serialization used for the digest. Repeat per-file SHA-256 checks before review or packaging if source changes. No approval or verification result here substitutes for the explicit native Mac, older-OS, hardware and background-soak release gates.
