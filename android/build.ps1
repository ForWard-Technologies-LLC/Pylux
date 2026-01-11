# Simple Android build script for chiaki-ng
# Usage: .\build.ps1 [debug|release] [-quick] [-clean] [-abi <abi>] [-install] [-launch]

param(
    [string]$BuildType = "debug",
    [switch]$Quick = $false,
    [switch]$Clean = $false,
    [string]$Abi = "",
    [switch]$Install = $false,
    [switch]$Launch = $false
)

$ErrorActionPreference = "Continue"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Chiaki-ng Android Build Script" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Try to find Java from Android Studio or system
$javaPaths = @(
    "C:\Program Files\Android\Android Studio1\jbr",  # User's Java 21 location
    "$env:LOCALAPPDATA\Android\Android Studio\jbr",
    "C:\Program Files\Android\Android Studio\jbr",
    "$env:ProgramFiles\Android\Android Studio\jbr",
    "C:\Program Files\Android\Android Studio\jre",
    "$env:JAVA_HOME"
)

$javaFound = $false
foreach ($javaPath in $javaPaths) {
    if ($javaPath -and (Test-Path $javaPath)) {
        $env:JAVA_HOME = $javaPath
        $env:PATH = "$javaPath\bin;$env:PATH"
        Write-Host "[OK] Java configured: $javaPath" -ForegroundColor Green
        $javaFound = $true
        break
    }
}

if (-not $javaFound) {
    Write-Host "[FAIL] Java not found. Please ensure Android Studio is installed or set JAVA_HOME" -ForegroundColor Red
    Write-Host "       Tried locations:" -ForegroundColor Yellow
    $javaPaths | ForEach-Object { if ($_) { Write-Host "       - $_" -ForegroundColor Yellow } }
    exit 1
}

# Fix Python PATH - ensure real Python comes before Windows Store stub
$pythonPath = "$env:LOCALAPPDATA\Programs\Python"
$pythonExe = $null
if (Test-Path $pythonPath) {
    $pythonDirs = Get-ChildItem $pythonPath -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
    foreach ($pyDir in $pythonDirs) {
        $pyExe = Join-Path $pyDir.FullName "python.exe"
        if (Test-Path $pyExe) {
            $version = & $pyExe --version 2>&1
            if ($version -match "Python 3") {
                $pythonExe = $pyExe
                # Remove WindowsApps from PATH to prevent CMake from finding the stub
                $newPath = $env:PATH -split ';' | Where-Object { $_ -notlike "*WindowsApps*" }
                $env:PATH = "$($pyDir.FullName);$($pyDir.FullName)\Scripts;" + ($newPath -join ';')
                $env:PYTHON_EXECUTABLE = $pyExe
                Write-Host "[OK] Python configured: $($pyDir.FullName) - $version" -ForegroundColor Green
                break
            }
        }
    }
} else {
    Write-Host "[WARN] Python not found in standard location, CMake may have issues" -ForegroundColor Yellow
}

# Set Python for CMake if found
if ($pythonExe) {
    $env:PYTHON_EXECUTABLE = $pythonExe
}

# Set Android SDK
$sdkPath = "$env:LOCALAPPDATA\Android\Sdk"
if (Test-Path $sdkPath) {
    $env:ANDROID_SDK_ROOT = $sdkPath
    $env:ANDROID_HOME = $sdkPath
    
    # Find and use CMake 3.22.1+ if available
    $cmakePath = Join-Path $sdkPath "cmake"
    $hasNewCmake = $false
    if (Test-Path $cmakePath) {
        $cmakeVersions = Get-ChildItem $cmakePath -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
        foreach ($cmakeDir in $cmakeVersions) {
            $versionStr = $cmakeDir.Name -replace '[^0-9.]', ''
            try {
                $version = [version]$versionStr
                if ($version -ge [version]"3.22.1") {
                    $cmakeBin = Join-Path $cmakeDir.FullName "bin"
                    if (Test-Path $cmakeBin) {
                        $env:PATH = "$cmakeBin;$env:PATH"
                        Write-Host "[OK] Using CMake: $($cmakeDir.Name)" -ForegroundColor Green
                        $hasNewCmake = $true
                        break
                    }
                }
            } catch {
                # Skip invalid version strings
            }
        }
    }
    
    if (-not $hasNewCmake) {
        Write-Host "[WARN] CMake 3.22.1+ required but not found." -ForegroundColor Yellow
        Write-Host "       Please install via Android Studio: Tools > SDK Manager > SDK Tools > CMake" -ForegroundColor Yellow
    }
    
    # Find and set NDK path
    $ndkPath = Join-Path $sdkPath "ndk"
    if (Test-Path $ndkPath) {
        $ndkVersions = Get-ChildItem $ndkPath -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
        if ($ndkVersions) {
            $latestNdk = $ndkVersions[0]
            $env:ANDROID_NDK_HOME = $latestNdk.FullName
            Write-Host "[OK] Using NDK: $($latestNdk.Name)" -ForegroundColor Green
        }
    } else {
        # Try ndk-bundle for older installations
        $ndkBundle = Join-Path $sdkPath "ndk-bundle"
        if (Test-Path $ndkBundle) {
            $env:ANDROID_NDK_HOME = $ndkBundle
            Write-Host "[OK] Using NDK: ndk-bundle" -ForegroundColor Green
        }
    }
    
    Write-Host "[OK] Android SDK configured: $sdkPath" -ForegroundColor Green
} else {
    Write-Host "[FAIL] Android SDK not found at: $sdkPath" -ForegroundColor Red
    exit 1
}

# Ensure local.properties exists
$localProps = "local.properties"
if (-not (Test-Path $localProps)) {
    $escaped = $sdkPath -replace '\\', '\\'
    "sdk.dir=$escaped" | Out-File -FilePath $localProps -Encoding UTF8
    Write-Host "[OK] Created local.properties" -ForegroundColor Green
}

Write-Host ""

# Track overall script execution time
$scriptStart = Get-Date

# If launch-only mode, skip build and install, just launch the app
if ($Launch) {
    Write-Host "[LAUNCH ONLY] Skipping build, just launching app..." -ForegroundColor Cyan
    $sdkPath = "$env:LOCALAPPDATA\Android\Sdk"
    if (-not (Test-Path $sdkPath)) {
        $sdkPath = "C:\Users\$env:USERNAME\AppData\Local\Android\Sdk"
    }
    
    $adb = Join-Path $sdkPath "platform-tools\adb.exe"
    if (-not (Test-Path $adb)) {
        Write-Host "[ERROR] ADB not found at: $adb" -ForegroundColor Red
        exit 1
    }
    
    # Check for connected devices
    Write-Host "Checking for connected devices..." -ForegroundColor Yellow
    $devices = & $adb devices 2>&1
    $deviceConnected = $false
    foreach ($line in $devices) {
        if ($line -match "^\w+\s+device\s*$") {
            $deviceConnected = $true
            Write-Host "Device found: $line" -ForegroundColor Green
            break
        }
    }
    
    if (-not $deviceConnected) {
        Write-Host "[ERROR] No Android device/emulator connected." -ForegroundColor Red
        Write-Host "Connected devices:" -ForegroundColor Yellow
        Write-Host $devices
        exit 1
    }
    
    Write-Host ""
    Write-Host "Launching app..." -ForegroundColor Cyan
    & $adb shell am start -n com.metallic.chiaki/.main.MainActivity 2>&1 | Out-Host
    if ($LASTEXITCODE -eq 0) {
        Write-Host "App launched successfully!" -ForegroundColor Green
    } else {
        Write-Host "[WARN] Failed to launch app (exit code: $LASTEXITCODE)" -ForegroundColor Yellow
        Write-Host "       Make sure the app is already installed on the device" -ForegroundColor Yellow
        exit 1
    }
    
    $totalDuration = (Get-Date) - $scriptStart
    Write-Host ""
    Write-Host "[TIMING] Total time: $($totalDuration.TotalSeconds.ToString('F2'))s" -ForegroundColor Cyan
    exit 0
}

# If install-only mode, skip build and go straight to install/launch
if ($Install) {
    Write-Host "[INSTALL ONLY] Skipping build, installing and launching existing APK..." -ForegroundColor Cyan
    $sdkPath = "$env:LOCALAPPDATA\Android\Sdk"
    if (-not (Test-Path $sdkPath)) {
        $sdkPath = "C:\Users\$env:USERNAME\AppData\Local\Android\Sdk"
    }
    
    # Find APK
    $outputPaths = @(
        "app\build\outputs\apk\debug\app-debug.apk",
        "app\build\intermediates\apk\debug\app-debug.apk"
    )
    if ($BuildType -eq "release") {
        $outputPaths = @(
            "app\build\outputs\apk\release\app-release-unsigned.apk",
            "app\build\intermediates\apk\release\app-release-unsigned.apk"
        )
    }
    
    $apkPath = $null
    foreach ($path in $outputPaths) {
        if (Test-Path $path) {
            $apkPath = (Resolve-Path $path).Path
            break
        }
    }
    
    if (-not $apkPath) {
        Write-Host "[ERROR] APK not found. Run build first." -ForegroundColor Red
        exit 1
    }
    
    Write-Host "Found APK: $apkPath" -ForegroundColor Green
    
    # Install and launch
    $adb = Join-Path $sdkPath "platform-tools\adb.exe"
    if (-not (Test-Path $adb)) {
        Write-Host "[ERROR] ADB not found at: $adb" -ForegroundColor Red
        exit 1
    }
    
    # Check for connected devices - fix regex to match properly
    Write-Host "Checking for connected devices..." -ForegroundColor Yellow
    $devices = & $adb devices 2>&1
    $deviceConnected = $false
    foreach ($line in $devices) {
        if ($line -match "^\w+\s+device\s*$") {
            $deviceConnected = $true
            Write-Host "Device found: $line" -ForegroundColor Green
            break
        }
    }
    
    if (-not $deviceConnected) {
        Write-Host "[ERROR] No Android device/emulator connected." -ForegroundColor Red
        Write-Host "Connected devices:" -ForegroundColor Yellow
        Write-Host $devices
        exit 1
    }
    
    Write-Host ""
    Write-Host "Installing APK..." -ForegroundColor Cyan
    $installStart = Get-Date
    & $adb install -r -t $apkPath 2>&1 | Out-Host
    $installDuration = (Get-Date) - $installStart
    if ($LASTEXITCODE -eq 0) {
        Write-Host "App installed successfully! (took $($installDuration.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green
        Write-Host "Launching app..." -ForegroundColor Cyan
        & $adb shell am start -n com.metallic.chiaki/.main.MainActivity 2>&1 | Out-Host
        if ($LASTEXITCODE -eq 0) {
            Write-Host "App launched successfully!" -ForegroundColor Green
        } else {
            Write-Host "[WARN] Failed to launch app (exit code: $LASTEXITCODE)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "[ERROR] Failed to install APK (exit code: $LASTEXITCODE)" -ForegroundColor Red
        exit 1
    }
    
    $totalDuration = (Get-Date) - $scriptStart
    Write-Host ""
    Write-Host "[TIMING] Total time: $($totalDuration.TotalSeconds.ToString('F2'))s" -ForegroundColor Cyan
    exit 0
}

Write-Host "Starting build ($BuildType)..." -ForegroundColor Yellow

# Handle clean - Clean takes precedence over Quick
if ($Clean) {
    Write-Host "[CLEAN] Removing build artifacts..." -ForegroundColor Yellow
    $cleanStart = Get-Date
    Remove-Item -Path "app\.cxx" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "app\build" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path ".gradle" -Recurse -Force -ErrorAction SilentlyContinue
    $cleanDuration = (Get-Date) - $cleanStart
    Write-Host "[TIMING] Clean completed in $($cleanDuration.TotalSeconds.ToString('F2'))s" -ForegroundColor Green
} elseif ($Quick) {
    Write-Host "[QUICK MODE] Skipping clean, tests, and linting" -ForegroundColor Yellow
}

Write-Host ""

# Build with optimizations
$buildTask = if ($BuildType -eq "release") { "assembleRelease" } else { "assembleDebug" }
$logFile = "build-output.txt"

# Build arguments for speed
$gradleArgs = @($buildTask)
$gradleArgs += "--parallel"  # Parallel builds
$gradleArgs += "--build-cache"  # Use build cache
# Note: Gradle daemon stays running by default for faster subsequent builds

# Only build specific ABI if specified (much faster)
if ($Abi) {
    $gradleArgs += "-Pandroid.injected.build.abi=$Abi"
    Write-Host "[ABI] Building only: $Abi" -ForegroundColor Yellow
} elseif ($Quick) {
    # In quick mode, default to arm64-v8a only (most common)
    $gradleArgs += "-Pandroid.injected.build.abi=arm64-v8a"
    Write-Host "[QUICK] Building only arm64-v8a (add -abi <abi> to override)" -ForegroundColor Yellow
}

# Skip tests and linting in quick mode
if ($Quick) {
    $gradleArgs += "-x" + "test"
    $gradleArgs += "-x" + "lint"
    $gradleArgs += "-x" + "lintVitalRelease"
}

# Only add stacktrace if not in quick mode (slower)
if (-not $Quick) {
    $gradleArgs += "--stacktrace"
}

Write-Host "Running: .\gradlew.bat $($gradleArgs -join ' ') (output: $logFile)" -ForegroundColor Cyan
Write-Host ""

# Clear/create output file before starting build
if (Test-Path $logFile) {
    Remove-Item $logFile -Force
}
New-Item -Path $logFile -ItemType File -Force | Out-Null

Write-Host "Building... (showing progress every 10 seconds)" -ForegroundColor Yellow

# Build with progress monitoring and timing
$buildStart = Get-Date
$lineCount = 0

# Run Gradle and monitor output - use simple approach with Start-Process and wait
# Get full path to gradlew.bat
$gradlewPath = Join-Path $PWD.Path "gradlew.bat"
if (-not (Test-Path $gradlewPath)) {
    Write-Host "[ERROR] gradlew.bat not found at: $gradlewPath" -ForegroundColor Red
    exit 1
}

# Use Start-Process with file redirection - simpler and more reliable
$buildProcess = Start-Process -FilePath $gradlewPath -ArgumentList $gradleArgs -NoNewWindow -PassThru -RedirectStandardOutput $logFile -RedirectStandardError "$logFile.err" -Wait:$false

if (-not $buildProcess) {
    Write-Host "[ERROR] Failed to start Gradle build process" -ForegroundColor Red
    exit 1
}

$lastProgressUpdate = Get-Date
while (-not $buildProcess.HasExited) {
    Start-Sleep -Milliseconds 2000
    $now = Get-Date
    $elapsed = ($now - $buildStart).TotalSeconds
    
    # Update progress every 10 seconds
    if (($now - $lastProgressUpdate).TotalSeconds -ge 10) {
        if (Test-Path $logFile) {
            try {
                # Read file with error handling - file might be locked
                $content = @()
                try {
                    $content = Get-Content $logFile -ErrorAction Stop
                } catch {
                    # File might be locked, try again
                    Start-Sleep -Milliseconds 500
                    $content = Get-Content $logFile -ErrorAction SilentlyContinue
                }
                
                $currentLines = $content.Count
                $newLines = $currentLines - $lineCount
                $lineCount = $currentLines
                
                # Get current task
                $currentTask = "Running..."
                $currentTaskLine = $content | Select-String -Pattern "> Task :" | Select-Object -Last 1
                if ($currentTaskLine) {
                    $currentTask = ($currentTaskLine.Line -replace "> Task :", "").Trim()
                }
                
                $fileSize = if (Test-Path $logFile) { ((Get-Item $logFile -ErrorAction SilentlyContinue).Length / 1KB) } else { 0 }
                Write-Host "[PROGRESS] ${elapsed.ToString('F0')}s elapsed | $currentLines lines (+$newLines) | ${fileSize.ToString('F1')}KB | Task: $currentTask" -ForegroundColor Gray
                
                # Show CMake/ninja progress
                $cmakeProgress = $content | Select-String -Pattern "ninja:|CMake|\[.*/.*\]" | Select-Object -Last 1
                if ($cmakeProgress) {
                    $progressLine = $cmakeProgress.Line.Trim()
                    if ($progressLine.Length -gt 80) { $progressLine = $progressLine.Substring(0, 77) + "..." }
                    Write-Host "  Native: $progressLine" -ForegroundColor DarkGray
                }
            } catch { }
        }
        $lastProgressUpdate = $now
    }
}

# Final wait to ensure process is fully terminated
$buildProcess.WaitForExit()

# Merge error output if it exists
if (Test-Path "$logFile.err") {
    Get-Content "$logFile.err" | Add-Content $logFile
    Remove-Item "$logFile.err"
}

$buildDuration = (Get-Date) - $buildStart
$buildOutput = Get-Content $logFile -ErrorAction SilentlyContinue
$exitCode = $buildProcess.ExitCode

Write-Host ""
Write-Host "[TIMING] Script execution time: $($buildDuration.TotalMinutes.ToString('F2')) minutes ($($buildDuration.TotalSeconds.ToString('F2'))s)" -ForegroundColor Cyan
if ($actualBuildTime) {
    Write-Host "[TIMING] Gradle build time: $actualBuildTime" -ForegroundColor Cyan
}
Write-Host "[TIMING] Total output: $($buildOutput.Count) lines" -ForegroundColor Cyan

# Check if build succeeded - parse actual build time from Gradle output
$buildSuccessLine = $buildOutput | Select-String -Pattern "BUILD SUCCESSFUL" | Select-Object -Last 1
$buildFailedLine = $buildOutput | Select-String -Pattern "BUILD FAILED" | Select-Object -Last 1

$buildSucceeded = $null -ne $buildSuccessLine
$buildFailed = $null -ne $buildFailedLine

# Extract actual build time from Gradle output if available
$actualBuildTime = $null
if ($buildSuccessLine) {
    if ($buildSuccessLine.Line -match "BUILD SUCCESSFUL in (.+)") {
        $actualBuildTime = $matches[1].Trim()
    }
}

# Analyze build phases and timing
Write-Host ""
Write-Host "Build phase analysis:" -ForegroundColor Yellow

# Find CMake and Ninja phases
$cmakeConfigLines = $buildOutput | Select-String -Pattern "configureCMake|CMake Warning" | Measure-Object
$ninjaBuildLines = $buildOutput | Select-String -Pattern "ninja:|buildCMake|externalNativeBuild" | Measure-Object
$taskLines = $buildOutput | Select-String -Pattern "^> Task :" | Measure-Object

Write-Host "  Tasks executed: $($taskLines.Count)" -ForegroundColor Gray
Write-Host "  CMake configuration lines: $($cmakeConfigLines.Count)" -ForegroundColor Gray
Write-Host "  Ninja build lines: $($ninjaBuildLines.Count)" -ForegroundColor Gray

# Count task statuses
$executedTasks = ($buildOutput | Select-String -Pattern "^> Task :.*EXECUTED$|^> Task :[^U]" | Measure-Object).Count
$cachedTasks = ($buildOutput | Select-String -Pattern "^> Task :.*FROM-CACHE" | Measure-Object).Count
$upToDateTasks = ($buildOutput | Select-String -Pattern "^> Task :.*UP-TO-DATE" | Measure-Object).Count
$noSourceTasks = ($buildOutput | Select-String -Pattern "^> Task :.*NO-SOURCE" | Measure-Object).Count

Write-Host "  Task breakdown:" -ForegroundColor Gray
Write-Host "    Executed: $executedTasks" -ForegroundColor DarkGray
Write-Host "    Cached: $cachedTasks" -ForegroundColor DarkGray
Write-Host "    Up-to-date: $upToDateTasks" -ForegroundColor DarkGray
Write-Host "    No source: $noSourceTasks" -ForegroundColor DarkGray

# Find slowest tasks (based on lines of output - rough estimate)
$taskOutputCounts = @{}
$currentTask = $null
$taskLineCount = 0
foreach ($line in $buildOutput) {
    if ($line -match "^> Task :(.+?)( UP-TO-DATE| NO-SOURCE| FROM-CACHE|$)$") {
        if ($currentTask -and $taskLineCount -gt 0) {
            if (-not $taskOutputCounts.ContainsKey($currentTask)) {
                $taskOutputCounts[$currentTask] = 0
            }
            $taskOutputCounts[$currentTask] += $taskLineCount
        }
        $currentTask = $matches[1]
        $taskLineCount = 0
    } else {
        $taskLineCount++
    }
}
# Add last task
if ($currentTask) {
    if (-not $taskOutputCounts.ContainsKey($currentTask)) {
        $taskOutputCounts[$currentTask] = 0
    }
    $taskOutputCounts[$currentTask] += $taskLineCount
}

if ($taskOutputCounts.Count -gt 0) {
    Write-Host ""
    Write-Host "Tasks with most output (likely slowest):" -ForegroundColor Yellow
    $slowest = $taskOutputCounts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 10
    foreach ($task in $slowest) {
        Write-Host "  :$($task.Key) - ~$($task.Value) output lines" -ForegroundColor Gray
    }
}

# Check for native build timing indicators
$ninjaProgressLines = $buildOutput | Select-String -Pattern "\[.*/.*\]" | Measure-Object
if ($ninjaProgressLines.Count -gt 0) {
    Write-Host ""
    Write-Host "Native build:" -ForegroundColor Yellow
    Write-Host "  Ninja progress lines: $($ninjaProgressLines.Count) (more = longer build)" -ForegroundColor Gray
}

if (-not $buildSucceeded -or $buildFailed) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "Build FAILED!" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "Last 20 lines of output:" -ForegroundColor Yellow
    $buildOutput | Select-Object -Last 20 | ForEach-Object { Write-Host $_ }
    exit 1
}

if ($buildSucceeded) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Build completed successfully!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    
    # Check both standard output location and intermediates (used when ABI filter is set)
    $outputPaths = @()
    if ($BuildType -eq "release") {
        $outputPaths += "app\build\outputs\apk\release\app-release-unsigned.apk"
        $outputPaths += "app\build\intermediates\apk\release\app-release-unsigned.apk"
    } else {
        $outputPaths += "app\build\outputs\apk\debug\app-debug.apk"
        $outputPaths += "app\build\intermediates\apk\debug\app-debug.apk"
    }
    
    $apkFound = $false
    $apkPath = $null
    foreach ($outputPath in $outputPaths) {
        if (Test-Path $outputPath) {
            $apkPath = (Resolve-Path $outputPath).Path
            $apkFile = Get-Item $apkPath
            Write-Host "APK location: $apkPath" -ForegroundColor Cyan
            Write-Host "APK size: $([math]::Round($apkFile.Length / 1MB, 2)) MB" -ForegroundColor Cyan
            $apkFound = $true
            break
        }
    }
    
    if (-not $apkFound) {
        Write-Host "[WARN] APK not found in expected locations. Searching..." -ForegroundColor Yellow
        $foundApks = Get-ChildItem -Path "app\build" -Recurse -Filter "*.apk" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($foundApks) {
            $apkPath = $foundApks[0].FullName
            Write-Host "Found APK at: $apkPath ($([math]::Round($foundApks[0].Length / 1MB, 2)) MB)" -ForegroundColor Yellow
            $apkFound = $true
        } else {
            Write-Host "[ERROR] No APK files found anywhere in build directory" -ForegroundColor Red
        }
    }
    
    # Install and launch app if APK found
    if ($apkFound -and $apkPath) {
        $adb = Join-Path $sdkPath "platform-tools\adb.exe"
        if (Test-Path $adb) {
            Write-Host ""
            Write-Host "Launching app..." -ForegroundColor Cyan
            
            # Check for connected devices - fix regex to match properly
            Write-Host "Checking for connected devices..." -ForegroundColor Yellow
            $devices = & $adb devices 2>&1
            $deviceConnected = $false
            foreach ($line in $devices) {
                if ($line -match "^\w+\s+device\s*$") {
                    $deviceConnected = $true
                    Write-Host "Device found: $line" -ForegroundColor Green
                    break
                }
            }
            
            if ($deviceConnected) {
                Write-Host "Launching app..." -ForegroundColor Yellow
                & $adb shell am start -n com.metallic.chiaki/.main.MainActivity 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "App launched successfully!" -ForegroundColor Green
                } else {
                    Write-Host "[WARN] Failed to launch app (exit code: $LASTEXITCODE)" -ForegroundColor Yellow
                    Write-Host "       Make sure the app is already installed on the device" -ForegroundColor Yellow
                }
            } else {
                Write-Host "[WARN] No Android device/emulator connected. Skipping install/launch." -ForegroundColor Yellow
                Write-Host "Connected devices output:" -ForegroundColor Yellow
                Write-Host $devices
                Write-Host ""
                Write-Host "To install manually, run:" -ForegroundColor Yellow
                Write-Host "  adb install -r -t `"$apkPath`"" -ForegroundColor Cyan
            }
        } else {
            Write-Host "[WARN] ADB not found. Cannot install/launch app automatically." -ForegroundColor Yellow
        }
    }
    
    # Total script execution time
    $totalDuration = (Get-Date) - $scriptStart
    Write-Host ""
    Write-Host "[TIMING] Total script execution time: $($totalDuration.TotalMinutes.ToString('F2')) minutes ($($totalDuration.TotalSeconds.ToString('F2'))s)" -ForegroundColor Cyan
} else {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "Build failed!" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    
    # Show the actual error from the output
    $errorLines = $buildOutput | Select-String -Pattern "What went wrong|FAILURE|Caused by|Exception" -Context 0,5
    if ($errorLines) {
        Write-Host "`nError details:" -ForegroundColor Yellow
        $errorLines | ForEach-Object { Write-Host $_.Line -ForegroundColor Red }
    }
    
    exit 1
}
