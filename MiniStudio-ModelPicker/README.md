# Mini Studio Model Picker

Companion custom node for **Mini Studio iPhone v1.1**.

It adds a small same-origin API to ComfyUI so the iPhone app can open the native Windows file picker on the PC and apply a selected model or LoRA to the current workflow.

## Install

1. Copy this whole folder to:
   `ComfyUI/custom_nodes/MiniStudio-ModelPicker`
2. Restart ComfyUI.
3. In Mini Studio on iPhone open **Models & LoRA**.
4. Open any detected loader and tap **Browse on PC**.
5. Windows opens the file picker on the PC.

If the selected file is already in the matching ComfyUI model folder, it is used directly. If it is elsewhere, the extension tries a symbolic link, then a hard link, and finally copies the file into the appropriate ComfyUI models folder.

Supported file types: `.safetensors`, `.ckpt`, `.pt`, `.pth`, `.bin`, `.gguf`.

The picker is Windows-only. Normal model selection from the workflow still works on other systems.
