# FastShare Release 构建脚本
# 输出: 4 个 Android APK（分架构 + 全架构）+ Windows ZIP
# 用法: .\scripts\build_release.ps1

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$releaseDir = "$root\release"
$ver = (Get-Content "$root\pubspec.yaml" | Select-String 'version:\s*(\S+)').Matches.Groups[1].Value
$date = Get-Date -Format "yyyyMMdd"

Write-Host "=== FastShare v$ver Release 构建 ==="
Write-Host "输出目录: $releaseDir`n"

# 清理
if (Test-Path $releaseDir) { Remove-Item $releaseDir -Recurse -Force }
New-Item $releaseDir -ItemType Directory | Out-Null

Push-Location $root

# ═══════════════════════════════════════════
# Android: 3 个分架构 + 1 个全架构
# ═══════════════════════════════════════════
$androidPlatforms = @(
    @{Name="arm64-v8a"; Flag="android-arm64"},
    @{Name="armeabi-v7a"; Flag="android-arm"},
    @{Name="x86_64"; Flag="android-x64"},
    @{Name="all"; Flag=""}
)

foreach ($plat in $androidPlatforms) {
    $name = $plat.Name
    $flag = $plat.Flag
    Write-Host "--- Android $name ---"

    if ($flag) {
        flutter build apk --release --target-platform $flag 2>&1 | Select-String "Built|FAILED"
    } else {
        flutter build apk --release 2>&1 | Select-String "Built|FAILED"
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Android $name build failed!" -ForegroundColor Red
        Pop-Location; exit 1
    }

    $src = "$root\build\app\outputs\flutter-apk\app-release.apk"
    $dst = "$releaseDir\fastshare-v$ver-$name.apk"
    Copy-Item $src $dst
    $size = [math]::Round((Get-Item $dst).Length / 1MB, 1)
    Write-Host "  $dst ($size MB)`n"
}

# ═══════════════════════════════════════════
# Windows: ZIP 打包
# ═══════════════════════════════════════════
Write-Host "--- Windows ---"
flutter build windows --release 2>&1 | Select-String "Built|FAILED"
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Windows build failed!" -ForegroundColor Red
    Pop-Location; exit 1
}

$winSrc = "$root\build\windows\x64\runner\Release\*"
$winZip = "$releaseDir\fastshare-v$ver-windows-x64.zip"
Compress-Archive -Path $winSrc -DestinationPath $winZip -CompressionLevel Optimal -Force
$size = [math]::Round((Get-Item $winZip).Length / 1MB, 1)
Write-Host "  $winZip ($size MB)`n"

Pop-Location

# ═══════════════════════════════════════════
# 汇总
# ═══════════════════════════════════════════
Write-Host "=== 构建完成 v$ver ==="
Get-ChildItem $releaseDir | ForEach-Object {
    $s = [math]::Round($_.Length / 1MB, 1)
    Write-Host "  $($_.Name)  $s MB"
}
Write-Host "`n上传到 GitHub Releases: https://github.com/linglu114/Fast-Share/releases/new"
