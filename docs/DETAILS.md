# What the installer does

`install.bat` runs `install.ps1` with Windows PowerShell 5.1. Everything it does can also be done by hand, as below.

## Where things are

| | Found from | Default |
|---|---|---|
| UT2004 | Steam (registry `HKCU\Software\Valve\Steam`, then every library in `steamapps\libraryfolders.vdf`), then the registry of the retail game | `Steam\steamapps\common\Unreal Tournament 2004` |
| `SpecialUnit.zip` | the release folder, `Downloads` (and the Downloads folder Windows knows), `Desktop` | |

`-UT2004Dir` and `-ZipPath` override them. If the UT2004 folder isn't writable (`C:\Program Files`), the installer starts again as administrator.

## 1. The OldUnreal 3374 patch

The installer reads `System\Build.ini`. Below 3374, it offers to download the latest Windows zip of the [OldUnreal patch](https://github.com/OldUnreal/UT2004Patches/releases) from GitHub, copies `System\` to `System-before-patch-<date>\`, and extracts the patch over the game. Without it, the Internet server list stays empty: Epic's master servers are closed. `-NoPatchCheck` skips it.

## 2. Special Unit

If `SpecialUnit\System\SpecialUnit.u` is missing, the installer needs the official release, **`SpecialUnit.zip`** from the mod's [ModDB page](https://www.moddb.com/mods/special-unit/downloads): 250 121 610 bytes, SHA-256 `a82b32021193eb6f0d293524b9e5d9544d6255b52986abd7d1386092b69d6293`. It opens the page and watches the folders above for up to 30 minutes. A file with another size or hash is refused. The zip only holds a `SpecialUnit\` folder (about 600 MB), extracted into the UT2004 folder. An installed mod is kept as it is.

## 3. Redial files

`files\` of the release zip is copied into the UT2004 folder:

| File | What |
|---|---|
| `SpecialUnit\System\SUBotFix.u`, `SUBotFix.ucl` | the bots (mutator "SU Bot Fix", server-side only) |
| `SpecialUnit\System\SUTweaks.u`, `SUTweaks.ucl` | faster movement (mutator "SU Speed"); servers send it to players, so it must be this exact file |

## 4. Settings

The mod builds `SpecialUnit\System\SpecialUnit.ini` from `SpecialUnit\System\default.ini` the first time it starts. The installer adds these lines to `default.ini`, and to `SpecialUnit.ini` if it exists already (a line already there is not added twice):

```ini
[Engine.GameEngine]
; only with the 3374 patch, which renamed the actor: with the old name there is no query port and no listing
-ServerActors=IpDrv.MasterServerUplink
+ServerActors=IpDrv.MasterServerLauncher

[IpDrv.MasterServerLink]
+MasterServerList=(Address="ut2004master.333networks.com",Port=28902,Group=1)
+MasterServerList=(Address="ut2004master.gonespy.com",Port=28902,Group=1)
+MasterServerList=(Address="ut2004master.errorist.eu",Port=28902,Group=1)
+MasterServerList=(Address="master.frag-net.com",Port=28902,Group=1)
+MasterServerList=(Address="master.noccer.de",Port=28902,Group=1)
+MasterServerList=(Address="utmaster.openspy.net",Port=28902,Group=2)

[XInterface.ExtendedConsole]
; one line per server of servers.txt
+Favorites=(ServerID=0,IP="92.222.243.147",Port=7810,QueryPort=7811,ServerName="Special Unit: Redial - bots 24/7")

[GUI2K4.UT2K4Tab_MutatorSP]
; only if you never chose mutators: "SU Bot Fix" and "SU Speed" ticked in Instant Action and Host Game
LastActiveMutators=SUBotFix.MutSUBotFix,SUTweaks.MutSUSpeed

[GUI2K4.UT2K4Tab_MutatorMP]
LastActiveMutators=SUBotFix.MutSUBotFix,SUTweaks.MutSUSpeed
```

In `SpecialUnit.ini` the lines go without their `+`. Files are written in Windows-1252 with CRLF line ends, as the game writes them.

## 5. Shortcuts

**Stargate - Special Unit** on the Desktop and in the Start menu: `System\UT2004.exe -mod=SpecialUnit`. `-NoShortcuts` skips them.

## Uninstall

`uninstall.bat` (`install.ps1 -Uninstall`) deletes the `SpecialUnit` folder (the mod, its settings and Redial) and the two shortcuts. The rest of UT2004 is not touched; the OldUnreal patch stays.
