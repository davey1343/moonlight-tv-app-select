<#
  steam-games-to-ha.ps1
  Sends the games in your Steam library (installed Steam games + non-Steam games added to Steam,
  e.g. Xbox / Epic) to Home Assistant, for the Games page.

  Run once with -Install to add a scheduled task (at logon + every 3 hours).
  Run with no arguments to send the list now.
#>
param(
    [switch]$Install,
    [switch]$Uninstall
)

# ---------------- Settings ----------------
$WebhookUrl = 'http://192.168.1.133:8123/api/webhook/WEBHOOK_ID_HERE'
# Optional: free key from https://www.steamgriddb.com/profile/preferences/api for art that Steam doesn't have
$SteamGridDbKey = ''
# ------------------------------------------

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$CoverCache = Join-Path $ScriptDir 'cover-cache.json'
$LogFile = Join-Path $ScriptDir 'steam-games-to-ha.log'
$TaskName = 'Home Assistant - Steam games list'

function Log($msg) {
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $msg
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    Write-Host $line
}

if ($Install -or $Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    if ($Uninstall) { Write-Host "Removed scheduled task '$TaskName'"; return }
    $ps = (Get-Command powershell.exe).Source
    $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$($MyInvocation.MyCommand.Path)`""
    $logon = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $logon.Delay = 'PT1M'
    $repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Hours 3)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($logon, $repeat) -Settings $settings `
        -Description 'Sends the Steam game list to Home Assistant for the Games page' | Out-Null
    Write-Host "Installed scheduled task '$TaskName'. Sending the list now..."
}

# ---------- Steam locations ----------
$SteamPath = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction SilentlyContinue).SteamPath
if (-not $SteamPath) { $SteamPath = "${env:ProgramFiles(x86)}\Steam" }
$SteamPath = $SteamPath -replace '/', '\'
if (-not (Test-Path $SteamPath)) { Log "Steam not found at $SteamPath"; exit 1 }

# Library folders
$libraries = @($SteamPath)
$lfPath = Join-Path $SteamPath 'steamapps\libraryfolders.vdf'
if (Test-Path $lfPath) {
    $lf = Get-Content -Raw -Encoding UTF8 $lfPath
    foreach ($m in [regex]::Matches($lf, '"path"\s+"([^"]+)"')) {
        $libraries += ($m.Groups[1].Value -replace '\\\\', '\')
    }
}
$libraries = $libraries | Select-Object -Unique

# Steam user: the one used most recently
$userDir = Get-ChildItem (Join-Path $SteamPath 'userdata') -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^\d+$' -and $_.Name -ne '0' } |
    Sort-Object { (Get-Item (Join-Path $_.FullName 'config\localconfig.vdf') -ErrorAction SilentlyContinue).LastWriteTime } -Descending |
    Select-Object -First 1
$localConfig = ''
if ($userDir) {
    $lcPath = Join-Path $userDir.FullName 'config\localconfig.vdf'
    if (Test-Path $lcPath) { $localConfig = Get-Content -Raw -Encoding UTF8 $lcPath }
}

function Get-LastPlayed([string]$appid) {
    if (-not $localConfig) { return 0 }
    $m = [regex]::Match($localConfig, '"' + $appid + '"\s*\{(?:(?!"\d+"\s*\{)[\s\S])*?"LastPlayed"\s*"(\d+)"')
    if ($m.Success) { return [long]$m.Groups[1].Value }
    return 0
}

# ---------- Cover cache ----------
$covers = @{}
if (Test-Path $CoverCache) {
    try {
        (Get-Content -Raw -Encoding UTF8 $CoverCache | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $covers[$_.Name] = $_.Value }
    } catch { $covers = @{} }
}

function Normalize([string]$s) { return ($s.ToLowerInvariant() -replace '[^a-z0-9]', '') }

function Find-Cover([string]$name) {
    if ($covers.ContainsKey($name)) { return $covers[$name] }
    $result = $null
    try {
        $url = 'https://store.steampowered.com/api/storesearch/?term=' + [uri]::EscapeDataString($name) + '&l=english&cc=GB'
        $res = Invoke-RestMethod -Uri $url -TimeoutSec 10
        $want = Normalize $name
        foreach ($item in $res.items) {
            $got = Normalize $item.name
            if ($got -eq $want -or ($want.Length -ge 5 -and ($got.StartsWith($want) -or $want.StartsWith($got)))) {
                $result = "https://cdn.cloudflare.steamstatic.com/steam/apps/$($item.id)/library_600x900.jpg"
                break
            }
        }
    } catch { Log "Steam store search failed for '$name': $($_.Exception.Message)" }
    if (-not $result -and $SteamGridDbKey) {
        try {
            $h = @{ Authorization = "Bearer $SteamGridDbKey" }
            $s = Invoke-RestMethod -Headers $h -TimeoutSec 10 -Uri ('https://www.steamgriddb.com/api/v2/search/autocomplete/' + [uri]::EscapeDataString($name))
            if ($s.success -and $s.data.Count -gt 0) {
                $g = Invoke-RestMethod -Headers $h -TimeoutSec 10 -Uri "https://www.steamgriddb.com/api/v2/grids/game/$($s.data[0].id)?dimensions=600x900"
                if ($g.success -and $g.data.Count -gt 0) { $result = $g.data[0].url }
            }
        } catch { Log "SteamGridDB failed for '$name': $($_.Exception.Message)" }
    }
    # Cache misses too (as empty) so we don't search every run; delete cover-cache.json to retry
    $covers[$name] = if ($result) { $result } else { '' }
    return $covers[$name]
}

# ---------- Installed Steam games ----------
$skipNames = '^(Steamworks Common Redistributables|Steam Linux Runtime.*|Proton.*|Steamworks Shared|SteamVR Performance Test)$'
$games = New-Object System.Collections.Generic.List[object]
foreach ($lib in $libraries) {
    $apps = Join-Path $lib 'steamapps'
    if (-not (Test-Path $apps)) { continue }
    foreach ($acf in Get-ChildItem $apps -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue) {
        $t = Get-Content -Raw -Encoding UTF8 $acf.FullName
        $appid = [regex]::Match($t, '"appid"\s+"(\d+)"').Groups[1].Value
        $name = [regex]::Match($t, '"name"\s+"([^"]*)"').Groups[1].Value
        $flags = [int]([regex]::Match($t, '"StateFlags"\s+"(\d+)"').Groups[1].Value)
        $size = [double]([regex]::Match($t, '"SizeOnDisk"\s+"(\d+)"').Groups[1].Value)
        if (-not $appid -or -not $name -or $appid -eq '228980' -or $name -match $skipNames) { continue }
        if (($flags -band 4) -eq 0) { continue }   # not fully installed
        $games.Add([ordered]@{
            id = $appid
            name = $name
            src = 'steam'
            size_gb = [math]::Round($size / 1GB, 1)
            last_played = (Get-LastPlayed $appid)
            cover = "https://cdn.cloudflare.steamstatic.com/steam/apps/$appid/library_600x900.jpg"
            fallback = "https://cdn.cloudflare.steamstatic.com/steam/apps/$appid/header.jpg"
        })
    }
}

# ---------- Non-Steam games added to Steam (shortcuts.vdf, binary VDF) ----------
$script:pos = 0
function Read-CString([byte[]]$b) {
    $start = $script:pos
    while ($script:pos -lt $b.Length -and $b[$script:pos] -ne 0) { $script:pos++ }
    $s = [System.Text.Encoding]::UTF8.GetString($b, $start, $script:pos - $start)
    $script:pos++
    return $s
}
function Read-Map([byte[]]$b) {
    $m = @{}
    while ($script:pos -lt $b.Length) {
        $type = $b[$script:pos]; $script:pos++
        if ($type -eq 8) { break }
        $key = Read-CString $b
        switch ($type) {
            0 { $m[$key] = Read-Map $b }
            1 { $m[$key] = Read-CString $b }
            2 { $m[$key] = [BitConverter]::ToInt32($b, $script:pos); $script:pos += 4 }
            7 { $script:pos += 8 }
            default { throw "Unknown VDF type $type" }
        }
    }
    return $m
}

$crcTable = $null
function Get-Crc32([byte[]]$bytes) {
    if (-not $script:crcTable) {
        $script:crcTable = New-Object 'uint32[]' 256
        for ($i = 0; $i -lt 256; $i++) {
            [uint32]$c = $i
            for ($k = 0; $k -lt 8; $k++) { if ($c -band 1) { $c = [uint32]([uint32]3988292384 -bxor ($c -shr 1)) } else { $c = $c -shr 1 } }
            $script:crcTable[$i] = $c
        }
    }
    [uint32]$crc = [uint32]::MaxValue
    foreach ($x in $bytes) { $crc = [uint32]($script:crcTable[($crc -bxor $x) -band 0xFF] -bxor ($crc -shr 8)) }
    return [uint32]($crc -bxor [uint32]::MaxValue)
}

if ($userDir) {
    $scPath = Join-Path $userDir.FullName 'config\shortcuts.vdf'
    if (Test-Path $scPath) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($scPath)
            $script:pos = 0
            $root = Read-Map $bytes
            $list = $root['shortcuts']
            if ($list) {
                foreach ($entry in $list.Values) {
                    $name = $entry['AppName']
                    if (-not $name) { continue }
                    if ($entry.ContainsKey('appid')) {
                        $id32 = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]$entry['appid']), 0)
                    } else {
                        # Old shortcuts without an appid: Steam's legacy CRC-based id
                        $id32 = [uint32]((Get-Crc32 ([System.Text.Encoding]::UTF8.GetBytes([string]$entry['Exe'] + $name))) -bor [uint32]2147483648)
                    }
                    $gameId = (([uint64]$id32) -shl 32) -bor [uint64]33554432
                    $lp = 0; if ($entry.ContainsKey('LastPlayTime')) { $lp = [long]$entry['LastPlayTime'] }
                    $games.Add([ordered]@{
                        id = [string]$gameId
                        name = $name
                        src = 'shortcut'
                        size_gb = $null
                        last_played = $lp
                        cover = (Find-Cover $name)
                        fallback = ''
                    })
                }
            }
        } catch { Log "Couldn't read shortcuts.vdf: $($_.Exception.Message)" }
    }
}

# Save cover cache
try { $covers | ConvertTo-Json -Depth 3 | Set-Content -Encoding UTF8 $CoverCache } catch { }

# ---------- Send ----------
$sorted = $games | Sort-Object -Property @{ Expression = { $_.last_played }; Descending = $true }, @{ Expression = { $_.name } }
$payload = [ordered]@{
    host = $env:COMPUTERNAME
    updated = (Get-Date).ToString('o')
    games = @($sorted)
}
$json = $payload | ConvertTo-Json -Depth 5 -Compress
try {
    Invoke-RestMethod -Method Post -Uri $WebhookUrl -ContentType 'application/json; charset=utf-8' `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 20 | Out-Null
    Log "Sent $($games.Count) games to Home Assistant"
} catch {
    Log "Failed to send to Home Assistant: $($_.Exception.Message)"
    exit 1
}
