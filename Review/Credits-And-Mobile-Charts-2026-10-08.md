# Credits and mobile activity charts — October 8, 2026

## Changes

Both Mac `CreditSnapshot` and mobile/widget `CompanionCredit` now use
`CompanionCreditFormatting`. It parses numeric wire strings with Foundation
`Decimal`, rounds the displayed value to four decimal places using decimal
rounding, and removes trailing zeros. Original balances remain unchanged in
storage and transport. Unlimited, missing and nonnumeric balance behavior is
preserved.

Examples: `62500.0000000000` → `62500`, `123.456789` → `123.4568`,
`1.2300000000` → `1.23`, and `9.99999` → `10`.

Mobile's 90-day, 1-year and All activity ranges now share the line-chart branch.
Today, 7-day and 30-day ranges retain bars. Selection and the visible point for
a single observation remain supported.

## Verification

Artifacts are under `.build/readiness-2026-10-08/`.

- `credit-core-final.log`: 48 shared tests passed, including 15 decimal-format
  cases, original wire precision, and every activity-range chart-style choice.
- `Mac-Credits-Verified.xcresult`: 123 Mac unit tests plus the native light/dark
  account/calendar UI test passed; zero failures or skips. The four-case Mac
  credit test explicitly verifies formatted output and unchanged raw values.
- `Mobile-Credits-Charts.xcresult`: two native simulator tests passed; zero
  failures or skips. Captures show `250` from the fixture's
  `250.0000000000`, real rendered 90-day/1-year/All lines, and a visible
  single-observation point. Simulator was the dedicated CodexGauge review
  simulator, not the owner's physical iPhone 17.
- Visually inspected Mac light Overview and dark Limits captures showing `12.5`,
  and mobile whole-credit, 1-year and All captures.
- Main and Beta universal Release builds and physical iPhone 12 Debug build
  succeeded. Installed Mac package checks confirm signed universal sandboxed
  bundles; phone strict signature verification passed. Repository checks passed.
- `Main-Credits-Installed.xcresult` and `Beta-Credits-Installed.xcresult`:
  each passed the actual installed app's normal connection check with saved
  folder/helper grants.
- `Phone-Credits-Installed.xcresult`: the physical iPhone 12 passed the saved
  real-account task check, retained its enabled Follow Active Tasks setting,
  showed its normal Live Activity, and retained the card through 35 seconds
  in the background. The test left the normal phone app open.

The initial narrow Mac test filter selected zero tests; it was replaced by the
full Mac unit suite and native UI check above. The zero-test result is not
verification evidence. Native CUA became unavailable during installation;
existing authorized XCTest checks verified the installed Mac apps instead.

## Installation

Updated `/Applications/CodexGauge.app` and `/Applications/CodexGauge Beta.app`
(Beta build 20) and the physical iPhone 12 app. Previous Mac bundles are retained
in `.build/readiness-2026-10-08/before-credit-update/`, with installation paths in
`credit-installation.json`. These local updates retain sandbox packaging. The
earlier exported App Store installer has not been regenerated for this change.
