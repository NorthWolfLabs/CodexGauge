import Foundation
import Testing
@testable import TokenTach

struct TaskProjectTests {
    @Test func projectMembershipUsesSavedNamesAndExcludesProjectlessTasks() throws {
        let data = Data(#"{"local-projects":{"p":{"name":"My Project","rootPaths":["/work/repo"]},"nested":{"name":"Nested","rootPaths":["/work/repo/child"]}},"thread-project-assignments":{"assigned":{"projectKind":"local","projectId":"p"},"unknown":{"projectKind":"local","projectId":"missing"}},"projectless-thread-ids":["loose"]}"#.utf8)
        let index = try JSONDecoder().decode(TaskProjectIndex.self, from: data)
        #expect(index.name(threadID: "assigned", workingDirectory: "/work/worktrees/random") == "My Project")
        #expect(index.name(threadID: "unassigned", workingDirectory: "/work/repo/subfolder") == "My Project")
        #expect(index.name(threadID: "unassigned", workingDirectory: "/work/repo/child/subfolder") == "Nested")
        #expect(index.name(threadID: "loose", workingDirectory: "/work/repo") == nil)
        #expect(index.name(threadID: "unknown", workingDirectory: "/work/repo") == nil)
        #expect(index.name(threadID: "unassigned", workingDirectory: "/work/repository") == nil)
        #expect(index.name(threadID: "unassigned", workingDirectory: "") == nil)
        let old = try JSONDecoder().decode(TaskProjectIndex.self, from: Data(#"{"electron-saved-workspace-roots":["/work/repo"],"electron-workspace-root-labels":{"/work/repo":"Renamed project"}}"#.utf8))
        #expect(old.name(threadID: "a", workingDirectory: "/work/repo") == "Renamed project")
        let empty = try JSONDecoder().decode(TaskProjectIndex.self, from: Data("{}".utf8))
        #expect(empty.name(threadID: "a", workingDirectory: "/work/repo") == nil)
    }

    @Test func projectLabelAppearsOnlyWhenAvailableAndSurvivesQueuedDelivery() throws {
        var event = ResetAlert(kind: .completed, key: "task", name: "Improve alerts", added: 1,
                               available: 0, since: .now, observedAt: .now)
        #expect(event.projectName == nil)
        event.projectName = "TokenTach"
        let restored = try JSONDecoder().decode(ResetAlert.self, from: JSONEncoder().encode(event))
        #expect(restored.name == "Improve alerts")
        #expect(restored.projectName == "TokenTach")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        json.removeValue(forKey: "projectName")
        let legacy = try JSONDecoder().decode(ResetAlert.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.projectName == nil)
    }
}
