@echo off

node bundle.js
if errorlevel 1 (
  echo [Bundle] bundle.js failed.
  exit /b 1
)

pause