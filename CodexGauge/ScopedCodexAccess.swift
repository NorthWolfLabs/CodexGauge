import Foundation
import Observation

/// A grant stays alive while the app's readers and helper use its URL.
final class ScopedCodexResource: @unchecked Sendable {
    let url: URL
    private let release: @Sendable () -> Void

    init(url: URL, release: @escaping @Sendable () -> Void) {
        self.url = url
        self.release = release
    }

    deinit { release() }
}

@MainActor
protocol CodexBookmarkAccessing {
    func acquire(_ url: URL) throws -> ScopedCodexResource
    func bookmark(_ url: URL, readOnly: Bool) throws -> Data
    func resolve(_ data: Data) throws -> (url: URL, stale: Bool)
}

@MainActor
struct SystemCodexBookmarkAccess: CodexBookmarkAccessing {
    func acquire(_ url: URL) throws -> ScopedCodexResource {
        guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
        return ScopedCodexResource(url: url) { url.stopAccessingSecurityScopedResource() }
    }

    func bookmark(_ url: URL, readOnly: Bool) throws -> Data {
        var options: URL.BookmarkCreationOptions = [.withSecurityScope]
        if readOnly { options.insert(.securityScopeAllowOnlyReadAccess) }
        return try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolve(_ data: Data) throws -> (url: URL, stale: Bool) {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }
}

@MainActor @Observable
final class ScopedCodexAccess {
    static var requiredForBuild: Bool {
        #if STORE_BUILD
        true
        #else
        false
        #endif
    }

    enum Resource: String, CaseIterable {
        case directory, helper
        var key: String { "codexScopedAccess.\(rawValue)" }
        var readOnly: Bool { self == .helper }
    }

    let isRequired: Bool
    private(set) var directoryURL: URL?
    private(set) var helperURL: URL?
    private(set) var restorationMessage: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let backend: any CodexBookmarkAccessing
    @ObservationIgnored private var grants: [Resource: ScopedCodexResource] = [:]

    init(defaults: UserDefaults = .standard, required: Bool = requiredForBuild,
         backend: any CodexBookmarkAccessing = SystemCodexBookmarkAccess()) {
        self.defaults = defaults
        self.isRequired = required
        self.backend = backend
        guard required else { return }
        for resource in Resource.allCases {
            guard let data = defaults.data(forKey: resource.key) else { continue }
            do {
                let resolved = try backend.resolve(data)
                let grant = try backend.acquire(resolved.url)
                if resolved.stale {
                    defaults.set(try backend.bookmark(resolved.url, readOnly: resource.readOnly), forKey: resource.key)
                }
                install(grant, for: resource)
            } catch {
                restorationMessage = "Choose the Codex data folder or helper again to restore access."
            }
        }
    }

    /// Call only after stopping providers that use the old resource.
    func select(_ url: URL, for resource: Resource) throws {
        let grant = try backend.acquire(url)
        let data = try backend.bookmark(url, readOnly: resource.readOnly)
        defaults.set(data, forKey: resource.key)
        install(grant, for: resource)
        restorationMessage = nil
    }

    func temporaryAccess(to url: URL) throws -> ScopedCodexResource { try backend.acquire(url) }

    func retainedGrants() -> [ScopedCodexResource] { Array(grants.values) }

    private func install(_ grant: ScopedCodexResource, for resource: Resource) {
        grants[resource] = grant
        switch resource {
        case .directory: directoryURL = grant.url
        case .helper: helperURL = grant.url
        }
    }
}
