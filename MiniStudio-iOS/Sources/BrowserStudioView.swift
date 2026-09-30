import SwiftUI
import WebKit

struct BrowserStudioView: View {
    @StateObject private var browser = StudioBrowser()
    @AppStorage("comfyServerURL") private var serverURL = ""
    @Environment(\.scenePhase) private var scenePhase
    @State private var editingComfyUI = false
    @State private var showServer = false

    var body: some View {
        ZStack(alignment: .top) {
            BrowserWebView(webView: browser.webView)
                .ignoresSafeArea(edges: .bottom)

            if !browser.connected || showServer {
                connectionOverlay
            } else {
                topBar
            }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onAppear {
            if !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                browser.connect(serverURL)
            } else {
                showServer = true
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                browser.resume()
            }
        }
        .alert("Mini Studio", isPresented: Binding(
            get: { !browser.message.isEmpty },
            set: { if !$0 { browser.message = "" } }
        )) {
            Button("OK", role: .cancel) { browser.message = "" }
        } message: {
            Text(browser.message)
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(browser.loading ? Color.orange : Color.green)
                .frame(width: 8, height: 8)

            Text(browser.status)
                .font(.caption.bold())
                .lineLimit(1)

            Spacer()

            Button {
                if editingComfyUI {
                    browser.openStudio()
                    editingComfyUI = false
                } else {
                    browser.editWorkflow()
                    editingComfyUI = true
                }
            } label: {
                Label(
                    editingComfyUI ? "Mini Studio" : "Workflow",
                    systemImage: editingComfyUI ? "sparkles.rectangle.stack" : "pencil"
                )
            }
            .buttonStyle(.borderedProminent)

            Menu {
                Button("Open Mini Studio") {
                    browser.openStudio()
                    editingComfyUI = false
                }
                Button("Add Mini Studio node") {
                    browser.openStudio(create: true)
                    editingComfyUI = false
                }
                Button("Reload") { browser.reload() }
                Button("Server") { showServer = true }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var connectionOverlay: some View {
        VStack(spacing: 14) {
            Spacer()

            VStack(alignment: .leading, spacing: 12) {
                Text("Mini Studio")
                    .font(.title.bold())

                Text("Подключение к настоящему ComfyUI")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField("http://100.x.x.x:8188", text: $serverURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

                Button {
                    browser.connect(serverURL)
                    showServer = false
                } label: {
                    Text("Подключиться")
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
                .buttonStyle(.borderedProminent)
                .disabled(StudioBrowser.serverURL(serverURL) == nil)

                if browser.connected {
                    Button("Отмена") { showServer = false }
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(18)
            .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 20))
            .padding(18)

            Spacer()
        }
        .background(Color.black.opacity(0.7).ignoresSafeArea())
    }
}

private struct BrowserWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
