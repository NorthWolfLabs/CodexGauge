import Darwin
import Foundation

struct ResourceSample: Codable {
    let elapsedSeconds: Int
    let cpuPercent: Double
    let footprintMB: Double
    let residentMB: Double
    let lifetimeMaximumFootprintMB: Double
    let intervalMaximumFootprintMB: Double
}

struct Result: Codable {
    let scenario: String
    let durationSeconds: Int
    let measuredSamples: Int
    let averageCPUPercent: Double
    let p95CPUPercent: Double
    let peakFootprintMB: Double
    let rawPeakFootprintMB: Double
    let filteredFootprintSpikeCount: Int
    let finalFootprintMB: Double
    let retainedGrowthMB: Double
    let samples: [ResourceSample]
    let passed: Bool
    let failures: [String]
}

struct ConsoleResult: Codable {
    let scenario: String
    let durationSeconds: Int
    let measuredSamples: Int
    let averageCPUPercent: Double
    let p95CPUPercent: Double
    let peakFootprintMB: Double
    let rawPeakFootprintMB: Double
    let filteredFootprintSpikeCount: Int
    let finalFootprintMB: Double
    let retainedGrowthMB: Double
    let passed: Bool
    let failures: [String]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("performance-probe: \(message)\n").utf8))
    exit(2)
}

let arguments = CommandLine.arguments
guard arguments.count == 10,
      let pid = Int32(arguments[1]),
      let duration = Int(arguments[3]),
      let warmup = Int(arguments[4]),
      let maximumAverageCPU = Double(arguments[5]),
      let maximumP95CPU = Double(arguments[6]),
      let maximumFootprint = Double(arguments[7]),
      let maximumGrowth = Double(arguments[8]) else {
    fail("usage: performance-probe PID SCENARIO DURATION WARMUP MAX_AVG_CPU MAX_P95_CPU MAX_MB MAX_GROWTH_MB OUTPUT")
}

let scenario = arguments[2]
let outputURL = URL(fileURLWithPath: arguments[9])
guard duration > warmup, warmup >= 0 else { fail("duration must be longer than warmup") }

func usage(for pid: Int32) -> rusage_info_v4? {
    var information = rusage_info_v4()
    let status = withUnsafeMutableBytes(of: &information) { buffer in
        guard let address = buffer.baseAddress else { return Int32(-1) }
        let pointer = address.assumingMemoryBound(to: rusage_info_t?.self)
        return proc_pid_rusage(pid, RUSAGE_INFO_V4, pointer)
    }
    return status == 0 ? information : nil
}

guard var previousUsage = usage(for: pid) else { fail("process \(pid) is not available") }
var previousTime = ProcessInfo.processInfo.systemUptime
var samples: [ResourceSample] = []

for second in 1...duration {
    Thread.sleep(forTimeInterval: 1)
    guard let currentUsage = usage(for: pid) else { fail("process \(pid) exited during measurement") }
    let currentTime = ProcessInfo.processInfo.systemUptime
    let elapsed = max(0.001, currentTime - previousTime)
    let previousCPU = previousUsage.ri_user_time + previousUsage.ri_system_time
    let currentCPU = currentUsage.ri_user_time + currentUsage.ri_system_time
    let cpuSeconds = Double(currentCPU >= previousCPU ? currentCPU - previousCPU : 0) / 1_000_000_000
    let cpuPercent = max(0, cpuSeconds / elapsed * 100)
    // Some macOS releases return zero for ri_phys_footprint to an unentitled
    // sibling process. Resident size is the conservative supported fallback.
    let footprintBytes = currentUsage.ri_phys_footprint > 0
        ? currentUsage.ri_phys_footprint
        : currentUsage.ri_resident_size
    let footprintMB = Double(footprintBytes) / 1_048_576
    if second > warmup {
        samples.append(ResourceSample(
            elapsedSeconds: second,
            cpuPercent: cpuPercent,
            footprintMB: footprintMB,
            residentMB: Double(currentUsage.ri_resident_size) / 1_048_576,
            lifetimeMaximumFootprintMB: Double(currentUsage.ri_lifetime_max_phys_footprint) / 1_048_576,
            intervalMaximumFootprintMB: Double(currentUsage.ri_interval_max_phys_footprint) / 1_048_576
        ))
    }
    previousUsage = currentUsage
    previousTime = currentTime
}

guard !samples.isEmpty else { fail("no samples were collected") }
let averageCPU = samples.map(\.cpuPercent).reduce(0, +) / Double(samples.count)
let sortedCPU = samples.map(\.cpuPercent).sorted()
let percentileIndex = min(sortedCPU.count - 1, Int((Double(sortedCPU.count - 1) * 0.95).rounded(.up)))
let p95CPU = sortedCPU[percentileIndex]
let rawPeakFootprint = samples.map(\.footprintMB).max() ?? 0
var confirmedFootprints = samples.map(\.footprintMB)
var filteredFootprintSpikeCount = 0
if samples.count >= 3 {
    for index in 1..<(samples.count - 1) {
        let previous = samples[index - 1]
        let current = samples[index]
        let next = samples[index + 1]
        let neighboringFootprint = max(previous.footprintMB, next.footprintMB)
        let neighboringResident = max(previous.residentMB, next.residentMB)

        // On current macOS releases, proc_pid_rusage can occasionally return a
        // process's old lifetime maximum as its current physical footprint for
        // exactly one sample. That kernel-accounting transient is distinguishable
        // from an allocation: adjacent current-footprint samples stay low, resident
        // memory does not rise, and the lifetime maximum does not advance. Preserve
        // the raw sample for diagnosis, but do not let it manufacture a gate failure.
        let isUnconfirmedAccountingSpike = current.footprintMB > neighboringFootprint + 32
            && current.residentMB <= neighboringResident + 5
            && current.lifetimeMaximumFootprintMB <= previous.lifetimeMaximumFootprintMB + 5
        if isUnconfirmedAccountingSpike {
            confirmedFootprints[index] = neighboringFootprint
            filteredFootprintSpikeCount += 1
        }
    }
}
let peakFootprint = confirmedFootprints.max() ?? 0
let finalFootprint = samples.last?.footprintMB ?? 0
let comparisonIndex = max(0, samples.count - min(120, samples.count))
let retainedGrowth = max(0, finalFootprint - samples[comparisonIndex].footprintMB)

var failures: [String] = []
if averageCPU >= maximumAverageCPU { failures.append("average CPU \(averageCPU) >= \(maximumAverageCPU)") }
if p95CPU >= maximumP95CPU { failures.append("p95 CPU \(p95CPU) >= \(maximumP95CPU)") }
if peakFootprint >= maximumFootprint { failures.append("peak footprint \(peakFootprint) MB >= \(maximumFootprint) MB") }
if retainedGrowth >= maximumGrowth { failures.append("retained growth \(retainedGrowth) MB >= \(maximumGrowth) MB") }

let result = Result(
    scenario: scenario,
    durationSeconds: duration,
    measuredSamples: samples.count,
    averageCPUPercent: averageCPU,
    p95CPUPercent: p95CPU,
    peakFootprintMB: peakFootprint,
    rawPeakFootprintMB: rawPeakFootprint,
    filteredFootprintSpikeCount: filteredFootprintSpikeCount,
    finalFootprintMB: finalFootprint,
    retainedGrowthMB: retainedGrowth,
    samples: samples,
    passed: failures.isEmpty,
    failures: failures
)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(result).write(to: outputURL, options: .atomic)
let consoleResult = ConsoleResult(
    scenario: result.scenario,
    durationSeconds: result.durationSeconds,
    measuredSamples: result.measuredSamples,
    averageCPUPercent: result.averageCPUPercent,
    p95CPUPercent: result.p95CPUPercent,
    peakFootprintMB: result.peakFootprintMB,
    rawPeakFootprintMB: result.rawPeakFootprintMB,
    filteredFootprintSpikeCount: result.filteredFootprintSpikeCount,
    finalFootprintMB: result.finalFootprintMB,
    retainedGrowthMB: result.retainedGrowthMB,
    passed: result.passed,
    failures: result.failures
)
print(String(data: try encoder.encode(consoleResult), encoding: .utf8)!)
exit(failures.isEmpty ? 0 : 1)
