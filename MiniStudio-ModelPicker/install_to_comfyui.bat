@echo off
setlocal
title Mini Studio Model Picker Installer
echo.
echo Mini Studio Model Picker
echo =========================
echo.
set "COMFY="
set /p COMFY=Enter or paste your ComfyUI folder path: 
set "COMFY=%COMFY:"=%"
if not exist "%COMFY%\main.py" (
  echo.
  echo main.py was not found in "%COMFY%".
  echo Please enter the actual ComfyUI folder, not the portable parent folder.
  pause
  exit /b 1
)
set "DEST=%COMFY%\custom_nodes\MiniStudio-ModelPicker"
if exist "%DEST%" rmdir /s /q "%DEST%"
mkdir "%DEST%"
copy /y "%~dp0__init__.py" "%DEST%\__init__.py" >nul
copy /y "%~dp0README.md" "%DEST%\README.md" >nul
echo.
echo Installed to:
echo %DEST%
echo.
echo Restart ComfyUI, then use Models ^& LoRA ^> Browse on PC from the iPhone app.
pause
