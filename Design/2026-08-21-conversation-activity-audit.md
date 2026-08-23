# Conversation and Activity UX Audit — August 21, 2026

Evidence: the thirteen user-supplied screenshots from 7:14–7:34 PM and the verified UI-test captures in `TestArtifacts/UI-final-2026-08-21-1954`.

1. **Turn timing and order — Healthy after revision.** Live tasks use the current turn start, sort newest turn first, and no longer reorder when their phase changes. Recent tasks show the last completed turn with coarse, stable durations.
2. **Conversation hierarchy — Healthy after revision.** Live cards keep the compact information hierarchy, add edge padding, use one phase label, and place the disclosure indicator at the trailing edge. Recent tasks use a uniform list with progressive disclosure.
3. **Motion and controls — Healthy after revision.** Phase changes cross-fade, numeric throughput retains local easing, Reduce Motion is respected, and menu-bar footer controls use larger hit regions.
4. **Activity ranges and copy — Healthy after revision.** Summary labels name their range, Today selects its only day automatically, All omits an inapplicable comparison, comparison text uses real prior periods, and long-range dates include the year.
5. **Resource use — Materially improved.** The running pre-change build measured a 222.8 MB physical footprint. The rebuilt app measured 66.1 MB after startup, with no leaks; oversized rollout tail buffers were the main clear retention source.

Verification: Swift 6 build succeeded, all 11 unit tests and 2 UI tests passed, and the menu-bar popover, Dashboard conversations, Dashboard activity, Help, Settings, right-click menu, and keyboard Help shortcut were exercised.
