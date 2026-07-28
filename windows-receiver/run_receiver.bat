@echo off
setlocal

set SCRIPT_DIR=%~dp0
set "PYTHONPATH=%SCRIPT_DIR%;%PYTHONPATH%"
python -m pc_as_screen_receiver.receiver %*

