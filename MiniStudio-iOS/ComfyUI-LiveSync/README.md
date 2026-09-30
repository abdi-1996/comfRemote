# Mini Studio Live Sync for ComfyUI

This optional companion is for true editor-state synchronization between the standalone iPhone Mini Studio app and the workflow currently open in ComfyUI.

## Why it exists

ComfyUI's standard HTTP API exposes queue/history/results very well, so Mini Studio Native can synchronize generated outputs and the last executed API prompt without installing anything extra.

The browser editor canvas itself is client-side state. To synchronize edits before the workflow is queued, install a tiny ComfyUI frontend/custom-node companion that publishes the current graph as API-format JSON.

## Required bridge contract

Expose these endpoints on the same ComfyUI origin:

- GET /mini-studio/sync/current
  - returns { "workflow": <UI workflow>, "prompt": <API prompt>, "updated_at": <unix seconds> }
- POST /mini-studio/sync/current
  - accepts the same object and updates the stored live snapshot.

The frontend extension should update the snapshot after graph/configuration changes and immediately before queueing.

## Native fallback

If the companion is not installed, Mini Studio Native 1.4 still:
- opens the real ComfyUI editor;
- reconnects when the app becomes active;
- reads /history;
- imports the latest executed API prompt;
- downloads image/video/audio outputs into its Results view.

This makes results and executed workflow state synchronize without changing the user's existing ComfyUI installation.
