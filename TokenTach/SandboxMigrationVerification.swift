#if DEBUG
import AppKit
import CryptoKit
import Foundation

/// Read only this app's own preferences and support files. Reports hashes and
/// counts, never preference values, identifiers, account data or credentials.
enum SandboxMigrationDigest {
    static func preference(_ value: Any) throws -> String {
        func normalize(_ item: Any) -> Any {
            if let data = item as? Data {
                if let json = try? JSONSerialization.jsonObject(with: data) { return ["json": normalize(json)] }
                return ["data": data.base64EncodedString()]
            }
            if let date = item as? Date { return ["date": date.timeIntervalSince1970] }
            if let items = item as? [String: Any] { return items.mapValues(normalize) }
            if let items = item as? [Any] { return items.map(normalize) }
            return item
        }
        return hash(try JSONSerialization.data(withJSONObject: ["value": normalize(value)], options: [.sortedKeys]))
    }
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor enum SandboxMigrationVerification {
    private static var window: NSWindow?
    static func start(_ state: AppState) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let marker = arguments.firstIndex(of: "-verifySandboxMigration"),
              arguments.indices.contains(marker + 1),
              let data = Data(base64Encoded: arguments[marker + 1]),
              let expected = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else { return }
        let preferences = expected["preferences"] ?? [:]
        let preferenceMatches = preferences.filter { key, hash in
            guard let value = UserDefaults.standard.object(forKey: key) else { return false }
            return (try? SandboxMigrationDigest.preference(value)) == hash
        }.count
        let mismatchedFields = preferences.keys.filter { key in
            guard let value = UserDefaults.standard.object(forKey: key) else { return true }
            return (try? SandboxMigrationDigest.preference(value)) != preferences[key]
        }.sorted()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: AppIdentity.current.supportDirectoryName)
        let files = expected["files"] ?? [:]
        let fileMatches = files.filter { path, hash in
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
                  let bytes = BoundedFileReader.read(support.appending(path: path), maximumBytes: 32 * 1024 * 1024)
            else { return false }
            return SandboxMigrationDigest.hash(bytes) == hash
        }.count
        let label = NSTextField(wrappingLabelWithString: """
        Preferences preserved: \(preferenceMatches)/\(preferences.count)
        Support files preserved: \(fileMatches)/\(files.count)
        Verification: \(preferenceMatches == preferences.count && fileMatches == files.count ? "Passed" : "Failed")
        Changed preference fields: \(mismatchedFields.isEmpty ? "None" : mismatchedFields.joined(separator: ", "))
        Companion publishing is suspended for this local check.
        """)
        label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        label.setAccessibilityIdentifier("sandbox-migration-result")
        label.frame = NSRect(x: 20, y: 20, width: 480, height: 140)
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 180),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Sandbox Migration Verification"
        panel.isReleasedWhenClosed = false
        panel.contentView?.addSubview(label)
        if fileMatches != files.count {
            let restore = NSButton(title: "Restore existing app state…", target: nil, action: nil)
            restore.frame = NSRect(x: 20, y: 0, width: 240, height: 24)
            let action = MigrationRestoreAction(expected: files, destination: support) {
                window?.close()
                start(state)
            }
            restore.target = action
            restore.action = #selector(MigrationRestoreAction.restore)
            restoreAction = action
            panel.contentView?.addSubview(restore)
        }
        window = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        // Bounded, local-only readiness check. No task/account values are reported.
        let migrationResult = label.stringValue
        Task { @MainActor [weak state] in
            for sample in 0...20 {
                guard let state else { return }
                label.stringValue = migrationResult + "\nAccount fresh: \(state.displayFreshness == .fresh) · Tasks loaded: \(state.hasLoadedConversations) · Error: \(state.errorMessage != nil)"
                if sample < 20 { try? await Task.sleep(for: .seconds(1)) }
            }
        }
    }
    private static var restoreAction: MigrationRestoreAction?
}

/// Only used by the development migration check when an old test container
/// already exists. The native picker grants access to this app's legacy state.
@MainActor private final class MigrationRestoreAction: NSObject {
    let expected: [String: String]
    let destination: URL
    let completed: () -> Void
    init(expected: [String: String], destination: URL, completed: @escaping () -> Void) {
        self.expected = expected
        self.destination = destination
        self.completed = completed
    }
    @objc func restore() {
        let picker = NSOpenPanel()
        picker.title = "Choose Existing \(AppIdentity.current.displayName) State"
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let source = picker.url,
              source.lastPathComponent == AppIdentity.current.supportDirectoryName,
              source.startAccessingSecurityScopedResource() else { return }
        defer { source.stopAccessingSecurityScopedResource() }
        do {
            var content: [String: Data] = [:]
            for (path, hash) in expected {
                guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
                      let data = BoundedFileReader.read(source.appending(path: path), maximumBytes: 32 * 1024 * 1024),
                      SandboxMigrationDigest.hash(data) == hash else { throw CocoaError(.fileReadCorruptFile) }
                content[path] = data
            }
            let backup = FileManager.default.temporaryDirectory.appending(path: "migration-backup-\(UUID().uuidString)")
            for (path, data) in content {
                let target = destination.appending(path: path)
                if FileManager.default.fileExists(atPath: target.path) {
                    let copy = backup.appending(path: path)
                    try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: target, to: copy)
                }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
            }
            completed()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Existing app state could not be restored"
            alert.informativeText = "Choose the original support folder matching this verification baseline. No other folder is accepted."
            alert.runModal()
        }
    }
}
#endif
