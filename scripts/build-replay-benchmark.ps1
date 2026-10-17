param(
    [ValidateSet('EditorDebug', 'EditorDevelopment', 'EditorDistribution')]
    [string]$Configuration = 'EditorDevelopment',
    [string]$VsDevCmd = 'C:/Program Files/Microsoft Visual Studio/2022/Community/Common7/Tools/VsDevCmd.bat',
    [string]$Toolset = '14.38'
)
$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
$output = Join-Path $repository "build/replay-benchmark-builds/$Configuration"
$helper = Join-Path $repository 'build/build-replay-benchmark.cmd'
New-Item -ItemType Directory -Force (Split-Path $helper -Parent) | Out-Null
@"
@call "$VsDevCmd" -arch=x64 -host_arch=x64 -vcvars_ver=$Toolset
@if errorlevel 1 exit /b %errorlevel%
@cmake --preset windows-msvc-x64 -DGDJ_CROSS_PLATFORM_DETERMINISTIC=ON
@if errorlevel 1 exit /b %errorlevel%
@cmake --build build/windows-msvc-x64 --config $Configuration --parallel 8
@if errorlevel 1 exit /b %errorlevel%
@cmake --install build/windows-msvc-x64 --config $Configuration --prefix "$output"
"@ | Set-Content -LiteralPath $helper
Push-Location $repository
try {
    & $helper
    if ($LASTEXITCODE -ne 0) { throw "Benchmark build failed: $LASTEXITCODE" }
    Write-Host "Benchmark addon: $output/addons/godot-jolt"
} finally {
    Pop-Location
}
