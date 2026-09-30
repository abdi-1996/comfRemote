import SwiftUI

@main
struct MiniStudioApp: App {
    @StateObject private var store = WorkflowStore()

    var body: some Scene {
        WindowGroup {
            NativeStudioView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}
