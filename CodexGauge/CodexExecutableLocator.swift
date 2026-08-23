import Foundation

struct DefaultCodexExecutableLocator: CodexExecutableLocating {
    func locate(override: String?) -> URL? {
        var candidates: [String] = []
        if let override, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(NSString(string: override).expandingTildeInPath)
        }

        candidates += [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(NSHomeDirectory())/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "\(NSHomeDirectory())/Applications/Codex.app/Contents/Resources/codex"
        ]

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/codex" }
        }

        candidates += [
            "\(NSHomeDirectory())/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(NSHomeDirectory())/.volta/bin/codex"
        ]

        var seen = Set<String>()
        for path in candidates where seen.insert(path).inserted {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  FileManager.default.isExecutableFile(atPath: path) else { continue }
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}
