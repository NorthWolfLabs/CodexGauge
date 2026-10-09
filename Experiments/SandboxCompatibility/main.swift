import AppKit
import CoreServices

@MainActor final class Probe: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let report = NSTextField(wrappingLabelWithString: "")
    var selectedFolder: URL?
    var selectedHelper: URL?
    var stream: FSEventStreamRef?
    var watchedFolder: URL?
    var events = 0
    var accountMode: Bool { CommandLine.arguments.contains("--account-check") }
    func argument(_ name: String) -> URL? {
        guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: CommandLine.arguments[index + 1])
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 560),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "TokenTach Sandbox Compatibility"
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        report.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        stack.addArrangedSubview(report)
        stack.addArrangedSubview(NSButton(title: "Choose Codex data folder", target: self, action: #selector(chooseFolder)))
        stack.addArrangedSubview(NSButton(title: "Choose Codex helper and check launch", target: self, action: #selector(chooseHelper)))
        stack.addArrangedSubview(NSButton(title: "Test app-server handshake with fixture folder", target: self, action: #selector(handshake)))
        if accountMode { stack.addArrangedSubview(NSButton(title: "Check saved sign-in and allowance access", target: self, action: #selector(accountCheck))) }
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
          stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
          stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20)])
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate()
        report.stringValue = "Sandbox fixture probe. No credentials or task contents are read."
        let previous = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("probe-stderr.txt")
        if let file = try? FileHandle(forReadingFrom: previous) {
            defer { try? file.close() }
            if let bytes = try? file.read(upToCount: 300), let text = String(data: bytes, encoding: .utf8), !text.isEmpty {
                report.stringValue += "\nLast fixture startup diagnostic:\n\(text)"
            }
        }
        if accountMode {
            report.stringValue = "Account compatibility check. The installed helper reads saved sign-in and allowances. Only success/failure is displayed; credentials and account details are not logged."
            return
        }
        selectedFolder = restore("fixtureFolder")
        selectedHelper = restore("fixtureHelper")
        if let selectedFolder { checkFolder(selectedFolder); watch(selectedFolder) }
    }

    private func save(_ url: URL, key: String, readOnly: Bool = false) {
        do {
            var options: URL.BookmarkCreationOptions = [.withSecurityScope]
            if readOnly { options.insert(.securityScopeAllowOnlyReadAccess) }
            let data = try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: key)
            append("Bookmark saved: \(key)")
        } catch { append("Bookmark save failed: \((error as NSError).code)") }
    }

    private func restore(_ key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            guard url.startAccessingSecurityScopedResource() else { append("Bookmark denied: \(key)"); return nil }
            defer { url.stopAccessingSecurityScopedResource() }
            if stale { save(url, key: key, readOnly: key == "fixtureHelper") }
            append("Bookmark restored: \(key), stale: \(stale)")
            return url
        } catch { append("Bookmark restore failed: \(key), \((error as NSError).code)"); return nil }
    }

    private func checkFolder(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let directory = AnchoredFileAccess.openDirectory(url) else {
            append("Production anchored directory access: DENIED"); return
        }
        defer { close(directory.descriptor) }
        append("Production anchored directory access: OK")
        if let file = AnchoredFileAccess.openRegularFile(relativePath: "sessions/fixture.txt", directoryDescriptor: directory.descriptor) {
            close(file); append("Production anchored fixture open: OK")
        } else { append("Production anchored fixture open: DENIED or absent") }
    }

    private func watch(_ url: URL) {
        stopWatch()
        guard url.startAccessingSecurityScopedResource() else { append("Watch scope denied"); return }
        watchedFolder = url
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, pointer, count, _, _, _ in
            guard let pointer else { return }
            let probe = Unmanaged<Probe>.fromOpaque(pointer).takeUnretainedValue()
            Task { @MainActor in
                probe.events += count
                probe.append("FSEvents received: \(probe.events)")
            }
        }, &context, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2,
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes))
        guard let stream else { stopWatch(); return }
        FSEventStreamSetDispatchQueue(stream, .main)
        append("FSEvents started: \(FSEventStreamStart(stream))")
    }

    private func stopWatch() {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        stream = nil
        watchedFolder?.stopAccessingSecurityScopedResource(); watchedFolder = nil
    }
    @objc func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.directoryURL = argument("--fixture")
        panel.showsHiddenFiles = true; panel.message = "Select the Codex data folder to test user-granted directory access."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedFolder = url
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if accountMode { append("Account data folder selected for this launch only"); return }
        save(url, key: "fixtureFolder")
        checkFolder(url)
        watch(url)
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
            let sessions = names.contains("sessions") && FileManager.default.isReadableFile(atPath: url.appendingPathComponent("sessions").path)
            report.stringValue += "\nSelected directory listing: OK. Sessions readable: \(sessions)."
        } catch { report.stringValue += "\nSelected directory denied: \((error as NSError).domain) \((error as NSError).code)" }
    }
    @objc func chooseHelper() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
        if let helper = argument("--helper") { panel.directoryURL = helper.deletingLastPathComponent(); panel.nameFieldStringValue = helper.lastPathComponent }
        panel.showsHiddenFiles = true; panel.message = "Select the already-installed Codex executable. This runs --version only."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedHelper = url
        let scoped = url.startAccessingSecurityScopedResource()
        if !accountMode { save(url, key: "fixtureHelper", readOnly: true) }
        let process = Process(); process.executableURL = url; process.arguments = ["--version"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] child in
            Task { @MainActor in
                if scoped { url.stopAccessingSecurityScopedResource() }
                self?.report.stringValue += "\nSelected helper exit: \(child.terminationStatus), reason: \(child.terminationReason.rawValue)."
            }
        }
        do {
            try process.run()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                if process.isRunning { process.terminate() }
            }
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            report.stringValue += "\nSelected helper launch denied: \((error as NSError).domain) \((error as NSError).code)."
        }
    }
    @objc func handshake() { runHandshake(accountCheck: false) }
    @objc func accountCheck() { runHandshake(accountCheck: true) }
    private func runHandshake(accountCheck: Bool) {
        guard let folder = selectedFolder, let helper = selectedHelper else { return }
        let folderScope = folder.startAccessingSecurityScopedResource()
        let helperScope = helper.startAccessingSecurityScopedResource()
        let child = Process(); let input = Pipe(); let output = Pipe()
        let diagnosticURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("probe-stderr.txt")
        FileManager.default.createFile(atPath: diagnosticURL.path, contents: Data())
        guard let diagnostic = try? FileHandle(forWritingTo: diagnosticURL) else {
            if folderScope { folder.stopAccessingSecurityScopedResource() }
            if helperScope { helper.stopAccessingSecurityScopedResource() }
            return
        }
        child.executableURL = helper; child.arguments = ["app-server", "--listen", "stdio://"]
        child.environment = ["CODEX_HOME": folder.path,
                             "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                             "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        child.standardInput = input; child.standardOutput = output; child.standardError = accountCheck ? FileHandle.nullDevice : diagnostic
        child.terminationHandler = { _ in
            if folderScope { folder.stopAccessingSecurityScopedResource() }
            if helperScope { helper.stopAccessingSecurityScopedResource() }
        }
        do {
            try child.run()
            try input.fileHandleForWriting.write(contentsOf: Data("{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"TokenTachSandboxProbe\",\"version\":\"1\"},\"capabilities\":{}}}\n".utf8))
            Task.detached { [weak self] in
                var buffer = Data(); var result = "No initialize response"
                var done = false; var receivedBytes = 0
                func send(_ object: [String: Any]) throws {
                    var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
                    try input.fileHandleForWriting.write(contentsOf: data)
                }
                while !done && receivedBytes < 1_048_576 {
                    let data = output.fileHandleForReading.availableData
                    guard !data.isEmpty else { break }
                    receivedBytes += data.count; buffer.append(data)
                    if buffer.count > 65_536 { result = "Oversized response rejected"; break }
                    while let newline = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                        guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                              let id = value["id"] as? Int else { continue }
                        guard let reply = value["result"] as? [String: Any] else {
                            result = "Request \(id) returned an error (details withheld)"; done = true; break
                        }
                        do {
                            switch id {
                            case 1 where accountCheck:
                                try send(["method": "initialized"])
                                try send(["id": 2, "method": "account/read", "params": ["refreshToken": false]])
                            case 1:
                                result = "Initialize accepted"; done = true
                            case 2:
                                guard reply["account"] is [String: Any] else {
                                    result = "Initialize accepted; no saved sign-in in selected folder"; done = true; break
                                }
                                try send(["id": 3, "method": "account/rateLimits/read"])
                            case 3:
                                result = reply["rateLimits"] is [String: Any]
                                    ? "Saved sign-in and authenticated allowance access: OK"
                                    : "Allowance response did not contain expected data"
                                done = true
                            default: break
                            }
                        } catch { result = "Request could not be written"; done = true }
                        if done { break }
                    }
                }
                if child.isRunning { child.terminate() }
                await self?.append(result)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                if child.isRunning { child.terminate(); report.stringValue += "\nHandshake timed out." }
            }
        } catch {
            if folderScope { folder.stopAccessingSecurityScopedResource() }
            if helperScope { helper.stopAccessingSecurityScopedResource() }
            report.stringValue += "\nHandshake launch failed: \((error as NSError).domain) \((error as NSError).code)."
        }
    }
    private func append(_ result: String) { report.stringValue += "\n\(result)." }
    func applicationWillTerminate(_ notification: Notification) { stopWatch() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let delegate = Probe()
app.delegate = delegate
app.run()
