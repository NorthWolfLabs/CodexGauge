import Foundation
import Testing
@testable import CodexGauge

private final class ReleasedGrants: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func append(_ url: URL) { lock.lock(); defer { lock.unlock() }; urls.append(url) }
    func contains(_ url: URL) -> Bool { lock.lock(); defer { lock.unlock() }; return urls.contains(url) }
}

@MainActor private final class FakeBookmarks: CodexBookmarkAccessing {
    let released = ReleasedGrants()
    var acquisitions: [URL] = []
    var creations: [(URL, Bool)] = []
    var stale = false
    var failsToResolve = false
    var failsToSave = false
    func acquire(_ url: URL) throws -> ScopedCodexResource {
        acquisitions.append(url)
        return ScopedCodexResource(url: url) { [released] in released.append(url) }
    }
    func bookmark(_ url: URL, readOnly: Bool) throws -> Data {
        if failsToSave { throw CocoaError(.fileWriteNoPermission) }
        creations.append((url, readOnly))
        return Data(url.path.utf8)
    }
    func resolve(_ data: Data) throws -> (url: URL, stale: Bool) {
        if failsToResolve { throw CocoaError(.fileReadNoPermission) }
        return (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale)
    }
}

private actor SandboxLocatorSpy: CodexExecutableLocating {
    var called = false
    func locate(override: String?) async -> URL? { called = true; return nil }
}
private actor SandboxSessionsSpy: SessionTelemetryProviding {
    var called = false
    func snapshots() async -> AsyncStream<[ConversationTelemetry]> {
        called = true
        return AsyncStream { $0.finish() }
    }
    func stop() async {}
}

@MainActor struct ScopedCodexAccessTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "ScopedAccessTests.\(UUID().uuidString)")!
    }

    @Test func restoredStaleGrantsRenewWithLeastRequiredAccessAndReleaseOnDeinit() throws {
        let store = defaults(), backend = FakeBookmarks()
        let directory = URL(fileURLWithPath: "/fixture/data")
        let helper = URL(fileURLWithPath: "/fixture/codex")
        store.set(Data(directory.path.utf8), forKey: ScopedCodexAccess.Resource.directory.key)
        store.set(Data(helper.path.utf8), forKey: ScopedCodexAccess.Resource.helper.key)
        backend.stale = true
        var access: ScopedCodexAccess? = ScopedCodexAccess(defaults: store, required: true, backend: backend)
        #expect(access?.directoryURL == directory)
        #expect(access?.helperURL == helper)
        #expect(backend.creations.count == 2)
        #expect(backend.creations.contains { $0.0 == helper && $0.1 })
        #expect(backend.creations.contains { $0.0 == directory && !$0.1 })
        #expect(!backend.released.contains(directory))
        access = nil
        #expect(backend.released.contains(directory))
        #expect(backend.released.contains(helper))
        for resource in ScopedCodexAccess.Resource.allCases { store.removeObject(forKey: resource.key) }
    }

    @Test func failedReplacementRetainsThePreviousGrantAndBookmark() throws {
        let store = defaults(), backend = FakeBookmarks()
        let old = URL(fileURLWithPath: "/fixture/original")
        let new = URL(fileURLWithPath: "/fixture/replacement")
        let access = ScopedCodexAccess(defaults: store, required: true, backend: backend)
        try access.select(old, for: .directory)
        backend.failsToSave = true
        #expect(throws: (any Error).self) { try access.select(new, for: .directory) }
        #expect(access.directoryURL == old)
        #expect(!backend.released.contains(old))
        #expect(backend.released.contains(new))
        #expect(store.data(forKey: ScopedCodexAccess.Resource.directory.key) == Data(old.path.utf8))
        store.removeObject(forKey: ScopedCodexAccess.Resource.directory.key)
    }

    @Test func unusableBookmarkRequiresSelectionAndDirectBuildDoesNotRestoreGrants() {
        let store = defaults(), backend = FakeBookmarks()
        store.set(Data("bad".utf8), forKey: ScopedCodexAccess.Resource.directory.key)
        backend.failsToResolve = true
        let access = ScopedCodexAccess(defaults: store, required: true, backend: backend)
        #expect(access.directoryURL == nil)
        #expect(access.restorationMessage != nil)
        let direct = ScopedCodexAccess(defaults: store, required: false, backend: backend)
        #expect(direct.restorationMessage == nil)
        #expect(backend.acquisitions.isEmpty)
        store.removeObject(forKey: ScopedCodexAccess.Resource.directory.key)
    }

    @Test func sandboxDoesNotReadOrDiscoverUntilDirectoryIsGranted() async {
        let store = defaults()
        let locator = SandboxLocatorSpy(), sessions = SandboxSessionsSpy()
        let access = ScopedCodexAccess(defaults: store, required: true, backend: FakeBookmarks())
        let state = AppState(settings: SettingsStore(defaults: store), locator: locator,
                             startImmediately: false, sessionProvider: sessions, codexAccess: access)
        await state.reconnect()
        #expect(await !locator.called)
        #expect(await !sessions.called)
        #expect(state.executableURL == nil)
        #expect(state.errorMessage?.contains("Choose your Codex data folder") == true)
    }

    @Test func sandboxSessionReaderCanStartWithoutDiscoveringAnUnselectedHelper() async throws {
        let store = defaults()
        let locator = SandboxLocatorSpy(), sessions = SandboxSessionsSpy()
        let access = ScopedCodexAccess(defaults: store, required: true, backend: FakeBookmarks())
        try access.select(URL(fileURLWithPath: "/fixture/data"), for: .directory)
        let state = AppState(settings: SettingsStore(defaults: store), locator: locator,
                             startImmediately: false, sessionProvider: sessions, codexAccess: access)
        await state.reconnect()
        for _ in 0..<20 where await !sessions.called { await Task.yield() }
        #expect(await sessions.called)
        #expect(await !locator.called)
        #expect(state.errorMessage == "Choose the installed Codex helper in Settings.")
        store.removeObject(forKey: ScopedCodexAccess.Resource.directory.key)
    }
}
