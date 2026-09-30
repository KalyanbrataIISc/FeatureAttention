param([string]$ResolverPath = '')
$ErrorActionPreference = 'Stop'
if (-not $ResolverPath) { $ResolverPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Register-BiosemiTriggerAdapter.ps1' }
$fixtureDir = Join-Path ([IO.Path]::GetTempPath()) ('biosemi-tests-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $fixtureDir
$config = Join-Path $fixtureDir 'adapter.json'
$testState = @{ Inventory = @(); Queue = $null; Failure = $false; Calls = 0 }
$passed = 0

# Override only Windows inventory and the two human prompts. Exercise the actual
# production script, including filtering, registration, JSON and output contract.
function Get-CimInstance {
    param([string]$ClassName)
    $testState.Calls++
    if ($testState.Failure) { throw 'Inventory access failed' }
    if ($testState.Queue.Count -gt 0) { $testState.Inventory = $testState.Queue.Dequeue() }
    return $testState.Inventory
}
function Read-Host { param([string]$Prompt) return '' }
function Set-Inventory($snapshots) {
    $testState.Queue = New-Object 'System.Collections.Generic.Queue[object]'
    foreach ($snapshot in $snapshots) { $testState.Queue.Enqueue($snapshot) }
    $testState.Inventory = @()
    $testState.Failure = $false
    $testState.Calls = 0
}
function Make-Device([string]$id, [string]$port, [int]$code = 0, [string]$name = 'USB Serial Port') {
    return [pscustomobject]@{ Name = "$name ($port)"; PNPDeviceID = $id; ConfigManagerErrorCode = $code }
}
function Assert-Equal($actual, $expected, [string]$label) {
    if ($actual -ne $expected) { throw "$label failed: expected '$expected', got '$actual'." }
    $script:passed++
}
function Expect-Failure([scriptblock]$action, [string]$pattern, [string]$label) {
    $message = ''
    try { $null = & $action } catch { $message = $_.Exception.Message }
    if (-not $message -or $message -notmatch $pattern) { throw "$label failed: unexpected result '$message'." }
    $script:passed++
}
try {
    $triggerId = 'USB\VID_0403&PID_6001\TRIGGER'
    $cedrusId = 'USB\VID_0403&PID_6001\RESPONSE_BOX'
    $trigger = Make-Device $triggerId 'COM9'
    $cedrus = Make-Device $cedrusId 'COM8'
    $bluetooth = Make-Device 'BTHENUM\BLUETOOTH' 'COM4' 0 'Bluetooth Serial'
    $gone = Make-Device $triggerId 'COM9' 45
    $renamed = Make-Device $triggerId 'COM12'
    Set-Inventory @(@($trigger, $cedrus, $bluetooth), @($gone, $cedrus, $bluetooth), @($gone, $cedrus), @($renamed, $cedrus))
    & $ResolverPath -Learn -ConfigPath $config -WaitSeconds 2
    $saved = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json
    Assert-Equal $saved.InstanceId $triggerId 'Learn selected the physically unplugged adapter'
    Assert-Equal ($testState.Calls -ge 4) $true 'Delayed Windows enumeration was retried'

    $renamed = Make-Device $triggerId 'COM27'
    Set-Inventory (,@($renamed, $cedrus, $bluetooth))
    $output = @(& $ResolverPath -Resolve -ConfigPath $config)
    Assert-Equal $output.Count 1 'Resolve emits exactly one stdout line'
    Assert-Equal $output[0] 'COM27' 'COM renumbering with same-chip response box present'

    Set-Inventory (,@($cedrus))
    Expect-Failure { & $ResolverPath -Resolve -ConfigPath $config } 'absent' 'Missing trigger never selects same-chip response box'
    Set-Inventory (,@((Make-Device $triggerId 'COM27' 22), $cedrus))
    Expect-Failure { & $ResolverPath -Resolve -ConfigPath $config } 'absent' 'Disabled trigger is excluded'
    Set-Inventory (,@($bluetooth))
    Expect-Failure { & $ResolverPath -Resolve -ConfigPath $config } 'absent' 'Bluetooth port is excluded'
    Set-Inventory (,@($renamed, $renamed))
    Expect-Failure { & $ResolverPath -Resolve -ConfigPath $config } 'more than once' 'Duplicate identity is rejected'

    $original = [IO.File]::ReadAllText($config)
    Set-Inventory @(@($trigger, $cedrus), @())
    Expect-Failure { & $ResolverPath -Learn -ConfigPath $config -WaitSeconds 1 } 'Several USB COM devices disappeared' 'Multiple unplugged devices are rejected'
    Assert-Equal ([IO.File]::ReadAllText($config)) $original 'Failed registration preserves previous identity'

    $wrong = Make-Device 'USB\VID_1234&PID_9876\OTHER' 'COM14'
    Set-Inventory @(@($trigger, $cedrus), @($cedrus), @($wrong, $cedrus))
    Expect-Failure { & $ResolverPath -Learn -ConfigPath $config -WaitSeconds 1 } 'does not match' 'Different reconnected model is rejected'
    Assert-Equal ([IO.File]::ReadAllText($config)) $original 'Wrong reconnect preserves previous identity'

    $namedCedrus = Make-Device $cedrusId 'COM8' 0 'Cedrus Response Box'
    Set-Inventory @(@($trigger, $namedCedrus), @($trigger))
    Expect-Failure { & $ResolverPath -Learn -ConfigPath $config -WaitSeconds 1 } 'named Cedrus' 'Known Cedrus registration is rejected'

    $movedId = 'USB\VID_0403&PID_6001\NEW_SOCKET'
    $moved = Make-Device $movedId 'COM31'
    Set-Inventory @(@($trigger, $cedrus), @($cedrus), @($moved, $cedrus))
    & $ResolverPath -Learn -ConfigPath $config -WaitSeconds 1
    Assert-Equal ((Get-Content -LiteralPath $config -Raw | ConvertFrom-Json).InstanceId) $movedId 'Explicit learning accepts the same model in a new USB socket'
    Set-Inventory (,@($trigger, $cedrus))
    Expect-Failure { & $ResolverPath -Resolve -ConfigPath $config } 'absent' 'Changed identity requires explicit registration'

    $ftdiId = 'FTDIBUS\VID_0403+PID_6001+TRIGGER\0000'
    [IO.File]::WriteAllText($config, (@{ InstanceId = $ftdiId } | ConvertTo-Json))
    Set-Inventory (,@((Make-Device $ftdiId 'COM42'), $cedrus))
    Assert-Equal (& $ResolverPath -Resolve -ConfigPath $config) 'COM42' 'FTDI port identity is supported'

    $testState.Failure = $true
    Expect-Failure { & $ResolverPath -Resolve -ConfigPath $config } 'Inventory access failed' 'Inventory failure is reported'
    $testState.Failure = $false
    [IO.File]::WriteAllText($config, '{broken json')
    Expect-Failure { & $ResolverPath -Resolve -ConfigPath $config } 'JSON|object|invalid' 'Corrupt registration is rejected'
    [IO.File]::WriteAllText($config, '{"InstanceId":"COM8"}')
    Expect-Failure { & $ResolverPath -Resolve -ConfigPath $config } 'registration is invalid' 'Bare COM number is not a device identity'
    Remove-Item -LiteralPath $config
    Expect-Failure { & $ResolverPath -Resolve -ConfigPath $config } 'No trigger adapter is registered' 'First run requires registration'
    Expect-Failure { & $ResolverPath -Learn -Resolve -ConfigPath $config } 'exactly one' 'Conflicting modes are rejected'
    Write-Output "PASS: $passed production-script assertions. No serial port was opened and no trigger was sent."
} finally {
    Get-ChildItem -LiteralPath $fixtureDir -File | ForEach-Object { Remove-Item -LiteralPath $_.FullName }
    Remove-Item -LiteralPath $fixtureDir
}