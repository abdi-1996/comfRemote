import SwiftUI

@main
struct MiniStudioApp: App {
    @StateObject private var store = WorkflowStore()

    var body: some Scene {
        WindowGroup {
            BrowserStudioView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}
