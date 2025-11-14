@echo off
REM Fast build and launch script for Chiaki-ng on Windows
REM Usage: fastbuild.bat

echo.
echo ========================================
echo   Chiaki-ng Fast Build and Launch
echo ========================================
echo.

cd /d "%~dp0"

REM Setup MSYS2 environment
set MSYSTEM=MINGW64
set PATH=C:\msys64\mingw64\bin;C:\msys64\usr\bin;%PATH%

REM Configure with Steamworks enabled (only reconfigures if needed)
echo [1/5] Configuring with Steamworks...
C:\msys64\usr\bin\bash.exe -lc "cd /c/Users/User/repos/chiaki-ng && cmake -B build -DCHIAKI_ENABLE_STEAMWORKS=ON -DCHIAKI_ENABLE_CLI=OFF"

REM Fast incremental build
echo [2/5] Building (incremental - only changed files)...
C:\msys64\usr\bin\bash.exe -lc "cd /c/Users/User/repos/chiaki-ng && cmake --build build --config Release --target chiaki"

if errorlevel 1 (
    echo.
    echo [ERROR] Build failed!
    pause
    exit /b 1
)

echo [OK] Build successful!
echo.

REM Kill old instance if running
echo [3/5] Stopping old instance...
taskkill /F /IM chiaki.exe >nul 2>&1
ping 127.0.0.1 -n 3 >nul

REM Copy new executable and Steamworks DLL
echo [4/5] Copying new executable and dependencies...
copy /Y "build\gui\chiaki.exe" "chiaki-ng-Win\chiaki.exe" >nul
if errorlevel 1 (
    echo [WARNING] Copy may have failed. Retrying...
    ping 127.0.0.1 -n 2 >nul
    copy /Y "build\gui\chiaki.exe" "chiaki-ng-Win\chiaki.exe" >nul
)
copy /Y "third-party\steamworks\steamworks_sdk\redistributable_bin\win64\steam_api64.dll" "chiaki-ng-Win\" >nul

REM Launch application with console output
echo [5/5] Launching application with console...
echo.

REM Enable Qt debug output (but filter out verbose spam)
set QT_LOGGING_RULES=*.info=true;chiaki.gui.info=true;qt.*.debug=false
set QT_MESSAGE_PATTERN=[%%{time}] [%%{type}] %%{message}
set CHIAKI_ENABLE_CLI=0

echo.
echo ========================================
echo   Launching Application:
echo ========================================
echo.

REM Run directly so we can see logs (including errors)
"chiaki-ng-Win\chiaki.exe"

echo.
echo Exit code: %ERRORLEVEL%

echo.
echo ========================================
echo   Application Closed
echo ========================================
echo.

