# FastShare Release 构建脚本
# 输出: 4 个 Android APK（arm64 / arm / x64 / all）+ Windows ZIP
# 用法: powershell -File scripts\build_release.ps1

$ErrorActionPreference = "Continue"
$root = Split-Path $PSScriptRoot -Parent
$releaseDir = "$root\release"

# 读取版本号
$pubspec = Get-Content "$root\pubspec.yaml" -Raw
$ver = "1.0.0"
if ($pubspec -match 'version:\s*(\S+)') { $ver = $Matches[1] }

Write-Host "=== FastShare v$ver Release 构建 ==="
Write-Host ""

if (Test-Path $releaseDir) { Remove-Item $releaseDir -Recurse -Force }
New-Item $releaseDir -ItemType Directory | Out-Null

Push-Location $root

# ═══════════════════════════════════════════
# Android: 分架构 + 全架构
# ═══════════════════════════════════════════

$targets = @(
    @("arm64-v8a", "android-arm64"),
    @("armeabi-v7a", "android-arm"),
    @("x86_64", "android-x64"),
    @("all", "")
)

foreach ($t in $targets) {
    $name = $t[0]
    $flag = $t[1]

    Write-Host "--- Android $name ---"
    if ($flag -eq "") {
        flutter build apk --release 2>&1 | Out-Null
    } else {
        flutter build apk --release --target-platform $flag 2>&1 | Out-Null
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: build failed!" -ForegroundColor Red
        Pop-Location; exit 1
    }

    $src = "$root\build\app\outputs\flutter-apk\app-release.apk"
    $dst = "$releaseDir\fastshare-v$ver-$name.apk"
    Copy-Item $src $dst -Force
    $size = [math]::Round((Get-Item $dst).Length / 1MB, 1)
    Write-Host "  $dst ($size MB)"
    Write-Host ""
}

# ═══════════════════════════════════════════
# Windows: ZIP
# ═══════════════════════════════════════════
Write-Host "--- Windows ---"
flutter build windows --release 2>&1 | Out-Null

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Windows build failed!" -ForegroundColor Red
    Pop-Location; exit 1
}

$winSrc = "$root\build\windows\x64\runner\Release\*"
$winZip = "$releaseDir\fastshare-v$ver-windows-x64.zip"
Compress-Archive -Path $winSrc -DestinationPath $winZip -CompressionLevel Optimal -Force
$size = [math]::Round((Get-Item $winZip).Length / 1MB, 1)
Write-Host "  $winZip ($size MB)"
Write-Host ""

Pop-Location

# ═══════════════════════════════════════════
# 汇总
# ═══════════════════════════════════════════
Write-Host "=== 构建完成 v$ver ==="
Get-ChildItem $releaseDir | ForEach-Object {
    $s = [math]::Round($_.Length / 1MB, 1)
    $name = $_.Name.PadRight(50)
    Write-Host "  $name $s MB"
}
