param(
    [string]$Godot = "D:\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe",
    [int]$TimeoutSeconds = 15,
    [int]$HostSceneDelayMs = 1500
)

$ErrorActionPreference = "Stop"
$Project = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$HostOut = Join-Path $Project ".smoke_host_out.txt"
$HostErr = Join-Path $Project ".smoke_host_err.txt"
$ClientOut = Join-Path $Project ".smoke_client_out.txt"
$ClientErr = Join-Path $Project ".smoke_client_err.txt"
$HostLog = Join-Path $Project ".smoke_host_godot.log"
$ClientLog = Join-Path $Project ".smoke_client_godot.log"
$Artifacts = @($HostOut, $HostErr, $ClientOut, $ClientErr, $HostLog, $ClientLog)

foreach ($Path in $Artifacts) {
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

$HostArgs = @("--headless", "--path", $Project, "--log-file", $HostLog, "--", "--net-test=host", "--net-test-host-scene-delay-ms=$HostSceneDelayMs")
$ClientArgs = @("--headless", "--path", $Project, "--log-file", $ClientLog, "--", "--net-test=client")

$HostProcess = $null
$ClientProcess = $null
$TimedOut = $false
try {
    $HostProcess = Start-Process -FilePath $Godot -ArgumentList $HostArgs -RedirectStandardOutput $HostOut -RedirectStandardError $HostErr -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 700
    $ClientProcess = Start-Process -FilePath $Godot -ArgumentList $ClientArgs -RedirectStandardOutput $ClientOut -RedirectStandardError $ClientErr -PassThru -WindowStyle Hidden

    $Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ((-not $HostProcess.HasExited -or -not $ClientProcess.HasExited) -and [DateTime]::UtcNow -lt $Deadline) {
        Start-Sleep -Milliseconds 100
        $HostProcess.Refresh()
        $ClientProcess.Refresh()
    }
    $TimedOut = -not $HostProcess.HasExited -or -not $ClientProcess.HasExited
}
finally {
    foreach ($Process in @($HostProcess, $ClientProcess)) {
        if ($null -ne $Process) {
            if (-not $Process.HasExited) {
                Stop-Process -Id $Process.Id -Force
            }
            $Process.WaitForExit()
        }
    }
}

$HostText = if (Test-Path -LiteralPath $HostOut) { Get-Content -LiteralPath $HostOut -Raw -Encoding UTF8 } else { "" }
$ClientText = if (Test-Path -LiteralPath $ClientOut) { Get-Content -LiteralPath $ClientOut -Raw -Encoding UTF8 } else { "" }
$HostErrorText = if (Test-Path -LiteralPath $HostErr) { Get-Content -LiteralPath $HostErr -Raw -Encoding UTF8 } else { "" }
$ClientErrorText = if (Test-Path -LiteralPath $ClientErr) { Get-Content -LiteralPath $ClientErr -Raw -Encoding UTF8 } else { "" }

Write-Host "--- HOST STDOUT ---"
Write-Host $HostText
Write-Host "--- HOST STDERR ---"
Write-Host $HostErrorText
Write-Host "--- CLIENT STDOUT ---"
Write-Host $ClientText
Write-Host "--- CLIENT STDERR ---"
Write-Host $ClientErrorText

Write-Host "Timed out: $TimedOut"
$RaceCovered = $HostSceneDelayMs -le 0 -or ($HostText.Contains("[Net] TEST_SCENE_DELAY") -and $ClientText.Contains("GAME_READY sent attempt=2"))
Write-Host "Scene-ready race covered: $RaceCovered"
$Passed = -not $TimedOut -and $RaceCovered -and $HostText.Contains("[AUTO] host PASS") -and $ClientText.Contains("[AUTO] client PASS")
if (-not $Passed) {
    throw "net_proto two-process smoke test failed or timed out; inspect .smoke_* files."
}
Write-Host "net_proto two-process smoke test PASS"
