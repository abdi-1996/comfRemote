from __future__ import annotations

import asyncio
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

from aiohttp import web
import folder_paths
from server import PromptServer

NODE_CLASS_MAPPINGS = {}
NODE_DISPLAY_NAME_MAPPINGS = {}

_ALLOWED_EXTENSIONS = {".safetensors", ".ckpt", ".pt", ".pth", ".bin", ".gguf"}
_CATEGORY_ALIASES = {
    "diffusion_models": ("diffusion_models", "unet"),
    "checkpoints": ("checkpoints",),
    "loras": ("loras",),
    "text_encoders": ("text_encoders", "clip"),
    "vae": ("vae",),
}


def _folder_candidates(category: str) -> list[Path]:
    aliases = _CATEGORY_ALIASES.get(category)
    if not aliases:
        raise ValueError(f"Unsupported model category: {category}")

    result: list[Path] = []
    for alias in aliases:
        try:
            for item in folder_paths.get_folder_paths(alias):
                path = Path(item).expanduser().resolve()
                if path not in result:
                    result.append(path)
        except Exception:
            pass

    if not result:
        models_dir = Path(folder_paths.models_dir).resolve()
        fallback = {
            "diffusion_models": "diffusion_models",
            "checkpoints": "checkpoints",
            "loras": "loras",
            "text_encoders": "text_encoders",
            "vae": "vae",
        }[category]
        result.append(models_dir / fallback)
    return result


def _powershell_pick(initial_dir: Path) -> str | None:
    if sys.platform != "win32":
        raise RuntimeError("Browse on PC is currently supported on Windows.")

    escaped_dir = str(initial_dir).replace("'", "''")
    script = f"""
Add-Type -AssemblyName System.Windows.Forms
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Title = 'Mini Studio - Select model'
$dialog.InitialDirectory = '{escaped_dir}'
$dialog.Filter = 'AI model files|*.safetensors;*.ckpt;*.pt;*.pth;*.bin;*.gguf|All files|*.*'
$dialog.Multiselect = $false
$dialog.RestoreDirectory = $true
if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {{
    Write-Output $dialog.FileName
}}
"""
    encoded = script.encode("utf-16le")
    import base64
    command = base64.b64encode(encoded).decode("ascii")
    completed = subprocess.run(
        ["powershell.exe", "-NoProfile", "-STA", "-EncodedCommand", command],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    if completed.returncode != 0:
        message = completed.stderr.strip() or "Windows file picker failed."
        raise RuntimeError(message)
    selected = completed.stdout.strip().splitlines()
    return selected[-1].strip() if selected else None


def _relative_to_any(path: Path, roots: list[Path]) -> tuple[str, Path] | None:
    resolved = path.resolve()
    for root in roots:
        try:
            relative = resolved.relative_to(root.resolve())
            return relative.as_posix(), root
        except ValueError:
            continue
    return None


def _unique_destination(root: Path, source: Path) -> Path:
    destination = root / source.name
    if not destination.exists():
        return destination
    try:
        if destination.samefile(source):
            return destination
    except OSError:
        pass

    stem, suffix = source.stem, source.suffix
    for index in range(1, 1000):
        candidate = root / f"{stem}-imported-{index}{suffix}"
        if not candidate.exists():
            return candidate
    raise RuntimeError("Could not choose a free destination filename.")


def _import_model(source: Path, destination: Path) -> str:
    destination.parent.mkdir(parents=True, exist_ok=True)

    try:
        os.symlink(source, destination)
        return "linked"
    except OSError:
        pass

    try:
        os.link(source, destination)
        return "hardlinked"
    except OSError:
        pass

    shutil.copy2(source, destination)
    return "copied"


def _pick_and_prepare(category: str) -> dict:
    roots = _folder_candidates(category)
    primary = roots[0]
    primary.mkdir(parents=True, exist_ok=True)

    picked = _powershell_pick(primary)
    if not picked:
        return {"ok": False, "cancelled": True}

    source = Path(picked).expanduser().resolve()
    if not source.is_file():
        raise RuntimeError("The selected file does not exist.")
    if source.suffix.lower() not in _ALLOWED_EXTENSIONS:
        raise RuntimeError("Unsupported model file type.")

    existing = _relative_to_any(source, roots)
    if existing:
        relative, _ = existing
        return {
            "ok": True,
            "filename": relative,
            "action": "existing",
            "source": str(source),
        }

    destination = _unique_destination(primary, source)
    action = _import_model(source, destination)
    relative = destination.relative_to(primary).as_posix()
    return {
        "ok": True,
        "filename": relative,
        "action": action,
        "source": str(source),
        "destination": str(destination),
    }


@PromptServer.instance.routes.get("/ministudio/model-picker/status")
async def ministudio_model_picker_status(request):
    categories = {}
    for category in _CATEGORY_ALIASES:
        try:
            categories[category] = [str(path) for path in _folder_candidates(category)]
        except Exception:
            categories[category] = []
    return web.json_response({
        "ok": True,
        "platform": sys.platform,
        "windowsPicker": sys.platform == "win32",
        "categories": categories,
    })


@PromptServer.instance.routes.post("/ministudio/model-picker/pick")
async def ministudio_model_picker_pick(request):
    try:
        payload = await request.json()
        category = str(payload.get("category", "")).strip()
        if category not in _CATEGORY_ALIASES:
            return web.json_response({"ok": False, "error": "Unsupported model category."}, status=400)

        result = await asyncio.to_thread(_pick_and_prepare, category)
        return web.json_response(result)
    except json.JSONDecodeError:
        return web.json_response({"ok": False, "error": "Invalid JSON body."}, status=400)
    except Exception as exc:
        return web.json_response({"ok": False, "error": str(exc)}, status=500)
