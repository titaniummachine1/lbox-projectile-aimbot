@echo off
setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
set "TITLEFILE=title.txt"
set "DEPLOY_ROOT=%localappdata%"
if "%DEPLOY_ROOT%"=="" (
  echo [BundleAndDeploy] LOCALAPPDATA is not set. Cannot deploy.
  exit /b 1
)
set "DEPLOY_DIR=%DEPLOY_ROOT%\lua"

if not exist "%DEPLOY_ROOT%" (
  echo [BundleAndDeploy] Creating %DEPLOY_ROOT%
  mkdir "%DEPLOY_ROOT%"
)
if not exist "%DEPLOY_DIR%" (
  echo [BundleAndDeploy] Creating %DEPLOY_DIR%
  mkdir "%DEPLOY_DIR%"
)

set "BUILD_DIR=%BUNDLE_OUTPUT_DIR%"
if "%BUILD_DIR%"=="" set "BUILD_DIR=%DEPLOY_DIR%"

rem Ensure build directory exists
if not exist "%BUILD_DIR%\" mkdir "%BUILD_DIR%"

rem Run bundler (ensuring bundle.js sees BUNDLE_OUTPUT_DIR)
pushd "%SCRIPT_DIR%" >nul
set "BUNDLE_OUTPUT_DIR=%BUILD_DIR%"
node "%SCRIPT_DIR%bundle.js"
if errorlevel 1 (
  echo [BundleAndDeploy] Bundle step failed. Aborting.
  exit /b 1
)
popd >nul

rem Determine actual output file name from title.txt or default
set "OUTFILE=projaimbot.lua"
if exist "%SCRIPT_DIR%%TITLEFILE%" (
  set /p OUTFILE=<"%SCRIPT_DIR%%TITLEFILE%"
)
if "%OUTFILE%"=="" set "OUTFILE=projaimbot.lua"

set "BUNDLE_PATH=%BUILD_DIR%\%OUTFILE%"
set "DEPLOY_PATH=%DEPLOY_DIR%\%OUTFILE%"

if not exist "%BUNDLE_PATH%" (
  echo [BundleAndDeploy] Expected bundle "%BUNDLE_PATH%" not found.
  exit /b 1
)

set "_BUNDLE_READY="
for /L %%I in (1,1,20) do (
  if exist "%BUNDLE_PATH%" (
    for %%F in ("%BUNDLE_PATH%") do if %%~zF GTR 0 set "_BUNDLE_READY=1"
  )
  if defined _BUNDLE_READY goto :bundle_ready
  timeout /T 1 >nul
)

echo [BundleAndDeploy] Bundle "%BUNDLE_PATH%" not ready after waiting.
exit /b 1

:bundle_ready

if /I "%BUNDLE_PATH%"=="%DEPLOY_PATH%" (
  echo [BundleAndDeploy] Bundle already located at %DEPLOY_PATH%
) else (
  copy /Y "%BUNDLE_PATH%" "%DEPLOY_PATH%" >nul
  if errorlevel 1 (
    echo [BundleAndDeploy] Deployment failed. Ensure %DEPLOY_DIR% is writable.
    exit /b 1
  )
)

echo [BundleAndDeploy] Deployed to %DEPLOY_PATH%

rem Bundle artillery_aiming if present
set "ARTILLERY_DIR=%SCRIPT_DIR%prototypes\artillery_aiming"
if exist "%ARTILLERY_DIR%\Main.lua" (
  echo [BundleAndDeploy] Bundling artillery_aiming...
  if not exist "%ARTILLERY_DIR%\build\" mkdir "%ARTILLERY_DIR%\build"
  node "%SCRIPT_DIR%bundle-artillery.js"
  if errorlevel 1 (
    echo [BundleAndDeploy] Artillery Aiming bundle failed.
    exit /b 1
  )
  if exist "%ARTILLERY_DIR%\build\artillery_aiming.lua" (
    copy /Y "%ARTILLERY_DIR%\build\artillery_aiming.lua" "%DEPLOY_DIR%\artillery_aiming.lua" >nul
    echo [BundleAndDeploy] Artillery Aiming deployed to %DEPLOY_DIR%\artillery_aiming.lua
  ) else (
    echo [BundleAndDeploy] Artillery Aiming bundle output not found.
    exit /b 1
  )
)

rem Deploy prototypes if present (directly from source, never from build)
rem Exclude artillery_aiming subfolder (bundled separately) and old monolith
set "PROTOS_SOURCE=%SCRIPT_DIR%prototypes"
set "PROTOS_DEPLOY=%DEPLOY_DIR%"

if exist "%PROTOS_SOURCE%" (
  if not exist "!PROTOS_DEPLOY!" mkdir "!PROTOS_DEPLOY!"
  robocopy "%PROTOS_SOURCE%" "!PROTOS_DEPLOY!" *.lua /XD artillery_aiming /XF ArtileryAiming.lua /NFL /NDL /NJH /NJS /NC /NS /NP >nul
  set "RC=!ERRORLEVEL!"
  if !RC! GEQ 8 (
    echo [BundleAndDeploy] Prototype deploy failed with code !RC!.
    exit /b 1
  )
  echo [BundleAndDeploy] Prototypes deployed to !PROTOS_DEPLOY!
) else (
  echo [BundleAndDeploy] No prototypes to deploy.
)

rem Bundle simtest if present
set "SIMTEST_DIR=%SCRIPT_DIR%simtest"
if exist "%SIMTEST_DIR%\Main.lua" (
  echo [BundleAndDeploy] Bundling simtest...
  if not exist "%SIMTEST_DIR%\build\" mkdir "%SIMTEST_DIR%\build"
  node "%SCRIPT_DIR%bundle-simtest.js" >nul 2>&1
  if exist "%SIMTEST_DIR%\build\simtest.lua" (
    copy /Y "%SIMTEST_DIR%\build\simtest.lua" "%DEPLOY_DIR%\simtest.lua" >nul
    echo [BundleAndDeploy] SimTest deployed to %DEPLOY_DIR%\simtest.lua
  ) else (
    echo [BundleAndDeploy] SimTest bundle failed.
  )
)

endlocal
exit /b 0