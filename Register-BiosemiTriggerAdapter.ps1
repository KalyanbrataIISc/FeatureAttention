param(
    [switch]$Learn,
    [switch]$Resolve,
    [switch]$SelfTest,
    [string]$ConfigPath = '',
    [ValidateRange(1, 60)][int]$WaitSeconds = 15
)

$ErrorActionPreference = 'Stop'
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $env:LOCALAPPDATA 'FeatureAttention\BiosemiTriggerAdapter.json'
}
$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)

function Get-HardwareKey([string]$instanceId) {
    if ($instanceId -match '(?i)VID_([0-9A-F]{4})[^\\]*PID_([0-9A-F]{4})') {
        return ('VID_{0}&PID_{1}' -f $Matches[1].ToUpperInvariant(), $Matches[2].ToUpperInvariant())
    }
    return ''
}

function Get-SerialDevices {
    foreach ($item in @(Get-CimInstance Win32_PnPEntity)) {
        if ($item.ConfigManagerErrorCode -eq 0 -and
                $item.PNPDeviceID -match '^(USB|FTDIBUS)\\' -and
                $item.Name -match '\((COM[1-9][0-9]*)\)') {
            [pscustomobject]@{
                Port = $Matches[1].ToUpperInvariant()
                InstanceId = [string]$item.PNPDeviceID
                HardwareKey = Get-HardwareKey ([string]$item.PNPDeviceID)
                Name = [string]$item.Name
            }
        }
    }
}

function Find-RegisteredDevice($registration, $devices) {
    if (-not $registration.InstanceId -or $registration.InstanceId -notmatch '^(USB|FTDIBUS)\\') {
        throw 'Trigger adapter registration is invalid. Re-run -Learn.'
    }
    $exact = @($devices | Where-Object { $_.InstanceId -eq $registration.InstanceId })
    if ($exact.Count -eq 1) { return $exact[0] }
    if ($exact.Count -gt 1) { throw 'The registered trigger adapter appears more than once. Check Device Manager.' }
    # VID/PID identifies a model or USB chip, not the physical adapter.
    # Never substitute a different instance, even if it is the only similar device.
    throw 'The registered trigger adapter is absent or its Windows identity changed. Reconnect it to the original USB socket, or re-run -Learn before recording.'
}

function Wait-DeviceChange($baseline, [string]$direction) {
    $deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
    do {
        $current = @(Get-SerialDevices)
        if ($direction -eq 'removed') {
            $changed = @($baseline | Where-Object {
                $id = $_.InstanceId
                -not @($current | Where-Object { $_.InstanceId -eq $id }).Count
            })
        } else {
            $changed = @($current | Where-Object {
                $id = $_.InstanceId
                -not @($baseline | Where-Object { $_.InstanceId -eq $id }).Count
            })
        }
        if ($changed.Count -gt 0) {
            return [pscustomobject]@{ Devices = $current; Changed = $changed }
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    throw ('Windows did not report a USB COM device as {0} within {1} seconds. Check the trigger cable and Device Manager, then retry -Learn.' -f $direction, $WaitSeconds)
}

if ($SelfTest) {
    $known = [pscustomobject]@{ InstanceId = 'USB\VID_1234&PID_5678\TRIGGER' }
    $trigger = [pscustomobject]@{ Port = 'COM12'; InstanceId = $known.InstanceId }
    $other = [pscustomobject]@{ Port = 'COM8'; InstanceId = 'USB\VID_1234&PID_5678\CEDRUS' }
    if ((Find-RegisteredDevice $known @($other, $trigger)).Port -ne 'COM12') { throw 'COM renumber test failed.' }
    if ((Find-RegisteredDevice $known @($trigger)).Port -ne 'COM12') { throw 'Single adapter test failed.' }
    foreach ($case in @('missing', 'same-chip', 'duplicate', 'invalid')) {
        $rejected = $false
        try {
            switch ($case) {
                'missing' { $null = Find-RegisteredDevice $known @() }
                'same-chip' { $null = Find-RegisteredDevice $known @($other) }
                'duplicate' { $null = Find-RegisteredDevice $known @($trigger, $trigger) }
                'invalid' { $null = Find-RegisteredDevice ([pscustomobject]@{ InstanceId = 'COM8' }) @($other) }
            }
        } catch { $rejected = $true }
        if (-not $rejected) { throw ('Device rejection test failed: {0}' -f $case) }
    }
    if ((Get-HardwareKey 'FTDIBUS\VID_0403+PID_6001+ABC') -ne 'VID_0403&PID_6001') { throw 'FTDI parsing test failed.' }
    Write-Output 'PASS: COM renumbering, exact identity, missing adapter, same-chip impostor, duplicate identity, invalid registration, FTDI parsing.'
    return
}

if ($Learn -eq $Resolve) { throw 'Specify exactly one of -Learn or -Resolve.' }

if ($Learn) {
    $before = @(Get-SerialDevices)
    if ($before.Count -eq 0) { throw 'No working USB COM devices were found. Connect the trigger adapter and check its driver first.' }
    Write-Host 'Stop recording and the MATLAB bridge before registering the adapter.'
    Write-Host 'Unplug ONLY the USB adapter/cable that sends trigger markers from P to A.'
    $null = Read-Host 'Press Enter after unplugging it'
    $disconnected = Wait-DeviceChange $before 'removed'
    $removed = @($disconnected.Changed)
    if ($removed.Count -ne 1) { throw 'Several USB COM devices disappeared. Reconnect them and retry, unplugging only the trigger adapter.' }
    if ($removed[0].Name -match 'Cedrus') { throw 'That device is named Cedrus. Reconnect it and register the P-to-A trigger adapter instead.' }
    Write-Host ('Disconnected device: {0}' -f $removed[0].Name)
    $null = Read-Host 'Reconnect that SAME adapter, then press Enter'
    $connected = Wait-DeviceChange $disconnected.Devices 'added'
    $candidate = @($connected.Changed)
    if ($candidate.Count -ne 1) { throw 'Several USB COM devices appeared. Reconnect only the trigger adapter and retry -Learn.' }
    if ($candidate[0].InstanceId -ne $removed[0].InstanceId -and
            (-not $removed[0].HardwareKey -or $candidate[0].HardwareKey -ne $removed[0].HardwareKey)) {
        throw 'The reconnected device does not match the disconnected adapter. Retry with the same physical adapter.'
    }
    $record = [pscustomobject]@{
        Version = 2
        InstanceId = $candidate[0].InstanceId
        HardwareKey = $candidate[0].HardwareKey
        Name = $candidate[0].Name
    }
    $folder = Split-Path -Parent $ConfigPath
    if (-not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
    $temporaryPath = Join-Path $folder ([IO.Path]::GetRandomFileName())
    try {
        [IO.File]::WriteAllText($temporaryPath, ($record | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporaryPath -Destination $ConfigPath -Force
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath }
    }
    Write-Host ('Registered trigger adapter: {0} on {1}.' -f $record.Name, $candidate[0].Port)
    Write-Host 'COM number changes are automatic. If its Windows identity changes, re-run -Learn.'
    return
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw 'No trigger adapter is registered. Run Register-BiosemiTriggerAdapter.ps1 -Learn on P first.'
}
$registration = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$device = Find-RegisteredDevice $registration @(Get-SerialDevices)
Write-Output $device.Port