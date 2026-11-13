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
# Optional: Steam Web API key from https://steamcommunity.com/dev/apikey - adds games you own but haven't installed
$SteamApiKey = ''
# Other stores (installed + owned where the store keeps a local list)
$IncludeEpic = $true
$IncludeXbox = $true
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
# Same folder can appear with different case/slashes (registry vs libraryfolders.vdf)
$seenLib = @{}
$libraries = foreach ($l in $libraries) {
    $key = ($l -replace '/', '\').TrimEnd('\').ToLowerInvariant()
    if (-not $seenLib.ContainsKey($key)) { $seenLib[$key] = $true; $l }
}

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
$seenIds = @{}
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
        if ($seenIds.ContainsKey($appid)) { continue }
        $seenIds[$appid] = $true
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


# ---------- Mark everything so far as installed, launched through Steam ----------
foreach ($g in $games) {
    $g['installed'] = $true
    $g['store'] = 'steam'
    $g['launch'] = "steam://rungameid/$($g['id'])"
    $g['install'] = ''
}

function Add-OrMerge($entry) {
    # One entry per game: an installed copy (e.g. a Steam shortcut to an Epic game) wins over an uninstalled one
    $key = Normalize $entry['name']
    if (-not $key) { return }
    $existing = $null
    foreach ($g in $games) { if ((Normalize $g['name']) -eq $key) { $existing = $g; break } }
    if ($null -eq $existing) { $games.Add($entry); return }
    if (-not $existing['installed'] -and $entry['installed']) {
        $games.Remove($existing) | Out-Null; $games.Add($entry); return
    }
    # Keep the existing (installed / Steam) entry, but borrow better art or the store name
    if (-not $existing['cover'] -and $entry['cover']) { $existing['cover'] = $entry['cover'] }
    if ($existing['src'] -eq 'shortcut' -and $entry['store'] -ne 'steam') { $existing['store'] = $entry['store'] }
}

# ---------- Steam: owned but not installed (needs $SteamApiKey) ----------
if ($SteamApiKey -and $userDir) {
    try {
        $steamId64 = [decimal]76561197960265728 + [decimal]$userDir.Name
        $url = "https://api.steampowered.com/IPlayerService/GetOwnedGames/v1/?key=$SteamApiKey&steamid=$steamId64&include_appinfo=1&include_played_free_games=1"
        $owned = (Invoke-RestMethod -Uri $url -TimeoutSec 20).response.games
        $installedIds = @{}; foreach ($g in $games) { if ($g['src'] -eq 'steam') { $installedIds[[string]$g['id']] = $g } }
        foreach ($o in $owned) {
            $aid = [string]$o.appid
            if ($installedIds.ContainsKey($aid)) {
                if (-not $installedIds[$aid]['last_played'] -and $o.rtime_last_played) { $installedIds[$aid]['last_played'] = [long]$o.rtime_last_played }
                continue
            }
            if ($o.name -match $skipNames) { continue }
            Add-OrMerge ([ordered]@{
                id = $aid; name = $o.name; src = 'steam'; store = 'steam'; installed = $false
                size_gb = $null; last_played = [long]$o.rtime_last_played
                cover = "https://cdn.cloudflare.steamstatic.com/steam/apps/$aid/library_600x900.jpg"
                fallback = "https://cdn.cloudflare.steamstatic.com/steam/apps/$aid/header.jpg"
                launch = "steam://rungameid/$aid"; install = "steam://install/$aid"
            })
        }
        Log "Steam owned games: $(@($owned).Count)"
    } catch { Log "Steam owned games failed: $($_.Exception.Message)" }
}

# ---------- Epic Games: installed (manifests) + owned (launcher catalogue cache) ----------
if ($IncludeEpic) {
    $epicData = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data'
    $epicInstalled = @{}
    try {
        foreach ($f in Get-ChildItem (Join-Path $epicData 'Manifests') -Filter '*.item' -ErrorAction SilentlyContinue) {
            $m = Get-Content -Raw -Encoding UTF8 $f.FullName | ConvertFrom-Json
            if ($m.bIsIncompleteInstall -or -not $m.DisplayName) { continue }
            if (@($m.AppCategories) -contains 'addons' -or @($m.AppCategories) -notcontains 'games') { continue }
            $epicInstalled["$($m.CatalogNamespace):$($m.CatalogItemId)"] = $true
            $uri = "com.epicgames.launcher://apps/$($m.CatalogNamespace)%3A$($m.CatalogItemId)%3A$($m.AppName)"
            Add-OrMerge ([ordered]@{
                id = "epic:$($m.AppName)"; name = $m.DisplayName; src = 'epic'; store = 'epic'; installed = $true
                size_gb = [math]::Round([double]$m.InstallSize / 1GB, 1); last_played = 0
                cover = ''; fallback = ''; launch = "$uri`?action=launch&silent=true"; install = ''
                _ns = $m.CatalogNamespace; _cid = $m.CatalogItemId
            })
        }
    } catch { Log "Epic manifests failed: $($_.Exception.Message)" }
    try {
        $cat = Join-Path $epicData 'Catalog\catcache.bin'
        if (Test-Path $cat) {
            $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((Get-Content -Raw $cat).Trim()))
            $items = $json | ConvertFrom-Json
            $epicCovers = @{}
            $n = 0
            foreach ($it in $items) {
                $paths = @($it.categories | ForEach-Object { $_.path })
                $art = $null
                foreach ($t in 'DieselGameBoxTall', 'OfferImageTall', 'DieselGameBox', 'Thumbnail') {
                    $art = ($it.keyImages | Where-Object { $_.type -eq $t } | Select-Object -First 1).url
                    if ($art) { break }
                }
                $epicCovers["$($it.namespace):$($it.id)"] = $art
                if ($paths -notcontains 'games' -or $paths -contains 'addons' -or $paths -contains 'digitalextras' -or $paths -contains 'applications') { continue }
                if ($it.mainGameItem) { continue }   # DLC / editions point at a main game
                $appName = (@($it.releaseInfo) | Where-Object { @($_.platform) -contains 'Windows' } | Select-Object -First 1).appId
                if (-not $appName) { continue }
                if ($epicInstalled.ContainsKey("$($it.namespace):$($it.id)")) { continue }
                $n++
                Add-OrMerge ([ordered]@{
                    id = "epic:$appName"; name = $it.title; src = 'epic'; store = 'epic'; installed = $false
                    size_gb = $null; last_played = 0; cover = $art; fallback = ''
                    launch = "com.epicgames.launcher://apps/$($it.namespace)%3A$($it.id)%3A$appName`?action=launch&silent=true"
                    install = "com.epicgames.launcher://apps/$($it.namespace)%3A$($it.id)%3A$appName`?action=install"
                })
            }
            # Art for installed Epic games
            foreach ($g in $games) {
                if ($g['_ns'] -and -not $g['cover']) { $g['cover'] = $epicCovers["$($g['_ns']):$($g['_cid'])"] }
            }
            Log "Epic library: $n not installed, $($epicInstalled.Count) installed"
        }
    } catch { Log "Epic catalogue failed: $($_.Exception.Message)" }
    foreach ($g in $games) { if ($g.Contains('_ns')) { $g.Remove('_ns'); $g.Remove('_cid') } }
}

# ---------- Xbox app (PC Game Pass / Microsoft Store) installed games ----------
if ($IncludeXbox) {
    try {
        $xcount = 0
        foreach ($drive in Get-PSDrive -PSProvider FileSystem) {
            $root = $drive.Root
            $folder = 'XboxGames'
            $gr = Join-Path $root '.GamingRoot'
            if (Test-Path $gr) {
                # .GamingRoot: 'RGBX' header + UTF-16 folder name
                $b = [System.IO.File]::ReadAllBytes($gr)
                if ($b.Length -gt 8) { $f = [System.Text.Encoding]::Unicode.GetString($b, 8, $b.Length - 8).Trim([char]0); if ($f) { $folder = $f } }
            }
            $xdir = Join-Path $root $folder
            if (-not (Test-Path $xdir)) { continue }
            foreach ($gdir in Get-ChildItem $xdir -Directory -ErrorAction SilentlyContinue) {
                $cfg = Join-Path $gdir.FullName 'Content\MicrosoftGame.config'
                if (-not (Test-Path $cfg)) { continue }
                [xml]$x = Get-Content -Raw -Encoding UTF8 $cfg
                $g = $x.Game
                $idName = $g.Identity.Name
                $display = $g.ShellVisuals.DefaultDisplayName
                if (-not $display -or $display -match '^ms-resource') { $display = $gdir.Name }
                $appId = @($g.ExecutableList.Executable)[0].Id
                $pkg = Get-AppxPackage -Name $idName -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not $pkg -or -not $appId) { continue }
                $storeId = $g.StoreId
                $art = ''
                if ($storeId) {
                    $ck = "xbox:$storeId"
                    if ($covers.ContainsKey($ck)) { $art = $covers[$ck] } else {
                        try {
                            $p = (Invoke-RestMethod -TimeoutSec 10 -Uri "https://displaycatalog.mp.microsoft.com/v7.0/products?bigIds=$storeId&market=GB&languages=en-GB").Products[0]
                            $imgs = $p.LocalizedProperties[0].Images
                            $img = ($imgs | Where-Object { $_.ImagePurpose -eq 'Poster' } | Select-Object -First 1)
                            if (-not $img) { $img = ($imgs | Where-Object { $_.ImagePurpose -eq 'BoxArt' } | Select-Object -First 1) }
                            if ($img) { $art = 'https:' + $img.Uri }
                        } catch { }
                        $covers[$ck] = $art
                    }
                }
                if (-not $art) { $art = Find-Cover $display }
                $xcount++
                Add-OrMerge ([ordered]@{
                    id = "xbox:$($pkg.PackageFamilyName)"; name = $display; src = 'xbox'; store = 'xbox'; installed = $true
                    size_gb = $null; last_played = 0; cover = $art; fallback = ''
                    launch = "shell:AppsFolder\$($pkg.PackageFamilyName)!$appId"; install = ''
                })
            }
        }
        Log "Xbox installed games: $xcount"
    } catch { Log "Xbox games failed: $($_.Exception.Message)" }
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
