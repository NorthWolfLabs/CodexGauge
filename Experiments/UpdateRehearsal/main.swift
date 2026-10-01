import AppKit
import Security

// Compile the production AppUpdater.swift unchanged, but give this disposable
// host its own identity so it cannot replace or read either real app's state.
enum AppIdentity {
    static let stableBundleIdentifier = "com.northwolflabs.CodexGauge.UpdateRehearsal"
}

@MainActor final class Rehearsal: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let defaults = UserDefaults.standard
        if version == "1", defaults.string(forKey: "rehearsal.preference") == nil {
            defaults.set("retained-test-preference", forKey: "rehearsal.preference")
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: AppIdentity.stableBundleIdentifier,
                                   kSecAttrAccount as String: "test-link-sentinel"]
        let expected = Data("disposable-rehearsal-link".utf8)
        if version == "1" {
            var insert = query; insert[kSecValueData as String] = expected
            _ = SecItemAdd(insert as CFDictionary, nil)
        }
        var read = query; read[kSecReturnData as String] = true
        var item: CFTypeRef?
        let keyStatus = SecItemCopyMatching(read as CFDictionary, &item)
        let retainedKey = keyStatus == errSecSuccess && (item as? Data) == expected
        let retainedPreference = defaults.string(forKey: "rehearsal.preference") == "retained-test-preference"
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 210),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "CodexGauge Update Rehearsal"
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(NSTextField(labelWithString: "Installed build: \(version)"))
        stack.addArrangedSubview(NSTextField(labelWithString: "Preference preserved: \(retainedPreference ? "yes" : "NO")"))
        stack.addArrangedSubview(NSTextField(labelWithString: "Keychain link preserved: \(retainedKey ? "yes" : "NO")"))
        stack.addArrangedSubview(NSButton(title: "Check for Updates…", target: self, action: #selector(check)))
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
                                     stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)])
        let menu = NSMenu(); let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Rehearsal", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem); NSApp.mainMenu = menu
        AppUpdater.shared.start()
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate()
    }
    @objc func check() { AppUpdater.shared.checkForUpdates() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let delegate = Rehearsal()
app.delegate = delegate
app.run()
