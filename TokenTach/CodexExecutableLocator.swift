import Foundation

actor DefaultCodexExecutableLocator: CodexExecutableLocating {
    private let validator: any CodexExecutableValidating
    private let homeDirectory: URL

    init(validator: any CodexExecutableValidating = DefaultCodexExecutableValidator(),
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.validator = validator
        self.homeDirectory = homeDirectory
    }

    func locate(override: String?) async -> URL? {
        var candidates: [String] = []
        if let override, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(NSString(string: override).expandingTildeInPath)
        }

        candidates += [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(homeDirectory.path)/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "\(homeDirectory.path)/Applications/Codex.app/Contents/Resources/codex",
            "\(homeDirectory.path)/.codex/packages/standalone/current/bin/codex",
            "\(homeDirectory.path)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]

        var seen = Set<String>()
        for path in candidates where seen.insert(path).inserted {
            guard let trusted = try? await validator.validate(URL(fileURLWithPath: path)) else { continue }
            return trusted
        }
        return nil
    }
}
