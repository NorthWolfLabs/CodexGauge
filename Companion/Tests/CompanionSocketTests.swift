import Foundation
import Testing
@testable import CompanionCore

@Test(.enabled(if: ProcessInfo.processInfo.environment["COMPANION_SOCKET_FIXTURE_URL"] != nil))
func socketDeadlinesCancelSilentReceivesAndDoNotCloseHealthyConnections() async throws {
    let base = URL(string: ProcessInfo.processInfo.environment["COMPANION_SOCKET_FIXTURE_URL"]!)!
    // This test may only target the disposable loopback fixture.
    #expect(base.host == "127.0.0.1")
    guard base.host == "127.0.0.1" else { return }
    let session = CompanionNoRedirect.session(timeout: 10)
    defer { session.invalidateAndCancel() }
    let echo = session.webSocketTask(with: base.appending(path: "echo"))
    echo.resume()
    defer { echo.cancel(with: .normalClosure, reason: nil) }
    for text in ["first", "second", "ping"] {
        try await CompanionSocket.send(.string(text), on: echo)
        let message = try await CompanionSocket.receive(echo, timeout: .seconds(2))
        if case .string(let reply) = message { #expect(reply == (text == "ping" ? "pong" : text)) }
        else { Issue.record("Expected text echo") }
    }
    let silent = session.webSocketTask(with: base.appending(path: "silent"))
    silent.resume()
    try await CompanionSocket.send(.string("ready"), on: silent)
    let clock = ContinuousClock(), start = clock.now
    do {
        _ = try await CompanionSocket.receive(silent, timeout: .milliseconds(150))
        Issue.record("A silent socket must time out")
    } catch {
        #expect(clock.now - start >= .milliseconds(100))
        #expect(clock.now - start < .seconds(3))
    }

    let cancelled = session.webSocketTask(with: base.appending(path: "silent"))
    cancelled.resume()
    let read = Task { try await CompanionSocket.receive(cancelled, timeout: .seconds(10)) }
    try await Task.sleep(for: .milliseconds(100))
    let cancellationStart = clock.now
    read.cancel()
    do { _ = try await read.value; Issue.record("Cancelled receive must fail") }
    catch { #expect(clock.now - cancellationStart < .seconds(3)) }
}
