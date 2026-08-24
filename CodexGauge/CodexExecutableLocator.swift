import Foundation

actor DefaultCodexExecutableLocator: CodexExecutableLocating {
    private let validator: any CodexExecutableValidating

    init(validator: any CodexExecutableValidating = DefaultCodexExecutableValidator()) {
        self.validator = validator
    }

    func locate(override: String?) async -> URL? {
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

        var seen = Set<String>()
        for path in candidates where seen.insert(path).inserted {
            guard let trusted = try? await validator.validate(URL(fileURLWithPath: path)) else { continue }
            return trusted
        }
        return nil
    }
}
