import AppKit
import Testing
@testable import CodexGauge

struct BrandingTests {
    @MainActor @Test func brandIconsAreBundledAsDistinct1024PixelPNGs() throws {
        let light = try #require(Bundle.main.url(forResource: "CodexGauge-Light", withExtension: "png"))
        let dark = try #require(Bundle.main.url(forResource: "CodexGauge-Dark", withExtension: "png"))
        let lightData = try Data(contentsOf: light)
        let darkData = try Data(contentsOf: dark)
        #expect(lightData != darkData)
        for data in [lightData, darkData] {
            #expect(data.count < 2_000_000)
            #expect(Array(data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
            let bitmap = try #require(NSBitmapImageRep(data: data))
            #expect(bitmap.pixelsWide == 1024 && bitmap.pixelsHigh == 1024)
            #expect(bitmap.hasAlpha)
        }
    }
}
