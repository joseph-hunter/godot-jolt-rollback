param(
    [Parameter(Mandatory = $true)]
    [string]$GodotPath
)

$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskGodot = (Resolve-Path -LiteralPath $GodotPath).Path
$taskLogDirectory = Join-Path $taskRoot 'build/rollback-boundary-tests'
New-Item -ItemType Directory -Path $taskLogDirectory -Force | Out-Null
$taskScenarios = @(
    'normal', 'sleep_wake', 'duplicate', 'inactive', 'destroyed_space', 'reentrant_request',
    'correction', 'callback_failure', 'invalid_return', 'explicit_failure',
    'owner_destroyed', 'configuration', 'unregister_failed'
)
foreach ($taskScenario in $taskScenarios) {
    $taskLogPath = Join-Path $taskLogDirectory "$taskScenario.log"
    & $taskGodot --headless --path (Join-Path $taskRoot 'examples') --quit-after 200 `
        'scenes/rollback_poc/boundary-test.tscn' -- "--scenario=$taskScenario" *> $taskLogPath
    $taskExitCode = $LASTEXITCODE
    $taskOutput = Get-Content -LiteralPath $taskLogPath -Raw
    if ($taskExitCode -ne 0 -or $taskOutput -notmatch "BOUNDARY TEST PASS \[$taskScenario\]" `
        -or $taskOutput -match 'SCRIPT ERROR|BOUNDARY TEST FAIL') {
        Write-Output $taskOutput
        throw "Boundary scenario '$taskScenario' failed (exit $taskExitCode)."
    }
    Write-Output ($taskOutput -split "`r?`n" | Where-Object { $_ -match 'BOUNDARY TEST PASS' })
}
Write-Output 'All 13 rollback boundary scenarios passed.'
