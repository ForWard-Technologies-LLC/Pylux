@echo off
REM Fast build and launch script for Chiaki-ng on Windows
REM Usage: fastbuild.bat [clean]
REM   clean - Delete build folder for a fresh rebuild

echo.
echo ========================================
echo   Chiaki-ng Fast Build and Launch
echo ========================================
echo.

cd /d "%~dp0"

REM Check for clean flag
if "%1"=="clean" (
    echo [0/5] Cleaning build folder...
    if exist build (
        rmdir /s /q build
        echo [OK] Build folder deleted
    ) else (
        echo [INFO] Build folder does not exist
    )
    if exist chiaki-ng-Win (
        rmdir /s /q chiaki-ng-Win
        echo [OK] chiaki-ng-Win folder deleted
    ) else (
        echo [INFO] chiaki-ng-Win folder does not exist
    )
    echo.
)

REM Setup MSYS2 environment
set MSYSTEM=MINGW64
set PATH=C:\msys64\mingw64\bin;C:\msys64\usr\bin;%PATH%

REM Configure with Steamworks enabled (only reconfigures if needed)
echo [1/5] Configuring with Steamworks...
C:\msys64\usr\bin\bash.exe -lc "cd /c/Users/User/repos/chiaki-ng && cmake -B build -DCHIAKI_ENABLE_STEAMWORKS=ON -DCHIAKI_ENABLE_CLI=OFF -DCHIAKI_ENABLE_CONSOLE=ON"

if errorlevel 1 (
    echo.
    echo [ERROR] CMake configuration failed!
    echo Please check the error messages above.
    pause
    exit /b 1
)

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
REM Create chiaki-ng-Win folder if it doesn't exist
if not exist "chiaki-ng-Win" (
    mkdir "chiaki-ng-Win"
    echo [INFO] Created chiaki-ng-Win folder
)
copy /Y "build\gui\chiaki.exe" "chiaki-ng-Win\chiaki.exe" >nul
if errorlevel 1 (
    echo [WARNING] Copy may have failed. Retrying...
    ping 127.0.0.1 -n 2 >nul
    copy /Y "build\gui\chiaki.exe" "chiaki-ng-Win\chiaki.exe" >nul
)
copy /Y "third-party\steamworks\steamworks_sdk\redistributable_bin\win64\steam_api64.dll" "chiaki-ng-Win\" >nul
copy /Y "steam_appid.txt" "chiaki-ng-Win\" >nul 2>nul

REM Copy cpp-steam-tools DLL if it exists
if exist "build\third-party\cpp-steam-tools\libcpp-steam-tools.dll" (
    copy /Y "build\third-party\cpp-steam-tools\libcpp-steam-tools.dll" "chiaki-ng-Win\" >nul
)

REM Copy all DLL dependencies using ldd (same as GitHub Actions)
echo [INFO] Copying DLL dependencies...
C:\msys64\usr\bin\bash.exe -lc "cd /c/Users/User/repos/chiaki-ng && export PATH=\"$PWD/build/third-party/cpp-steam-tools:/mingw64/share/qt6/bin/:/mingw64/bin/:\${PATH}\" && echo chiaki-ng-Win/chiaki.exe > tmp0.txt && while [ -e tmp0.txt ]; do cp tmp0.txt tmp.txt && rm tmp0.txt && sort -u tmp.txt -o tmp.txt && ldd \$(<tmp.txt) 2>/dev/null | grep -v \":\" | cut -d \" \" -f3 | grep -iv \"system32\" | grep -iv \"not\" | xargs -d \$'\n' sh -c 'for arg do if [ -n \"\$arg\" ] && [ ! -e \"chiaki-ng-Win/\${arg##*/}\" ]; then echo \"Copied \${arg##*/}\"; cp \"\$arg\" chiaki-ng-Win/ ; echo \"\$arg\" >> tmp0.txt; fi; done'; done && rm -f tmp0.txt tmp.txt"

REM Copy Qt plugins and QML modules using windeployqt6
echo [INFO] Deploying Qt dependencies...
C:\msys64\usr\bin\bash.exe -lc "cd /c/Users/User/repos/chiaki-ng && export PATH=\"/mingw64/share/qt6/bin/:/mingw64/bin/:\${PATH}\" && windeployqt6.exe --no-translations --qmldir=gui/src/qml chiaki-ng-Win/chiaki.exe"

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

REM Run and save all output to log file
set LOGFILE=chiaki_fastbuild_logs.txt
echo Saving logs to: %LOGFILE%
echo.

REM Run with output redirected to both console and file using PowerShell
powershell -Command "& { & 'chiaki-ng-Win\chiaki.exe' 2>&1 | Tee-Object -FilePath '%LOGFILE%' }"

set EXITCODE=%ERRORLEVEL%
echo.
echo Exit code: %EXITCODE%
echo.
echo Logs saved to: %LOGFILE%

echo.
echo ========================================
echo   Application Closed
echo ========================================
echo.
