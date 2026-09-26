import SwiftUI

@main
struct ComfyMobileApp: App {
    @StateObject private var store = WorkflowStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}
