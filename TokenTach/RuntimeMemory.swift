import Darwin
import Foundation

enum RuntimeMemory {
    static func scheduleUnusedPageRelease() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            malloc_zone_pressure_relief(nil, 0)
        }
    }
}
