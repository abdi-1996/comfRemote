import SwiftUI
import WebKit

@main
struct MiniStudioApp: App {
    var body: some Scene {
        WindowGroup { RootView().preferredColorScheme(.dark) }
    }
}

struct SharedFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct RootView: View {
    @StateObject private var browser = StudioBrowser()
    @AppStorage("serverAddress") private var address = ""
    @State private var draft = ""
    @State private var showingServer = false
    @State private var showingDownloads = false
    @State private var confirmReload = false
    @State private var confirmCreate = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles.rectangle.stack.fill").foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Mini Studio").font(.headline)
                    Text(browser.status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { browser.openStudio() } label: { Image(systemName: "rectangle.expand.vertical") }
                    .accessibilityLabel("Open Mini Studio")
                Menu {
                    Button { browser.openStudio() } label: { Label("Open Mini Studio", systemImage: "sparkles") }
                    Button { confirmCreate = true } label: { Label("Add Mini Studio to workflow", systemImage: "plus.rectangle") }
                    Button { showingDownloads = true } label: { Label("Downloads", systemImage: "arrow.down.circle") }
                    Button { confirmReload = true } label: { Label("Reload connection", systemImage: "arrow.clockwise") }
                    Button { draft = address; showingServer = true } label: { Label("Server settings", systemImage: "network") }
                } label: { Image(systemName: "ellipsis.circle").font(.title3) }
            }.padding(.horizontal, 16).padding(.vertical, 10).background(Color(white: 0.07))
            if browser.loading { ProgressView().progressViewStyle(.linear).tint(.mint) }
            if !browser.message.isEmpty {
                HStack(alignment: .top) {
                    Text(browser.message).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    Button { browser.message = "" } label: { Image(systemName: "xmark") }
                }.padding(12).background(Color.orange.opacity(0.14))
            }
            if browser.connected {
                BrowserView(browser: browser)
            } else {
                VStack(spacing: 22) {
                    Image(systemName: "sparkles.tv").font(.system(size: 68)).foregroundStyle(.mint)
                    Text("Your studio. Anywhere.").font(.largeTitle.bold()).multilineTextAlignment(.center)
                    Text("Connect to ComfyUI on your computer.\nCreate images and videos from your iPhone.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Connect to ComfyUI") { draft = address; showingServer = true }
                        .buttonStyle(.borderedProminent).tint(.mint).foregroundStyle(.black)
                    Text("Wi-Fi · Tailscale · Your server").font(.caption).foregroundStyle(.secondary)
                }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(white: 0.04)).tint(.mint)
        .sheet(isPresented: $showingServer) { serverSheet }
        .sheet(isPresented: $showingDownloads) { downloadsSheet }
        .sheet(item: $browser.sharedFile) { ShareView(url: $0.url) }
        .confirmationDialog("Reload ComfyUI?", isPresented: $confirmReload, titleVisibility: .visible) {
            Button("Reload") { browser.reload() }
        } message: { Text("Save workflow edits first. A running generation continues on the computer.") }
        .confirmationDialog("Add a new Mini Studio?", isPresented: $confirmCreate, titleVisibility: .visible) {
            Button("Add Mini Studio") { browser.openStudio(create: true) }
        } message: { Text("Adds the installed Mini Studio node with its internal workflow. Existing nodes are kept.") }
        .onAppear { if !address.isEmpty && !browser.connected { browser.connect(address) } }
        .onChange(of: scenePhase) { phase in
            if phase == .active { browser.resume() }
        }
    }

    private var serverSheet: some View {
        NavigationStack {
            Form {
                Section("ComfyUI address") {
                    TextField("http://100.x.x.x:8188", text: $draft)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Use your computer's Wi-Fi or Tailscale address, including the port. ComfyUI must already be running.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("Connect") {
                        guard let url = StudioBrowser.serverURL(draft) else {
                            browser.message = "Enter a valid http:// or https:// server address."; return
                        }
                        address = url.absoluteString; showingServer = false; browser.connect(address)
                    }
                }
                Section("Mini Studio") {
                    Text("Install Mini Studio v0.4.4 or later in ComfyUI on your computer. Open your workflow, then tap Open Mini Studio. You can also add its node from the app menu.")
                    Text("Generation runs on your computer. After returning to the app, Mini Studio checks the queue and results. Frames missed while iOS suspended the app cannot be replayed.")
                }.font(.footnote)
            }.navigationTitle("Server")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showingServer = false } } }
        }
    }

    private var downloadsSheet: some View {
        NavigationStack {
            List {
                if browser.downloads.isEmpty { Text("Use Download on a generation result. Files also appear in Files → On My iPhone → Mini Studio.").foregroundStyle(.secondary) }
                ForEach(browser.downloads, id: \.self) { url in
                    ShareLink(item: url) { Label(url.lastPathComponent, systemImage: "doc") }
                }
            }.navigationTitle("Downloads")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showingDownloads = false } } }
                .onAppear { browser.refreshDownloads() }
        }
    }
}

struct BrowserView: UIViewRepresentable {
    @ObservedObject var browser: StudioBrowser
    func makeUIView(context: Context) -> WKWebView { browser.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct ShareView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
