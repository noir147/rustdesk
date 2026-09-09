# Local Android (arm64) build of the custom RustDesk app. Dart-only changes:
# the Rust native library (librustdesk.so / libc++_shared.so) and the
# flutter_rust_bridge generated sources are taken from a CI build once and
# reused (see .github/workflows/android-custom.yml). ASCII only.
#
#   powershell -ExecutionPolicy Bypass -File build_android_local.ps1 [-Tag tv2]
#
# Prerequisites (mothership, 2026-09-10):
#   C:\dev\flutter (3.24.5 + .github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff)
#   scoop temurin17-jdk, Android SDK at %LOCALAPPDATA%\Android\Sdk
#   flutter/android/key.properties -> C:\dev\rustdesk-keys\custom.jks (persistent signature)
#   flutter/lib/generated_bridge*.dart, src/bridge_generated*.rs, jniLibs/arm64-v8a/*.so
param(
    [string]$Tag = (Get-Date -Format 'yyyyMMdd-HHmm'),
    [string]$OutDir = 'C:\dev\installers'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:JAVA_HOME = "$HOME\scoop\apps\temurin17-jdk\current"
$env:ANDROID_HOME = "$HOME\AppData\Local\Android\Sdk"
$env:PATH = "C:\dev\flutter\bin;$env:JAVA_HOME\bin;$env:PATH"
# pub cannot resolve symlinks on the RAM-disk TEMP (R:\Temp) -> use NTFS
New-Item -ItemType Directory -Force 'C:\dev\tmp' | Out-Null
$env:TEMP = 'C:\dev\tmp'; $env:TMP = 'C:\dev\tmp'
Remove-Item Env:\JAVA_TOOL_OPTIONS -ErrorAction SilentlyContinue
# app/build.gradle normally asks `cargo metadata` where the rustls-platform-verifier
# maven repo lives; without a Rust toolchain point it at the extracted crate.
$env:RUSTLS_PV_ANDROID_MAVEN_DIR = 'C:\dev\rustdesk-deps\rustls-platform-verifier-android-0.1.1\maven'

foreach ($f in 'flutter\lib\generated_bridge.dart',
               'flutter\android\app\src\main\jniLibs\arm64-v8a\librustdesk.so',
               'flutter\android\app\src\main\jniLibs\arm64-v8a\libc++_shared.so',
               'flutter\android\key.properties') {
    if (-not (Test-Path (Join-Path $root $f))) { throw "missing prerequisite: $f" }
}

Push-Location (Join-Path $root 'flutter')
# Desktop platform folders make `flutter pub get` create plugin symlinks, which
# needs Developer Mode / admin on Windows. Android-only: park them during the build.
$parked = @()
foreach ($d in 'windows', 'linux', 'macos', 'web') {
    if (Test-Path $d) { Rename-Item $d "_parked_$d"; $parked += $d }
}
try {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed' }
    flutter build apk --release --target-platform android-arm64 --split-per-abi
    if ($LASTEXITCODE -ne 0) { throw 'flutter build apk failed' }
    $apk = 'build\app\outputs\flutter-apk\app-arm64-v8a-release.apk'
    if (-not (Test-Path $apk)) { throw "apk not produced: $apk" }
    New-Item -ItemType Directory -Force $OutDir | Out-Null
    $dst = Join-Path $OutDir ("rustdesk-custom-1.4.9-{0}-aarch64.apk" -f $Tag)
    Copy-Item $apk $dst -Force
    Write-Host ("OK {0}  ({1:n0} bytes, {2:n0}s)" -f $dst, (Get-Item $dst).Length, $sw.Elapsed.TotalSeconds)
} finally {
    foreach ($d in $parked) { Rename-Item "_parked_$d" $d }
    Pop-Location
}
