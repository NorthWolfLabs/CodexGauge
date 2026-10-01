import Foundation

/// Optional local Codex metadata. Unknown formats/associations produce no label;
/// a working-directory basename alone is not proof of project membership.
struct TaskProjectIndex: Decodable, Sendable {
    struct Project: Decodable, Sendable {
        let name: String
        let rootPaths: [String]
    }
    struct Assignment: Decodable, Sendable {
        let projectKind: String
        let projectId: String?
    }
    var projects: [String: Project]?
    var assignments: [String: Assignment]?
    var projectless: [String]?
    var roots: [String]?
    var labels: [String: String]?

    enum CodingKeys: String, CodingKey {
        case projects = "local-projects"
        case assignments = "thread-project-assignments"
        case projectless = "projectless-thread-ids"
        case roots = "electron-saved-workspace-roots"
        case labels = "electron-workspace-root-labels"
    }

    func name(threadID: String, workingDirectory: String) -> String? {
        if projectless?.contains(threadID) == true { return nil }
        if let assignment = assignments?[threadID] {
            guard assignment.projectKind == "local", let id = assignment.projectId else { return nil }
            return clean(projects?[id]?.name)
        }
        guard workingDirectory.hasPrefix("/") else { return nil }
        let path = URL(fileURLWithPath: workingDirectory).standardizedFileURL.path
        var candidates: [(root: String, name: String)] = []
        for project in projects?.values ?? Dictionary<String, Project>().values {
            for root in project.rootPaths { candidates.append((root, project.name)) }
        }
        for root in roots ?? [] {
            candidates.append((root, labels?[root] ?? URL(fileURLWithPath: root).lastPathComponent))
        }
        return candidates.filter {
            guard $0.root.hasPrefix("/") else { return false }
            let root = URL(fileURLWithPath: $0.root).standardizedFileURL.path
            return path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
        }.sorted { $0.root.count > $1.root.count }.first.flatMap { clean($0.name) }
    }

    private func clean(_ name: String?) -> String? {
        guard let name else { return nil }
        let value = String(name.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        return value.isEmpty ? nil : value
    }
}
