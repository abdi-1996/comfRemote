import SwiftUI
import WebKit

struct SharedFile: Identifiable {
    let id = UUID()
    let url: URL
}


@MainActor
final class StudioBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    @Published var connected = false
    @Published var loading = false
    @Published var status = "Connect your computer"
    @Published var message = ""
    @Published var sharedFile: SharedFile?
    @Published var downloads: [URL] = []
    private var server: URL?
    private var destinations: [ObjectIdentifier: URL] = [:]
    private var connectionID = UUID()
    private var opening = false

    lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.isOpaque = false
        view.backgroundColor = UIColor(white: 0.04, alpha: 1)
        view.scrollView.backgroundColor = view.backgroundColor
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.allowsBackForwardNavigationGestures = false
        return view
    }()

    static func serverURL(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "http://" + text }
        guard var parts = URLComponents(string: text),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, !host.contains(" "),
              parts.user == nil, parts.password == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        parts.fragment = nil
        if parts.path.isEmpty { parts.path = "/" }
        return parts.url
    }

    func connect(_ address: String) {
        guard let url = Self.serverURL(address) else { message = "Invalid server address."; return }
        connectionID = UUID(); opening = false
        server = url; connected = true; message = ""; status = "Connecting…"
        webView.load(URLRequest(url: url, timeoutInterval: 30))
    }

    func reload() {
        guard connected else { return }
        message = ""; status = "Reconnecting…"
        webView.reload()
    }

    private func isServer(_ url: URL?) -> Bool {
        guard let url, let server else { return false }
        return url.host?.lowercased() == server.host?.lowercased()
            && url.scheme?.lowercased() == server.scheme?.lowercased()
            && (url.port ?? (url.scheme == "https" ? 443 : 80)) == (server.port ?? (server.scheme == "https" ? 443 : 80))
    }

    func openStudio(create: Bool = false, automatic: Bool = false) {
        guard connected, isServer(webView.url), !opening else { return }
        opening = true
        let id = connectionID
        Task {
            defer { if id == connectionID { opening = false } }
            for _ in 0..<(automatic ? 30 : 1) {
                guard id == connectionID else { return }
                do {
                    let result = try await bridge(create ? "create" : "open")
                    guard id == connectionID else { return }
                    if result == "ready" { status = "Mini Studio"; message = ""; return }
                    if !automatic {
                        message = result == "missing-extension"
                            ? "Install Mini Studio v0.4.4 or later in ComfyUI on your computer, then reload."
                            : "Open your Mini Studio workflow, or choose Add Mini Studio to workflow from the app menu."
                        return
                    }
                } catch {
                    if !automatic { message = "Mini Studio is not ready. Wait for ComfyUI to finish loading, then try again."; return }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            if id == connectionID { status = "ComfyUI"; message = "Open your workflow, then tap Open Mini Studio. To start a new studio, use the app menu." }
        }
    }

    func editWorkflow() {
        guard connected, isServer(webView.url), !opening else { return }
        opening = true
        Task {
            defer { opening = false }
            do {
                let result = try await bridge("edit")
                if result == "ready" {
                    status = "ComfyUI Workflow"
                    message = ""
                } else if result == "no-studio" {
                    status = "ComfyUI Workflow"
                    message = ""
                }
            } catch {
                message = "Не удалось переключиться в редактор workflow."
            }
        }
    }

    func resume() {
        guard connected, !loading, isServer(webView.url) else { return }
        Task {
            do { _ = try await bridge("resume") }
            catch { message = "Connection is waking up. If progress stays frozen, use Reload connection in the menu." }
        }
    }

    private func bridge(_ mode: String) async throws -> String {
        guard let path = Bundle.main.url(forResource: "studio-bridge", withExtension: "js") else {
            throw NSError(domain: "MiniStudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing bridge"])
        }
        let source = try String(contentsOf: path, encoding: .utf8)
        let result = try await webView.callAsyncJavaScript(source, arguments: ["mode": mode], in: nil, contentWorld: .page)
        return result as? String ?? "waiting"
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true; status = "Connecting…"
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false; status = "ComfyUI"; openStudio(automatic: true)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        loading = false; status = "Disconnected"
        message = "\(error.localizedDescription) Check that ComfyUI is running and Wi-Fi or Tailscale is connected. Use Server settings or Reload connection."
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        status = "Restoring connection…"; webView.reload()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload { decisionHandler(.download); return }
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.targetFrame?.isMainFrame != false && !isServer(url) && url.scheme != "about" && url.scheme != "blob" {
            decisionHandler(.cancel)
            if navigationAction.navigationType == .linkActivated { UIApplication.shared.open(url) }
            else { message = "The server redirected to another address. Enter the final ComfyUI address in Server settings." }
            return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        decisionHandler(!navigationResponse.canShowMIMEType || disposition.lowercased().contains("attachment") ? .download : .allow)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let safeName = (suggestedFilename as NSString).lastPathComponent
        let name = safeName.isEmpty || safeName == "." || safeName == ".." ? "Result" : safeName
        var destination = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(name)")
        }
        destinations[ObjectIdentifier(download)] = destination
        status = "Downloading…"; completionHandler(destination)
    }
    func downloadDidFinish(_ download: WKDownload) {
        if let url = destinations.removeValue(forKey: ObjectIdentifier(download)) { sharedFile = SharedFile(url: url) }
        status = "Download saved"; refreshDownloads()
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let url = destinations.removeValue(forKey: ObjectIdentifier(download)) { try? FileManager.default.removeItem(at: url) }
        message = "Download failed: \(error.localizedDescription). Retry Download on the result."; status = "ComfyUI"
    }
    func refreshDownloads() {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        downloads = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles)) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            if isServer(url) { webView.load(navigationAction.request) }
            else if ["http", "https"].contains(url.scheme ?? "") { UIApplication.shared.open(url) }
        }
        return nil
    }
    private func presenter() -> UIViewController? {
        var controller = webView.window?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let presenter = presenter() else { completionHandler(); return }
        let alert = UIAlertController(title: "Mini Studio", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        presenter.present(alert, animated: true)
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let presenter = presenter() else { completionHandler(false); return }
        let alert = UIAlertController(title: "Mini Studio", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        presenter.present(alert, animated: true)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard let presenter = presenter() else { completionHandler(nil); return }
        let alert = UIAlertController(title: "Mini Studio", message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "Save", style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
        presenter.present(alert, animated: true)
    }
}
