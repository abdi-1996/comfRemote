import SwiftUI
import WebKit

struct ComfyEditorView: UIViewRepresentable {
    let serverURL: String
    let item: WorkflowItem
    let onSync: (Any, Any?) -> Void
    let onStatus: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "workflowSync")

        let script = WKUserScript(source: Self.syncScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        controller.addUserScript(script)

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.keyboardDismissMode = .interactive

        if let url = ComfyClient.normalizedBaseURL(serverURL) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "workflowSync")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let parent: ComfyEditorView
        private var didLoadWorkflow = false

        init(parent: ComfyEditorView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onStatus("ComfyUI открыт")
            guard !didLoadWorkflow else { return }
            didLoadWorkflow = true
            loadSelectedWorkflow(into: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.onStatus(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.onStatus(error.localizedDescription)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "workflowSync",
                  let body = message.body as? [String: Any],
                  let workflow = body["workflow"] else { return }
            let output = body["output"]
            DispatchQueue.main.async {
                self.parent.onSync(workflow, output is NSNull ? nil : output)
            }
        }

        private func loadSelectedWorkflow(into webView: WKWebView) {
            if let data = parent.item.workflowJSON {
                evaluateLoad(data: data, function: "loadGraphData", in: webView)
            } else if let data = parent.item.apiPromptJSON {
                evaluateLoad(data: data, function: "loadApiJson", in: webView)
            }
        }

        private func evaluateLoad(data: Data, function: String, in webView: WKWebView) {
            let b64 = data.base64EncodedString()
            let js = """
            (async () => {
              const sleep = ms => new Promise(r => setTimeout(r, ms));
              for (let i = 0; i < 100; i++) {
                const app = window.app;
                if (app && typeof app.\(function) === 'function') {
                  try {
                    const bytes = Uint8Array.from(atob('\(b64)'), c => c.charCodeAt(0));
                    const obj = JSON.parse(new TextDecoder().decode(bytes));
                    await app.\(function)(obj);
                    return 'loaded';
                  } catch (e) { return 'load-error:' + e.toString(); }
                }
                await sleep(100);
              }
              return 'app-not-ready';
            })();
            """
            webView.evaluateJavaScript(js) { [weak self] result, error in
                if let error { self?.parent.onStatus("Не удалось загрузить workflow: \(error.localizedDescription)") }
                else if let result = result as? String, result != "loaded" { self?.parent.onStatus(result) }
            }
        }
    }

    private static let syncScript = """
    (() => {
      if (window.__comfyMobileSyncInstalled) return;
      window.__comfyMobileSyncInstalled = true;
      let last = '';
      const sync = async () => {
        try {
          const app = window.app;
          const graph = app?.rootGraph || app?.graph;
          if (!app || !graph || typeof graph.serialize !== 'function') return;
          const workflow = graph.serialize();
          const packed = JSON.stringify(workflow);
          if (packed === last) return;
          last = packed;

          let output = null;
          if (typeof app.graphToPrompt === 'function') {
            try {
              const prompt = await app.graphToPrompt();
              output = prompt?.output || prompt?.prompt || null;
            } catch (_) {}
          }
          window.webkit.messageHandlers.workflowSync.postMessage({ workflow, output });
        } catch (_) {}
      };
      setInterval(sync, 800);
      setTimeout(sync, 1200);
    })();
    """
}
