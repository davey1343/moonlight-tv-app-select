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
# PC Game Pass catalogue (shown greyed out, install via the Xbox app)
$IncludeGamePass = $true
$MaxLookupsPerRun = 250      # new Game Pass detail lookups per run; the rest fill in on later runs
# Folders where Epic installs games (the new Epic launcher keeps no manifests in ProgramData)
$EpicInstallFolders = @("$env:USERPROFILE\Epic Games", "$env:ProgramFiles\Epic Games")
# Vibepollo: add every installed game as its own app, so Moonlight can start it directly.
# Create a token in the Vibepollo web page (API Tokens) with these scopes, then paste it below:
#   /api/apps  GET, POST      /api/apps/delete  POST
$VibepolloUrl = 'https://localhost:47990'
$VibepolloToken = ''
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

$script:gameIndex = $null
function NormKey([string]$s) {
    $k = Normalize $s
    foreach ($suffix in 'standardedition', 'pcedition', 'windowsedition', 'forwindows', 'windows10', 'pc', 'gamepreview') {
        if ($k.Length -gt $suffix.Length + 3 -and $k.EndsWith($suffix)) { $k = $k.Substring(0, $k.Length - $suffix.Length) }
    }
    return $k
}

function Add-OrMerge($entry) {
    # One entry per game: an installed copy (e.g. a Steam shortcut to an Epic game) wins over an uninstalled one
    $key = NormKey $entry['name']
    if (-not $key) { return }
    if ($null -eq $script:gameIndex) {
        $script:gameIndex = @{}
        foreach ($g in $games) { $k = NormKey $g['name']; if ($k -and -not $script:gameIndex.ContainsKey($k)) { $script:gameIndex[$k] = $g } }
    }
    $existing = $script:gameIndex[$key]
    if ($null -eq $existing) { $games.Add($entry); $script:gameIndex[$key] = $entry; return }
    if (-not $existing['installed'] -and $entry['installed']) {
        foreach ($f in 'gamepass') { if ($existing[$f] -and -not $entry[$f]) { $entry[$f] = $existing[$f] } }
        if (-not $entry['cover'] -and $existing['cover']) { $entry['cover'] = $existing['cover'] }
        $games.Remove($existing) | Out-Null; $games.Add($entry); $script:gameIndex[$key] = $entry; return
    }
    # Keep the existing (installed / Steam) entry, but borrow better art or the store name
    if (-not $existing['cover'] -and $entry['cover']) { $existing['cover'] = $entry['cover'] }
    if ($entry['gamepass']) { $existing['gamepass'] = $true; if (-not $existing['install'] -and -not $existing['installed']) { $existing['install'] = $entry['install'] } }
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
    # New launcher: find installed games by their .egstore\*.mancpn marker in the install folders
    try {
        foreach ($root in $EpicInstallFolders) {
            if (-not (Test-Path $root)) { continue }
            foreach ($gdir in Get-ChildItem $root -Directory -ErrorAction SilentlyContinue) {
                $eg = Join-Path $gdir.FullName '.egstore'
                if (-not (Test-Path $eg)) { continue }
                # Look for a small JSON file naming the game (old launcher: *.mancpn); otherwise use the folder name
                $mc = $null
                foreach ($f in Get-ChildItem $eg -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Length -lt 65536 }) {
                    try {
                        $j = Get-Content -Raw -Encoding UTF8 $f.FullName | ConvertFrom-Json -ErrorAction Stop
                        if ($j.AppName) { $mc = $j; break }
                    } catch { }
                }
                if ($mc -and $mc.CatalogNamespace -and $mc.CatalogItemId) {
                    $key = "$($mc.CatalogNamespace):$($mc.CatalogItemId)"
                    $uri = "com.epicgames.launcher://apps/$($mc.CatalogNamespace)%3A$($mc.CatalogItemId)%3A$($mc.AppName)"
                } else {
                    $appName = if ($mc -and $mc.AppName) { $mc.AppName } else { $gdir.Name }
                    $key = "app:$appName"
                    $uri = "com.epicgames.launcher://apps/$appName"
                    $mc = [pscustomobject]@{ AppName = $appName; CatalogNamespace = ''; CatalogItemId = '' }
                }
                if ($epicInstalled.ContainsKey($key)) { continue }
                $epicInstalled[$key] = $true
                $size = 0
                try { $size = (Get-ChildItem $gdir.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum } catch { }
                Add-OrMerge ([ordered]@{
                    id = "epic:$($mc.AppName)"; name = $gdir.Name; src = 'epic'; store = 'epic'; installed = $true
                    size_gb = [math]::Round([double]$size / 1GB, 1); last_played = 0
                    cover = (Find-Cover $gdir.Name); fallback = ''; launch = "$uri`?action=launch&silent=true"; install = ''
                    _ns = $mc.CatalogNamespace; _cid = $mc.CatalogItemId
                })
            }
        }
        Log "Epic installed games found: $($epicInstalled.Count)"
    } catch { Log "Epic install folders failed: $($_.Exception.Message)" }
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
    # New Epic launcher (eglv2): owned library, catalogue art and installed sizes in %LOCALAPPDATA%\com.epicgames.eglv2\cache
    try {
        $egl = Join-Path $env:LOCALAPPDATA 'com.epicgames.eglv2\cache'
        $libFile = Get-ChildItem (Join-Path $egl 'prod\account') -Recurse -Filter 'library-cache.json' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $catFile = Join-Path $egl 'prod\catalog-cache.json'
        if ($libFile -and (Test-Path $catFile)) {
            $lib = (Get-Content -Raw -Encoding UTF8 $libFile.FullName | ConvertFrom-Json).items
            $catItems = (Get-Content -Raw -Encoding UTF8 $catFile | ConvertFrom-Json).items
            $installedApps = @{}
            $ds = Join-Path $egl 'disk-size-cache.json'
            if (Test-Path $ds) {
                foreach ($e in (Get-Content -Raw -Encoding UTF8 $ds | ConvertFrom-Json).entries) { $installedApps[$e.app_id.appName] = [double]$e.bytes }
            }
            $owned = 0; $inst = 0
            foreach ($it in $lib) {
                if ($it.owned -eq $false) { continue }
                $a = $it.appId
                $prop = $catItems.PSObject.Properties[$a.itemId]
                if (-not $prop) { continue }
                $c = $prop.Value.item
                $paths = @($c.categories | ForEach-Object { $_.path })
                if ($c.mainGameItem -or $paths -notcontains 'games' -or $paths -contains 'addons' -or $paths -contains 'digitalextras') { continue }
                $art = $null
                foreach ($t in 'DieselGameBoxTall', 'OfferImageTall', 'DieselGameBox', 'Thumbnail') {
                    $art = (@($c.keyImages) | Where-Object { $_.type -eq $t } | Select-Object -First 1).url
                    if ($art) { break }
                }
                $isInst = $installedApps.ContainsKey($a.appName) -or $epicInstalled.ContainsKey("$($a.namespaceId):$($a.itemId)") -or $epicInstalled.ContainsKey("app:$($a.appName)")
                $uri = "com.epicgames.launcher://apps/$($a.namespaceId)%3A$($a.itemId)%3A$($a.appName)"
                $size = $null; if ($installedApps.ContainsKey($a.appName)) { $size = [math]::Round($installedApps[$a.appName] / 1GB, 1) }
                if ($isInst) { $inst++ } else { $owned++ }
                Add-OrMerge ([ordered]@{
                    id = "epic:$($a.appName)"; name = $it.title; src = 'epic'; store = 'epic'; installed = [bool]$isInst
                    size_gb = $size; last_played = 0; cover = $art; fallback = ''
                    launch = "$uri`?action=launch&silent=true"; install = $(if ($isInst) { '' } else { "$uri`?action=install" })
                })
            }
            Log "Epic (new launcher): $inst installed, $owned owned not installed"
        }
    } catch { Log "Epic new launcher failed: $($_.Exception.Message)" }
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

# ---------- PC Game Pass catalogue ----------
$script:lookups = 0
function Can-Lookup { return $script:lookups -lt $MaxLookupsPerRun }
if ($IncludeGamePass) {
    try {
        $sigl = Invoke-RestMethod -TimeoutSec 20 -Uri 'https://catalog.gamepass.com/sigls/v2?id=fdd9e2a7-0fee-49f6-ad69-4354098401ff&language=en-gb&market=GB'
        $ids = @($sigl | Where-Object { $_.id } | ForEach-Object { $_.id })
        $need = @($ids | Where-Object { -not $covers.ContainsKey("gp:$_") })
        for ($i = 0; $i -lt $need.Count -and (Can-Lookup); $i += 20) {
            $batch = $need[$i..([math]::Min($i + 19, $need.Count - 1))]
            $script:lookups++
            try {
                $res = Invoke-RestMethod -TimeoutSec 20 -Uri ("https://displaycatalog.mp.microsoft.com/v7.0/products?bigIds=" + ($batch -join ',') + "&market=GB&languages=en-GB")
                foreach ($pr in $res.Products) {
                    $lp = $pr.LocalizedProperties[0]
                    $img = ($lp.Images | Where-Object { $_.ImagePurpose -eq 'Poster' } | Select-Object -First 1)
                    if (-not $img) { $img = ($lp.Images | Where-Object { $_.ImagePurpose -eq 'BoxArt' } | Select-Object -First 1) }
                    $art = if ($img) { 'https:' + $img.Uri } else { '' }
                    $covers["gp:$($pr.ProductId)"] = "$($lp.ProductTitle)|$art"
                }
            } catch { Log "Game Pass details failed: $($_.Exception.Message)" }
        }
        $gpCount = 0
        foreach ($id in $ids) {
            $v = $covers["gp:$id"]
            if (-not $v) { continue }
            $parts = $v -split '\|'
            if (-not $parts[0]) { continue }
            $gpCount++
            Add-OrMerge ([ordered]@{
                id = "gp:$id"; name = $parts[0]; src = 'gamepass'; store = 'xbox'; installed = $false; gamepass = $true
                size_gb = $null; last_played = 0; cover = $parts[1]; fallback = ''
                launch = "msxbox://game/?productId=$id"; install = "msxbox://game/?productId=$id"
            })
        }
        Log "Game Pass catalogue: $($ids.Count) games, $gpCount with details"
    } catch { Log "Game Pass failed: $($_.Exception.Message)" }
}


# ---------- Vibepollo: one app per installed game ----------
# Apps this script manages have IDs starting 'bea57000-'; anything you added yourself is left alone.
function Get-VpUuid([string]$key) {
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $h = -join ($md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("beast:$key")) | ForEach-Object { $_.ToString('x2') })
    return 'bea57000-{0}-4{1}-8{2}-{3}' -f $h.Substring(0, 4), $h.Substring(4, 3), $h.Substring(7, 3), $h.Substring(10, 12)
}
function Get-VpCover($g, [string]$uuid) {
    $dir = Join-Path $ScriptDir 'vibepollo-covers'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $png = Join-Path $dir "$uuid.png"
    if (Test-Path $png) { return $png }
    foreach ($url in @($g['cover'], $g['fallback'])) {
        if (-not $url) { continue }
        $tmp = Join-Path $env:TEMP "vp-cover-$uuid.img"
        try {
            Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 15
            Add-Type -AssemblyName System.Drawing
            $img = [System.Drawing.Image]::FromFile($tmp)
            try { $img.Save($png, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $img.Dispose() }
            Remove-Item $tmp -ErrorAction SilentlyContinue
            return $png
        } catch { Remove-Item $tmp -ErrorAction SilentlyContinue }
    }
    return ''
}

if ($VibepolloToken) {
    $oldPolicy = [Net.ServicePointManager]::CertificatePolicy
    try {
        # Vibepollo uses a self-signed certificate; only trusted for these localhost calls
        if (-not ('VpTrustAll' -as [type])) {
            Add-Type @"
using System.Net; using System.Security.Cryptography.X509Certificates;
public class VpTrustAll : ICertificatePolicy { public bool CheckValidationResult(ServicePoint sp, X509Certificate c, WebRequest r, int p) { return true; } }
"@
        }
        [Net.ServicePointManager]::CertificatePolicy = New-Object VpTrustAll
        $vpHeaders = @{ Authorization = "Bearer $VibepolloToken" }
        $existing = @{}
        $resp = Invoke-RestMethod -Uri "$VibepolloUrl/api/apps" -Headers $vpHeaders -TimeoutSec 15
        foreach ($a in @($resp.apps)) { if ($a.uuid) { $existing[[string]$a.uuid] = $a } }

        $wanted = @{}; $added = 0; $updated = 0; $removed = 0
        foreach ($g in $games) {
            if (-not $g['installed'] -or -not $g['launch']) { continue }
            $uuid = Get-VpUuid ("{0}:{1}" -f $g['src'], $g['id'])
            if ($wanted.ContainsKey($uuid)) { continue }
            $wanted[$uuid] = $true
            $app = [ordered]@{
                name = [string]$g['name']
                uuid = $uuid
                cmd = 'cmd /c start "" "' + $g['launch'] + '"'
                'auto-detach' = $true
                'wait-all' = $false
            }
            if ($g['src'] -eq 'steam') { $app['steam-id'] = [string]$g['id'] }   # lets Vibepollo follow the Steam game
            $cover = Get-VpCover $g $uuid
            if ($cover) { $app['image-path'] = $cover }
            $g['vp'] = $true
            $cur = $existing[$uuid]
            if ($cur -and $cur.name -eq $app.name -and $cur.cmd -eq $app.cmd -and ([string]$cur.'image-path') -eq ([string]$app['image-path'])) { continue }
            $body = [System.Text.Encoding]::UTF8.GetBytes(($app | ConvertTo-Json -Depth 3 -Compress))
            Invoke-RestMethod -Method Post -Uri "$VibepolloUrl/api/apps" -Headers $vpHeaders -ContentType 'application/json' -Body $body -TimeoutSec 15 | Out-Null
            if ($cur) { $updated++ } else { $added++ }
        }
        foreach ($uuid in @($existing.Keys)) {
            if ($uuid -like 'bea57000-*' -and -not $wanted.ContainsKey($uuid)) {
                $body = ([ordered]@{ uuid = $uuid } | ConvertTo-Json -Compress)
                Invoke-RestMethod -Method Post -Uri "$VibepolloUrl/api/apps/delete" -Headers $vpHeaders -ContentType 'application/json' -Body $body -TimeoutSec 15 | Out-Null
                $removed++
            }
        }
        Log "Vibepollo: $($wanted.Count) game apps ($added added, $updated updated, $removed removed)"
    } catch {
        Log "Vibepollo sync failed: $($_.Exception.Message)"
    } finally {
        [Net.ServicePointManager]::CertificatePolicy = $oldPolicy
    }
}

# Save cover cache
try { $covers | ConvertTo-Json -Depth 3 | Set-Content -Encoding UTF8 $CoverCache } catch { }

# ---------- Send ----------
# Drop empty fields to keep the payload small
foreach ($g in $games) {
    foreach ($k in @($g.Keys)) { $v = $g[$k]; if ($null -eq $v -or ($v -is [string] -and $v -eq '') -or ($k -eq 'last_played' -and $v -eq 0)) { $g.Remove($k) } }
}
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
