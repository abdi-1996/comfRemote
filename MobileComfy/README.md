# Comfy Mobile

Native iOS client for ComfyUI.

## v1
- Save ComfyUI LAN/Tailscale address
- Import multiple ComfyUI JSON workflows
- Select workflow from the iPhone app
- Open the real ComfyUI frontend inside WKWebView
- Auto-sync edited graph back into the app
- Auto-extract API prompt via ComfyUI graphToPrompt()
- Edit common prompt/seed/steps/CFG/size/LoRA parameters
- Queue the selected workflow via /prompt

The GitHub Actions workflow creates an unsigned IPA suitable for sideloading/signing tools.
