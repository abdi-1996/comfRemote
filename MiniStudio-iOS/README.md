# Mini Studio for iPhone 1.1.0

Native SwiftUI + WKWebView client for your existing ComfyUI Mini Studio installation. Requires iOS 16+ and a running ComfyUI computer. H3 generation remains on the PC GPU.

## New in 1.1

- **Models & LoRA** button in the iPhone top bar.
- Reads model/LoRA loader widgets from the **real currently opened ComfyUI workflow**.
- Search and select models already exposed by each loader.
- **Browse on PC** opens the native Windows file picker on the ComfyUI computer.
- Selected model is written back into the real loader widget, marks the graph changed, and reconciles Mini Studio.
- Supports diffusion models, checkpoints, text encoders, VAE and LoRA loaders.
- External model files selected through Browse on PC are imported into the matching ComfyUI models folder by symlink, hardlink, or copy fallback.

## Install

1. Build/sign and install `MiniStudio-1.1.0-unsigned.ipa` as usual.
2. Keep your existing Mini Studio custom node installed in ComfyUI.
3. Install the companion folder `MiniStudio-ModelPicker` into:
   `ComfyUI/custom_nodes/MiniStudio-ModelPicker`
   You can also run `install_to_comfyui.bat` from that folder and paste your ComfyUI folder path.
4. Restart ComfyUI.
5. Start ComfyUI with network access, for example `--listen 0.0.0.0 --port 8188`.
6. Connect the iPhone through the same Wi-Fi or Tailscale address.
7. Open your H3 workflow and tap the **box icon → Models & LoRA**.

Normal model selection from ComfyUI works even without the companion extension. The companion is only required for **Browse on PC**.

## Model Browser behavior

Mini Studio scans the active graph (including nested/subgraph references it can reach) and detects file-selection widgets such as:

- UNET / diffusion model
- checkpoint
- text encoder / CLIP / Qwen
- VAE
- LoRA

Selecting an entry from the iPhone changes that exact widget in the workflow. Browse on PC sends a same-origin request to ComfyUI; Windows opens a file picker locally. No separate cloud server is used.

Supported file extensions for the Windows picker:
`.safetensors`, `.ckpt`, `.pt`, `.pth`, `.bin`, `.gguf`.

## Existing behavior

References, bypass, prompts, generation, progress and results continue to use the installed Mini Studio interface served by the PC. Downloads appear in Files → On My iPhone → Mini Studio.

The app keeps persistent website data and cookies. On foreground return it asks Mini Studio to reconcile queue/history while preserving workflow edits. Generation continues on the PC if the iPhone is locked or the app is suspended.

## Build

The branch is `mini-studio-ios-1.1`.

GitHub Actions:
- runs bridge tests;
- syntax-checks the Windows companion;
- generates the Xcode project;
- builds the unsigned iPhone app;
- packages `MiniStudio-1.1.0-unsigned.ipa`;
- packages `MiniStudio-ModelPicker.zip`.

Real iPhone/Tailscale/GPU generation and the physical Windows file-picker interaction still require a test against your ComfyUI installation.
