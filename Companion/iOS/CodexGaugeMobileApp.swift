import SwiftUI

@main struct CodexGaugeMobileApp: App {
    @UIApplicationDelegateAdaptor(CompanionPush.self) private var pushDelegate
    @State private var store = CompanionStore()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            CompanionHome(store: store)
                .modifier(CompanionTestTypeSize())
                .onChange(of: scenePhase, initial: true) { _, phase in store.setForeground(phase == .active) }
        }
    }
}

private struct CompanionTestTypeSize: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-companionLargeType") {
            content.dynamicTypeSize(.accessibility3)
        } else { content }
        #else
        content
        #endif
    }
}
