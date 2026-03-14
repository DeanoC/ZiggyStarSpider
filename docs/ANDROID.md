# Android Build

SpiderApp can now build a local debug Android APK for `arm64-v8a`.

## Prerequisites

- Zig 0.15.x on `PATH`
- JDK 17
- Android SDK with build-tools and platform-tools
- Android NDK

Environment variables:

- `JAVA_HOME`
- `ANDROID_SDK_ROOT`

## Build

PowerShell:

```powershell
.\scripts\build-android.ps1
```

Direct Zig invocation:

```powershell
$env:JAVA_HOME="C:\Program Files\Eclipse Adoptium\jdk-17.0.17.10-hotspot"
$env:ANDROID_SDK_ROOT="$env:LOCALAPPDATA\Android\Sdk"
zig build apk -Dtarget=aarch64-linux-android
```

The build emits a debug APK for `arm64-v8a` at `zig-out/bin/main.apk`.
The first build may fetch Dawn sources as part of the Android renderer toolchain setup.

## Install

```powershell
adb install -r .\zig-out\bin\main.apk
```

If the installed APK filename differs, install the generated APK from `zig-out/bin/`.
