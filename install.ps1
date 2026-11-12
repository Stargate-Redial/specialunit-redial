<#
.SYNOPSIS
    Installs Special Unit (the 2013 Stargate mod for Unreal Tournament 2004) and Special Unit: Redial.

.DESCRIPTION
    Installs the official ModDB release of Special Unit into UT2004, then adds Special Unit: Redial:
    the bots that play the objectives (SUBotFix), faster movement (SUTweaks), compatibility with the
    OldUnreal 3374 patch, the master servers, the 24/7 server in Favorites, and a shortcut.

    The mod itself is NOT included: its licence forbids redistributing it. The installer opens the mod's
    ModDB page, waits for SpecialUnit.zip in your Downloads folder, checks its SHA-256 and installs it.
    Running it again is safe. Windows PowerShell 5.1 (built into Windows 10/11); install.bat runs it.

.PARAMETER UT2004Dir
    The UT2004 folder (the one holding System\UT2004.exe), if it isn't found.

.PARAMETER ZipPath
    SpecialUnit.zip, if you already downloaded it somewhere else than Downloads or Desktop.

.PARAMETER Uninstall
    Removes the SpecialUnit folder (mod, its settings and Redial) and the shortcuts. uninstall.bat runs it.
#>
param(
    [string]$UT2004Dir,
    [string]$ZipPath,
    [switch]$Uninstall,
    [switch]$NoPatchCheck,       # don't offer the OldUnreal patch
    [switch]$Quiet,              # no questions: default answers
    [switch]$NoShortcuts         # no shortcuts (tests)
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Version = '?'
try { $Version = (Get-Content -LiteralPath (Join-Path $Here 'VERSION') -TotalCount 1).Trim() } catch { }

# --- Official Special Unit release expected (ModDB, 2013-01-13) ---
$SuZipSha256 = 'a82b32021193eb6f0d293524b9e5d9544d6255b52986abd7d1386092b69d6293'
$SuZipSize   = 250121610
$SuModDbUrl  = 'https://www.moddb.com/mods/special-unit/downloads'
$OldUnrealApi = 'https://api.github.com/repos/OldUnreal/UT2004Patches/releases/latest'
$ShortcutName = 'Stargate - Special Unit'

function Say([string]$msg, [string]$color = 'Gray') { Write-Host $msg -ForegroundColor $color }
function Step([string]$msg) { Write-Host ''; Write-Host "== $msg" -ForegroundColor Cyan }
function Ask([string]$question, [bool]$default = $true) {
    if ($Quiet) { return $default }
    $suffix = if ($default) { '[Y/n]' } else { '[y/N]' }
    $a = Read-Host "$question $suffix"
    if ([string]::IsNullOrWhiteSpace($a)) { return $default }
    return ($a.Trim().ToLower() -in @('y', 'yes', 'o', 'oui'))
}

# ---------------------------------------------------------------- UT2004 detection
function Test-UT2004Dir([string]$d) {
    return ($d -and (Test-Path (Join-Path $d 'System\UT2004.exe')))
}

function Find-UT2004 {
    $candidates = New-Object System.Collections.Generic.List[string]
    # Steam: libraries listed in libraryfolders.vdf
    foreach ($key in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
        try {
            $p = Get-ItemProperty -Path $key -ErrorAction Stop
            foreach ($steam in @($p.SteamPath, $p.InstallPath)) {
                if (-not $steam) { continue }
                $steam = $steam -replace '/', '\'
                $candidates.Add((Join-Path $steam 'steamapps\common\Unreal Tournament 2004'))
                $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
                if (Test-Path $vdf) {
                    foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                        $lib = $m.Groups[1].Value -replace '\\\\', '\'
                        $candidates.Add((Join-Path $lib 'steamapps\common\Unreal Tournament 2004'))
                    }
                }
            }
        } catch { }
    }
    # Boxed / Editor's Choice / manual installs
    foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\Unreal Technology\Installed Apps\UT2004', 'HKLM:\SOFTWARE\Unreal Technology\Installed Apps\UT2004') {
        try { $candidates.Add((Get-ItemProperty -Path $key -ErrorAction Stop).Folder) } catch { }
    }
    foreach ($d in 'C:\UT2004', 'C:\Games\UT2004', 'C:\Program Files (x86)\Unreal Tournament 2004', 'C:\Program Files\Unreal Tournament 2004') {
        $candidates.Add($d)
    }
    foreach ($c in $candidates) { if (Test-UT2004Dir $c) { return (Resolve-Path $c).Path } }
    return $null
}

function Select-Folder {
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Pick the Unreal Tournament 2004 folder (the one holding System\UT2004.exe)"
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
    return $null
}

# ---------------------------------------------------------------- engine version
function Get-EngineBuild([string]$ut) {
    $bi = Join-Path $ut 'System\Build.ini'
    if (Test-Path $bi) {
        $label = (Get-Content $bi | Where-Object { $_ -like 'Label=*' } | Select-Object -First 1)
        if ($label -match 'v(\d{4})') { return @{ Version = [int]$Matches[1]; Label = $label.Substring(6) } }
        return @{ Version = 0; Label = $label }
    }
    return @{ Version = 0; Label = '(unknown)' }
}

function Install-OldUnrealPatch([string]$ut) {
    Say 'Looking up the latest OldUnreal patch on GitHub...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $rel = Invoke-RestMethod -Uri $OldUnrealApi -Headers @{ 'User-Agent' = 'SpecialUnit-Redial-Installer' }
    $asset = $rel.assets | Where-Object { $_.name -like '*Windows*.zip' } | Select-Object -First 1
    if (-not $asset) { throw "No Windows zip in release $($rel.tag_name)" }
    $tmp = Join-Path $env:TEMP $asset.name
    Say "Downloading $($asset.name) ($([math]::Round($asset.size / 1MB)) MB)..."
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmp -UseBasicParsing
    $bak = Join-Path $ut ("System-before-patch-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Say "Backing up System\ to $bak"
    Copy-Item -Recurse (Join-Path $ut 'System') $bak
    Say 'Installing the patch...'
    Expand-Zip $tmp $ut
    Remove-Item $tmp
    Say "Patch $($rel.tag_name) installed." 'Green'
}

# ---------------------------------------------------------------- zip helpers
function Expand-Zip([string]$zip, [string]$dest) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [System.IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $destFull = [System.IO.Path]::GetFullPath($dest)
        foreach ($e in $z.Entries) {
            $target = [System.IO.Path]::GetFullPath((Join-Path $dest $e.FullName))
            if (-not $target.StartsWith($destFull, [StringComparison]::OrdinalIgnoreCase)) { throw "Invalid path in the zip: $($e.FullName)" }
            if ($e.Name -eq '') { New-Item -ItemType Directory -Force -Path $target | Out-Null; continue }
            New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
        }
    } finally { $z.Dispose() }
}

function Test-SuZip([string]$p) {
    if (-not (Test-Path $p)) { return $false }
    if ((Get-Item $p).Length -ne $SuZipSize) { return $false }
    return ((Get-FileHash -Algorithm SHA256 $p).Hash.ToLower() -eq $SuZipSha256)
}

function Find-SuZip {
    $dirs = @($Here, (Join-Path $env:USERPROFILE 'Downloads'), (Join-Path $env:USERPROFILE 'Desktop'))
    try {
        $dl = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction Stop).'{374DE290-123F-4565-9164-39C4925E467B}'
        if ($dl) { $dirs += [Environment]::ExpandEnvironmentVariables($dl) }
    } catch { }
    foreach ($d in ($dirs | Select-Object -Unique)) {
        if (-not (Test-Path $d)) { continue }
        foreach ($f in Get-ChildItem -Path $d -Filter '*.zip' -File -ErrorAction SilentlyContinue | Where-Object { $_.Length -eq $SuZipSize }) {
            if (Test-SuZip $f.FullName) { return $f.FullName }
        }
    }
    return $null
}

# ---------------------------------------------------------------- ini helpers (Windows-1252, CRLF)
$Enc = [System.Text.Encoding]::GetEncoding(1252)
function Read-Lines([string]$p) { return ,([System.IO.File]::ReadAllText($p, $Enc) -split "`r?`n") }
function Write-Lines([string]$p, $lines) { [System.IO.File]::WriteAllText($p, ($lines -join "`r`n"), $Enc) }

# Ensure each line of $add is present in [$section] (creates the section if needed).
function Add-IniLines([string]$p, [string]$section, [string[]]$add) {
    $lines = [System.Collections.Generic.List[string]](Read-Lines $p)
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -ieq "[$section]") { $start = $i; break } }
    if ($start -lt 0) {
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -ne '') { $lines.Add('') }
        $lines.Add("[$section]"); $start = $lines.Count - 1
    }
    $end = $lines.Count
    for ($i = $start + 1; $i -lt $lines.Count; $i++) { if ($lines[$i].StartsWith('[')) { $end = $i; break } }
    # insert after the last non-empty line of the section
    $insert = $end
    while ($insert -gt $start + 1 -and $lines[$insert - 1].Trim() -eq '') { $insert-- }
    $changed = $false
    foreach ($l in $add) {
        $present = $false
        for ($i = $start + 1; $i -lt $end; $i++) { if ($lines[$i].Trim() -ieq $l) { $present = $true; break } }
        if (-not $present) { $lines.Insert($insert, $l); $insert++; $end++; $changed = $true }
    }
    if ($changed) { Write-Lines $p $lines }
    return $changed
}

# Set Key=Value in [$section] unless the key already has a value there (keeps the player's choice).
function Set-IniKeyIfMissing([string]$p, [string]$section, [string]$key, [string]$value) {
    $lines = Read-Lines $p
    $in = $false
    foreach ($l in $lines) {
        $t = $l.Trim()
        if ($t.StartsWith('[')) { $in = ($t -ieq "[$section]"); continue }
        if ($in -and $t -match "^$([regex]::Escape($key))=(.+)$") { return $false }
    }
    return (Add-IniLines $p $section @("$key=$value"))
}

function Set-IniLineReplace([string]$p, [string]$from, [string]$to) {
    $lines = Read-Lines $p
    $changed = $false
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -ieq $from) { $lines[$i] = $to; $changed = $true } }
    if ($changed) { Write-Lines $p $lines }
    return $changed
}

# ---------------------------------------------------------------- shortcuts
function New-Shortcut([string]$lnk, [string]$ut) {
    $sh = New-Object -ComObject WScript.Shell
    $s = $sh.CreateShortcut($lnk)
    $s.TargetPath = Join-Path $ut 'System\UT2004.exe'
    $s.Arguments = '-mod=SpecialUnit'
    $s.WorkingDirectory = Join-Path $ut 'System'
    $s.IconLocation = (Join-Path $ut 'System\UT2004.exe') + ',0'
    $s.Description = 'Special Unit - Stargate mod for Unreal Tournament 2004'
    $s.Save()
}
function Get-ShortcutPaths {
    return @(
        (Join-Path ([Environment]::GetFolderPath('Desktop')) "$ShortcutName.lnk"),
        (Join-Path ([Environment]::GetFolderPath('Programs')) "$ShortcutName.lnk")
    )
}

# ================================================================= main
Say "Special Unit: Redial $Version installer - the Stargate mod for UT2004, with bots that play the objectives" 'Yellow'

if (-not (Test-UT2004Dir $UT2004Dir)) { $UT2004Dir = Find-UT2004 }
if (-not (Test-UT2004Dir $UT2004Dir)) {
    Say "UT2004 was not found."
    $UT2004Dir = Select-Folder
    if (-not (Test-UT2004Dir $UT2004Dir)) { throw "Not a UT2004 folder (no System\UT2004.exe)." }
}
Say "UT2004: $UT2004Dir" 'Green'

# Write access (e.g. C:\Program Files): otherwise start again as administrator
try {
    $probe = Join-Path $UT2004Dir ('.su-write-test-' + [guid]::NewGuid().ToString('N'))
    [System.IO.File]::WriteAllText($probe, 'x'); Remove-Item $probe
} catch {
    Say "No write access to $UT2004Dir : starting again as administrator..." 'Yellow'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$($MyInvocation.MyCommand.Path)`"", '-UT2004Dir', "`"$UT2004Dir`"")
    if ($ZipPath) { $argList += @('-ZipPath', "`"$ZipPath`"") }
    foreach ($sw in 'Uninstall', 'NoPatchCheck', 'Quiet', 'NoShortcuts') { if ((Get-Variable $sw).Value) { $argList += "-$sw" } }
    Start-Process powershell -Verb RunAs -ArgumentList $argList -Wait
    return
}
$SuDir = Join-Path $UT2004Dir 'SpecialUnit'
$SuSys = Join-Path $SuDir 'System'

if ($Uninstall) {
    Step 'Uninstall'
    if (Test-Path $SuDir) {
        if (Ask "Delete $SuDir (the mod, its settings and Redial)?" $true) { Remove-Item -Recurse -Force $SuDir; Say 'Mod removed.' 'Green' }
    }
    foreach ($l in Get-ShortcutPaths) { if (Test-Path $l) { Remove-Item $l } }
    Say 'Done.' 'Green'
    return
}

# 1. OldUnreal patch
Step 'Game version'
$build = Get-EngineBuild $UT2004Dir
Say "Build: $($build.Label)"
if ($build.Version -lt 3374) {
    Say "UT2004 doesn't have the OldUnreal community patch (3374). Without it the server list stays empty" 'Yellow'
    Say "(Epic's master servers are closed), and the game keeps bugs fixed since." 'Yellow'
    if (-not $NoPatchCheck -and (Ask 'Download and install the latest OldUnreal patch now?' $true)) {
        Install-OldUnrealPatch $UT2004Dir
        $build = Get-EngineBuild $UT2004Dir
    }
}
$Patched = ($build.Version -ge 3374)

# 2. Special Unit (ModDB release)
Step 'Special Unit (ModDB)'
$suInstalled = Test-Path (Join-Path $SuSys 'SpecialUnit.u')
if ($suInstalled) {
    Say 'Special Unit is already installed: its files are kept.' 'Green'
} else {
    if (-not $ZipPath) { $ZipPath = Find-SuZip }
    if ($ZipPath -and -not (Test-SuZip $ZipPath)) { throw "$ZipPath is not the official Special Unit release (size or SHA-256 differs)." }
    if (-not $ZipPath) {
        Say "The mod isn't included here (its licence forbids redistributing it)."
        Say "Its ModDB page is opening: download SpecialUnit.zip (250 MB)."
        Say "The installer finds it by itself in your Downloads folder."
        Start-Process $SuModDbUrl
        $deadline = (Get-Date).AddMinutes(30)
        while (-not $ZipPath -and (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 3
            $ZipPath = Find-SuZip
        }
        if (-not $ZipPath) { throw 'SpecialUnit.zip not found. Run the installer again with: install.bat -ZipPath "path\to\SpecialUnit.zip"' }
    }
    Say "Archive: $ZipPath" 'Green'
    Say 'Extracting (about 600 MB)...'
    Expand-Zip $ZipPath $UT2004Dir
    if (-not (Test-Path (Join-Path $SuSys 'SpecialUnit.u'))) { throw "Extraction incomplete: $SuSys\SpecialUnit.u is missing" }
    Say 'Special Unit installed.' 'Green'
}

# 3. Redial
Step "Special Unit: Redial $Version"
$files = Join-Path $Here 'files'
if (-not (Test-Path (Join-Path $files 'SpecialUnit\System\SUBotFix.u'))) {
    throw "files\SpecialUnit\System\SUBotFix.u is missing. Download the release zip from https://github.com/Stargate-Redial/specialunit-redial/releases, not the source code."
}
Copy-Item -Recurse -Force (Join-Path $files '*') $UT2004Dir
Say 'Bots (SU Bot Fix) and movement speed (SU Speed) installed.' 'Green'

# The mod's default.ini: SpecialUnit.ini is built from it on the mod's first start
$defIni = Join-Path $SuSys 'default.ini'
$serverLines = @()
$serversFile = Join-Path $Here 'servers.txt'
if (Test-Path $serversFile) {
    foreach ($l in Get-Content $serversFile) {
        $l = $l.Trim()
        if ($l -eq '' -or $l.StartsWith('#')) { continue }
        $parts = $l -split '\s+', 2   # "ip:port  Server name"
        $hp = $parts[0] -split ':'
        $name = if ($parts.Count -gt 1) { $parts[1] } else { 'Special Unit' }
        $serverLines += ('Favorites=(ServerID=0,IP="{0}",Port={1},QueryPort={2},ServerName="{3}")' -f $hp[0], [int]$hp[1], ([int]$hp[1] + 1), $name)
    }
}
$masters = @(
    '(Address="ut2004master.333networks.com",Port=28902,Group=1)',
    '(Address="ut2004master.gonespy.com",Port=28902,Group=1)',
    '(Address="ut2004master.errorist.eu",Port=28902,Group=1)',
    '(Address="master.frag-net.com",Port=28902,Group=1)',
    '(Address="master.noccer.de",Port=28902,Group=1)',
    '(Address="utmaster.openspy.net",Port=28902,Group=2)'
)
if ($Patched) {
    Add-IniLines $defIni 'Engine.GameEngine' @('-ServerActors=IpDrv.MasterServerUplink', '+ServerActors=IpDrv.MasterServerLauncher') | Out-Null
}
Add-IniLines $defIni 'IpDrv.MasterServerLink' ($masters | ForEach-Object { "+MasterServerList=$_" }) | Out-Null
if ($serverLines.Count -gt 0) { Add-IniLines $defIni 'XInterface.ExtendedConsole' ($serverLines | ForEach-Object { "+$_" }) | Out-Null }
# "SU Bot Fix" and "SU Speed" ticked in Instant Action (SP) and Host Game (MP)
$botFix = 'SUBotFix.MutSUBotFix,SUTweaks.MutSUSpeed'
foreach ($sec in 'GUI2K4.UT2K4Tab_MutatorSP', 'GUI2K4.UT2K4Tab_MutatorMP') { Set-IniKeyIfMissing $defIni $sec 'LastActiveMutators' $botFix | Out-Null }

# SpecialUnit.ini already built (reinstall / update): the same changes, made directly
$suIni = Join-Path $SuSys 'SpecialUnit.ini'
if (Test-Path $suIni) {
    if ($Patched) { Set-IniLineReplace $suIni 'ServerActors=IpDrv.MasterServerUplink' 'ServerActors=IpDrv.MasterServerLauncher' | Out-Null }
    Add-IniLines $suIni 'IpDrv.MasterServerLink' ($masters | ForEach-Object { "MasterServerList=$_" }) | Out-Null
    if ($serverLines.Count -gt 0) { Add-IniLines $suIni 'XInterface.ExtendedConsole' $serverLines | Out-Null }
    foreach ($sec in 'GUI2K4.UT2K4Tab_MutatorSP', 'GUI2K4.UT2K4Tab_MutatorMP') { Set-IniKeyIfMissing $suIni $sec 'LastActiveMutators' $botFix | Out-Null }
}
Say 'Settings: master servers, the 24/7 server in Favorites, 3374 compatibility, SU Bot Fix and SU Speed ticked.' 'Green'

# 4. Shortcuts
Step 'Shortcuts'
if ($NoShortcuts) { Say 'No shortcuts (-NoShortcuts).' }
else {
    foreach ($l in Get-ShortcutPaths) { New-Shortcut $l $UT2004Dir }
    Say "Shortcut '$ShortcutName' created on the Desktop and in the Start menu." 'Green'
}

Write-Host ''
Say 'Installation complete!' 'Yellow'
Say "To play: the '$ShortcutName' shortcut (or UT2004.exe -mod=SpecialUnit)."
Say 'With bots: Instant Action > an SU-... map > number of bots ("SU Bot Fix" is already ticked).'
Say 'Online: Join Game > Favorites, or Internet (game type Special Unit).'
if (-not $Patched) { Say "Warning: without the OldUnreal 3374 patch, the Internet list may stay empty." 'Yellow' }
