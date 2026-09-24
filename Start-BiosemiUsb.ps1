param(
    [string]$DeviceSerial = '',
    [int]$Port = 5010,
    [string]$AdbPath = ''
)

$ErrorActionPreference = 'Stop'
if ($Port -lt 1 -or $Port -gt 65535) { throw 'Port must be between 1 and 65535.' }
if (-not $AdbPath) {
    $command = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($command) { $AdbPath = $command.Source }
}
if (-not $AdbPath -and $env:ANDROID_HOME) {
    $candidate = Join-Path $env:ANDROID_HOME 'platform-tools\adb.exe'
    if (Test-Path -LiteralPath $candidate) { $AdbPath = $candidate }
}
if (-not $AdbPath) {
    $candidate = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    if (Test-Path -LiteralPath $candidate) { $AdbPath = $candidate }
}
if (-not $AdbPath -or -not (Test-Path -LiteralPath $AdbPath)) {
    throw 'adb.exe was not found. Install Android SDK Platform Tools or pass -AdbPath.'
}

Write-Host 'Connect the tablet by USB and approve the USB debugging prompt on it.'
Write-Host "Maintaining adb reverse tcp:$Port tcp:$Port. Press Ctrl+C to stop."
$lastNotice = ''
while ($true) {
    $lines = & $AdbPath devices 2>&1
    $devices = @($lines | ForEach-Object {
        if ($_ -match '^([^\s]+)\s+device(?:\s|$)') { $Matches[1] }
    } | Where-Object { $_ -notmatch '^emulator-' })
    $selected = ''
    if ($DeviceSerial) {
        if ($devices -contains $DeviceSerial) { $selected = $DeviceSerial }
    } elseif ($devices.Count -eq 1) {
        $selected = $devices[0]
    }
    if (-not $selected) {
        $notice = if ($devices.Count -gt 1) { 'Several tablets found; rerun with -DeviceSerial.' } else { 'Waiting for one authorized USB tablet.' }
        if ($notice -ne $lastNotice) { Write-Host $notice; $lastNotice = $notice }
        Start-Sleep -Seconds 2
        continue
    }

    $mapping = & $AdbPath -s $selected reverse --list 2>&1
    $expected = "tcp:$Port tcp:$Port"
    if (-not (@($mapping | Where-Object { $_ -like "*$expected*" }).Count)) {
        $result = & $AdbPath -s $selected reverse "tcp:$Port" "tcp:$Port" 2>&1
        if ($LASTEXITCODE -ne 0) {
            $notice = "ADB reverse failed for $selected`: $result"
            if ($notice -ne $lastNotice) { Write-Warning $notice; $lastNotice = $notice }
        } else {
            Write-Host "USB bridge ready for $selected on port $Port."
            $lastNotice = ''
        }
    }
    Start-Sleep -Seconds 2
}
