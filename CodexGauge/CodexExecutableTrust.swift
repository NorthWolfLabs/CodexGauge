import Foundation
import Security

enum CodexExecutableTrustError: LocalizedError {
    case unavailable
    case untrusted

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "The selected Codex helper is unavailable."
        case .untrusted:
            "Choose a Codex helper signed by OpenAI."
        }
    }
}

enum CodexExecutableTrust {
    static let openAITeamID = "2DC432GLL2"

    static func validate(_ candidate: URL) throws -> URL {
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: resolved.path) else {
            throw CodexExecutableTrustError.unavailable
        }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(resolved as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            throw CodexExecutableTrustError.untrusted
        }

        var requirement: SecRequirement?
        let requirementText = "identifier \"codex\" and anchor apple generic and certificate leaf[subject.OU] = \"\(openAITeamID)\""
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            throw CodexExecutableTrustError.untrusted
        }

        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess else {
            throw CodexExecutableTrustError.untrusted
        }
        return resolved
    }
}
