#!/bin/zsh
set -euo pipefail

if [[ "${PERFORMANCE_CAFFEINATED:-0}" != "1" ]]; then
  exec /usr/bin/env PERFORMANCE_CAFFEINATED=1 /usr/bin/caffeinate -dims "$0" "$@"
fi

project_root="${0:A:h:h}"
budgets="$project_root/Performance/Budgets.json"
output_root="${PERFORMANCE_OUTPUT_ROOT:-$project_root/.build/performance}"
derived_data="$output_root/DerivedData"
probe="$output_root/performance-probe"
mode="${PERFORMANCE_MODE:-strict}"

mkdir -p "$output_root"
xcrun swiftc "$project_root/Scripts/performance-probe.swift" -O -o "$probe"

if [[ -n "${PERFORMANCE_APP_PATH:-}" ]]; then
  app_path="$PERFORMANCE_APP_PATH"
else
  xcodebuild build \
    -project "$project_root/CodexGauge.xcodeproj" \
    -scheme CodexGauge \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO
  app_path="$derived_data/Build/Products/Release/CodexGauge.app"
fi

binary="$app_path/Contents/MacOS/CodexGauge"
[[ -x "$binary" ]] || { print -u2 "performance: app executable is missing at $binary"; exit 1; }
if pgrep -x CodexGauge >/dev/null; then
  print -u2 "performance: quit every other CodexGauge instance before running the gate"
  exit 1
fi

sample_seconds="${PERFORMANCE_SAMPLE_SECONDS:-$(jq -r '.sampleSeconds' "$budgets")}"
warmup_seconds="${PERFORMANCE_WARMUP_SECONDS:-$(jq -r '.warmupSeconds' "$budgets")}"
scenarios=(idle popover popover-expanded dashboard-activity recovery)
if [[ -n "${PERFORMANCE_SCENARIOS:-}" ]]; then
  scenarios=("${(@s: :)PERFORMANCE_SCENARIOS}")
fi
if [[ "$mode" == "smoke" ]]; then
  sample_seconds="${PERFORMANCE_SAMPLE_SECONDS:-30}"
  warmup_seconds="${PERFORMANCE_WARMUP_SECONDS:-5}"
  scenarios=(idle)
fi

capture_traces() {
  local pid="$1" scenario="$2"
  for template in 'Time Profiler' SwiftUI Allocations 'Animation Hitches' Leaks; do
    local safe_name="${template// /-}"
    xcrun xctrace record --template "$template" --attach "$pid" --time-limit 10s \
      --output "$output_root/$scenario-$safe_name.trace" >/dev/null 2>&1 &
    local trace_pid=$!
    (
      sleep 25
      if kill -0 "$trace_pid" 2>/dev/null; then
        kill -TERM "$trace_pid" 2>/dev/null || true
        sleep 2
        kill -KILL "$trace_pid" 2>/dev/null || true
      fi
    ) &
    local watchdog_pid=$!
    wait "$trace_pid" 2>/dev/null || true
    kill -TERM "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
  done
  leaks "$pid" > "$output_root/$scenario-leaks.txt" 2>&1 &
  local leaks_pid=$!
  (
    sleep 25
    if kill -0 "$leaks_pid" 2>/dev/null; then
      kill -TERM "$leaks_pid" 2>/dev/null || true
      sleep 2
      kill -KILL "$leaks_pid" 2>/dev/null || true
    fi
  ) &
  local leaks_watchdog_pid=$!
  wait "$leaks_pid" 2>/dev/null || true
  kill -TERM "$leaks_watchdog_pid" 2>/dev/null || true
  wait "$leaks_watchdog_pid" 2>/dev/null || true
}

presentation_p95() {
  local metric="$1" process_log="$2"
  awk -v metric="$metric" '$1 == "PERFORMANCE_METRIC" && $2 == metric { print $3 }' "$process_log" \
    | sort -n \
    | awk '{ value[NR] = $1 } END { if (NR == 0) exit 1; idx = int((NR - 1) * 0.95 + 0.999999) + 1; print value[idx] }'
}

validate_presentation() {
  local scenario="$1" process_log="$2" metric limit p95 sample_count
  case "$scenario" in
    popover|popover-expanded|recovery) metric="popover_ms"; limit=250 ;;
    dashboard-activity) metric="dashboard_ms"; limit=500 ;;
    *) return 0 ;;
  esac
  if ! p95="$(presentation_p95 "$metric" "$process_log")"; then
    print -u2 "performance: $scenario did not record a presentation measurement"
    return 1
  fi
  sample_count="$(awk -v metric="$metric" '$1 == "PERFORMANCE_METRIC" && $2 == metric { count++ } END { print count + 0 }' "$process_log")"
  if (( sample_count < 20 )); then
    print -u2 "performance: $scenario recorded only $sample_count presentation samples; 20 are required"
    return 1
  fi
  if ! awk -v value="$p95" -v limit="$limit" 'BEGIN { exit !(value < limit) }'; then
    print -u2 "performance: $scenario presentation p95 ${p95}ms is not below ${limit}ms"
    return 1
  fi
  print "Presentation p95: $scenario ${p95}ms ($sample_count samples)"
}

run_scenario() {
  local scenario="$1"
  local arguments=(-performanceDemo -performanceScenario "$scenario")
  [[ "$scenario" == "popover-expanded" ]] && arguments+=(-performanceExpanded)
  [[ "$scenario" == "dashboard-activity" ]] && arguments+=(-performanceDashboardActivity)
  [[ "$scenario" == "popover-expanded" ]] && arguments+=(-performanceStress)

  local started pid result process_log runtime_log probe_status=0
  started="$(date '+%Y-%m-%d %H:%M:%S')"
  result="$output_root/$scenario.json"
  process_log="$output_root/$scenario-process.log"
  runtime_log="$output_root/$scenario-runtime.log"
  "$binary" "${arguments[@]}" > "$process_log" 2>&1 &
  pid=$!
  cleanup_scenario() {
    if [[ -n "${pid:-}" ]]; then
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  }
  trap cleanup_scenario EXIT
  trap 'cleanup_scenario; exit 130' INT TERM
  local ready_deadline=$(( SECONDS + 120 ))
  local ready_failure=""
  until grep -Fxq "PERFORMANCE_READY $scenario" "$process_log" 2>/dev/null; do
    if ! kill -0 "$pid" 2>/dev/null; then
      ready_failure="performance: $scenario exited before becoming ready"
      break
    fi
    if (( SECONDS >= ready_deadline )); then
      ready_failure="performance: $scenario did not become ready within 120 seconds"
      break
    fi
    sleep 0.2
  done
  if [[ -n "$ready_failure" ]]; then
    print -u2 "$ready_failure"
    cleanup_scenario
    trap - EXIT INT TERM
    return 1
  fi

  local average p95 memory growth
  average="$(jq -r ".scenarios[\"$scenario\"].averageCPU" "$budgets")"
  p95="$(jq -r ".scenarios[\"$scenario\"].p95CPU" "$budgets")"
  memory="$(jq -r ".scenarios[\"$scenario\"].footprintMB" "$budgets")"
  growth="$(jq -r ".scenarios[\"$scenario\"].growthMB" "$budgets")"
  "$probe" "$pid" "$scenario" "$sample_seconds" "$warmup_seconds" \
    "$average" "$p95" "$memory" "$growth" "$result" || probe_status=$?

  /usr/bin/log show --start "$started" --style compact --predicate 'process == "CodexGauge"' > "$runtime_log" || true
  if grep -Ei 'com\.apple\.runtime-issues|Invalid frame dimension|negative or non-finite|Custom UnitPoint|Charts:|Unable to simultaneously satisfy constraints|Publishing changes from within view updates|AttributeGraph: cycle|main thread as it may lead to UI unresponsiveness' \
    "$process_log" "$runtime_log"; then
    probe_status=1
  fi
  validate_presentation "$scenario" "$process_log" || probe_status=1
  if (( probe_status != 0 )); then capture_traces "$pid" "$scenario"; fi
  cleanup_scenario
  trap - EXIT INT TERM
  return "$probe_status"
}

failed=0
for scenario in "${scenarios[@]}"; do
  print "Performance scenario: $scenario"
  run_scenario "$scenario" || failed=1
done

(( failed == 0 )) || { print -u2 "performance: one or more resource budgets failed"; exit 1; }
print "Performance results: $output_root"
