# FastShare Windows 单文件 EXE 构建脚本
# 用法: .\scripts\build_single_exe.ps1

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$releaseDir = "$root\build\windows\x64\runner\Release"
$outFile = "$root\fastshare_single.exe"

Write-Host "=== 1/3 构建 Release ==="
Push-Location $root
flutter build windows --release
Pop-Location

Write-Host "`n=== 2/3 打包为 ZIP ==="
$zipPath = "$env:TEMP\fastshare_bundle.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath }
Compress-Archive -Path "$releaseDir\*" -DestinationPath $zipPath -CompressionLevel Optimal -Force
$zipSize = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
Write-Host "ZIP: $zipSize MB"

Write-Host "`n=== 3/3 编译单文件 EXE ==="
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) {
    $csc = (Get-ChildItem "$env:WINDIR\Microsoft.NET\Framework64" -Recurse -Filter csc.exe | Select-Object -First 1).FullName
}
& $csc /target:winexe /out:$outFile /resource:$zipPath,bundle /reference:System.IO.Compression.dll "$PSScriptRoot\build_sfx.cs"
$sfxSize = [math]::Round((Get-Item $outFile).Length / 1MB, 1)

Write-Host "`n=== 完成 ==="
Write-Host "单文件 EXE: $outFile ($sfxSize MB)"
Write-Host "对比: 原始文件夹 55 MB → 单文件 $sfxSize MB"
Remove-Item $zipPath
