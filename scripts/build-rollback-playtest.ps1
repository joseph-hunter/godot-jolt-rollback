[CmdletBinding()]
param(
    [string]$VsDevCmd = 'C:/Program Files/Microsoft Visual Studio/2022/Community/Common7/Tools/VsDevCmd.bat',
    [string]$Toolset = '14.38'
)
$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
$output = Join-Path $repository 'build/rollback-playtest/Development'
$helper = Join-Path $repository 'build/build-rollback-playtest.cmd'
New-Item -ItemType Directory -Force (Split-Path $helper -Parent) | Out-Null
@"
@call "$VsDevCmd" -arch=x64 -host_arch=x64 -vcvars_ver=$Toolset
@if errorlevel 1 exit /b %errorlevel%
@set "ROLLBACK_TOOLCHAIN=%VCToolsInstallDir:\=/%bin/Hostx64/x64/cl.exe"
@cmake --preset windows-msvc-x64 -DGDJ_CROSS_PLATFORM_DETERMINISTIC=ON -DCMAKE_C_COMPILER="%ROLLBACK_TOOLCHAIN%" -DCMAKE_CXX_COMPILER="%ROLLBACK_TOOLCHAIN%"
@if errorlevel 1 exit /b %errorlevel%
@cmake --build build/windows-msvc-x64 --config Development --parallel 8
@if errorlevel 1 exit /b %errorlevel%
@cmake --install build/windows-msvc-x64 --config Development --prefix "$output"
"@ | Set-Content -LiteralPath $helper
Push-Location $repository
try {
    & $helper
    if ($LASTEXITCODE -ne 0) { throw "Rollback runtime build failed: $LASTEXITCODE" }
    Write-Host "Optimized runtime addon: $output/addons/godot-jolt"
} finally { Pop-Location }
