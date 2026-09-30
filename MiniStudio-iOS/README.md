# Mini Studio for iPhone 1.0.0

Native SwiftUI + WKWebView client for your existing ComfyUI Mini Studio v0.4.4+ installation. Requires iOS 16+ and a running ComfyUI computer. It does not run H3 on the phone.

## Use
1. Sign the unsigned IPA with your own Apple signing setup and install it.
2. Keep Mini Studio custom nodes installed in ComfyUI on the computer. Run ComfyUI listening on its network interface (for example `--listen 0.0.0.0`).
3. Connect iPhone and computer using the same Wi-Fi or Tailscale. Enter the computer address such as `http://100.x.x.x:8188` in the app. Do not use localhost on iPhone.
4. Allow Local Network access. Open the Mini Studio workflow. The app opens its fullscreen UI. Alternatively choose **Add Mini Studio to workflow** from the app menu. This adds the installed node without removing existing nodes.
5. References, model selection, bypass, prompts, progress and results are the existing Mini Studio interface served by your computer. Use **Download** on a result to share/save it. Downloads also appear in Files → On My iPhone → Mini Studio.

The app keeps persistent website data and cookies. On foreground return it asks Mini Studio to reconcile the queue/history while preserving workflow edits. ComfyUI handles WebSocket reconnects. iOS can suspend the web view; missed previews are not reconstructed. If the web process is killed, the page reloads. Save workflow changes before manual reload. The app cannot guarantee restoration of unsaved changes after OS termination.

Only scripts on the configured server origin receive the Mini Studio bridge. HTTP is supported for local/Tailscale servers. HTTPS certificate validation is not bypassed. Different-origin redirects require entering the final server address. Generation continues on the PC even while the phone is locked.

## Build
Install Xcode and XcodeGen on macOS, run `xcodegen generate`, then build scheme MiniStudio. The GitHub Actions workflow builds device and simulator targets, packages an **unsigned** IPA and launches the app in an iPhone simulator. Apple signing credentials are not included.

## Validation scope
Bridge tests cover resume, opening, missing extension and preserving existing nodes on explicit creation. CI validates compilation and simulator launch. Real iPhone, Tailscale, GPU generation and end-to-end imports/downloads require testing on your server.
