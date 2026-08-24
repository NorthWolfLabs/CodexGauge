# Runtime performance

CodexGauge treats idle resource use as a release requirement. The local performance gate runs the exported Release app through five deterministic, privacy-safe demo scenarios for five minutes each. It samples only the CodexGauge process with `proc_pid_rusage`; a separately launched Codex helper is never included in the app's budget.

## Run the gate

Quit any installed copy of CodexGauge, then run:

```sh
./Scripts/performance-check.sh
```

To verify an already-exported app:

```sh
PERFORMANCE_APP_PATH=/absolute/path/to/CodexGauge.app \
  ./Scripts/performance-check.sh
```

The strict run takes about 25 minutes. A short installation smoke test is available for development only:

```sh
PERFORMANCE_MODE=smoke PERFORMANCE_APP_PATH=/absolute/path/to/CodexGauge.app \
  ./Scripts/performance-check.sh
```

The smoke test does not replace the strict release gate.

## Scenarios and measurements

Budgets are defined in [`Budgets.json`](Budgets.json). The scenarios cover a closed idle app, a visible popover, expanded task and activity details, the Dashboard Activity view, and recovery after twenty popover open/close cycles. The expanded scenario also supplies 200 tasks, oversized values, rapid semantic task changes, and a one-second allowance refresh preference.

Each result records average and p95 CPU, confirmed peak physical footprint, raw peak physical footprint, final footprint, retained growth, resident size, and the lifetime and interval footprint maxima. Presentation p95 values require at least 20 completed open/close samples for every measured transient surface. If macOS withholds `ri_phys_footprint` from the sibling probe, the harness uses the process's resident size as a conservative fallback rather than accepting a zero measurement. The first minute is warm-up. Release logs are scanned for SwiftUI, Charts, Auto Layout, main-thread, accessibility, invalid-dimension, and view-update-cycle diagnostics.

Some current macOS builds can return a process's unchanged lifetime maximum as its current physical footprint for exactly one `proc_pid_rusage` sample. The report always preserves that raw value. The gate filters it only when both adjacent current-footprint samples remain at least 32 MB lower, resident memory does not rise by more than 5 MB, and the lifetime maximum does not advance. A sustained elevation, a resident-memory increase, a new lifetime maximum, or a boundary sample remains release-blocking.

Resource sampling starts only after the app emits a scenario-readiness marker. This ensures the 60-second warm-up begins after presentation cycling and surface setup have completed; the presentation cycle's own latency and sample-count gates are evaluated separately.

The harness holds a `caffeinate` assertion for its entire run so display sleep and system-idle scene reconfiguration cannot contaminate a deterministic steady-state budget. JSON reports include every bounded one-second measured sample for direct peak correlation. Sleep/wake behavior remains part of manual compatibility testing rather than the resource baseline.

Xcode 26.6 emits one known `[Internal]` priority-inversion diagnostic when `com.apple.testmanagerd` attaches a hosted unit-test bundle, even when all CodexGauge background work is disabled. The release script excludes only that exact message from the hosted-test runtime log. Standalone Release launches, exported-app performance scenarios, and mounted-DMG smoke tests receive no such exception.

Signposts cover executable validation, session discovery and parsing, snapshot publication, transient-surface construction, and chart updates. On failure, the harness captures Time Profiler, SwiftUI, Allocations, Animation Hitches, and Leaks diagnostics under `.build/performance`; generated results and traces are intentionally not committed.

The release process repeats a short smoke test against the app inside the generated DMG. Clean-machine macOS 14 and macOS 26+ soaks remain manual release-candidate checks because a single machine cannot prove both compatibility targets.
