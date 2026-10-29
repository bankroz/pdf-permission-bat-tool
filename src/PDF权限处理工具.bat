@echo off
setlocal DisableDelayedExpansion
set "TOOL_ROOT=%~dp0"
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%TOOL_ROOT%tools\pdf_tool.ps1" %*
set "TOOL_EXIT=%ERRORLEVEL%"
echo(
pause
exit /b %TOOL_EXIT%
