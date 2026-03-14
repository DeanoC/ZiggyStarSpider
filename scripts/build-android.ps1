param(
    [string]$JavaHome = "C:\Program Files\Eclipse Adoptium\jdk-17.0.17.10-hotspot",
    [string]$AndroidSdkRoot = "$env:LOCALAPPDATA\Android\Sdk"
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "android-env.ps1") -JavaHome $JavaHome -AndroidSdkRoot $AndroidSdkRoot

zig build apk -Dtarget=aarch64-linux-android
