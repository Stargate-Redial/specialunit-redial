# Hosting a Special Unit Linux dedicated server

The Stargate Redial server (`92.222.243.147:7810`) runs this way, natively on Debian 13, next to a plain UT2004 server on the same install. With 8 bots it uses about 150 MB and a few % of one vCPU.

The game and the mod are not in this repository: you bring them yourself, as below. The files referred to as `linux/...` are in this repository and in the release zip.

## 1. UT2004 with the OldUnreal 3374 patch

UT2004 has no Linux depot on Steam, but its content is the same on every platform, and the Linux binaries come from the patch:

1. the game content: the [OldUnreal full-game installer](https://github.com/OldUnreal/FullGameInstallers/releases) (free, for Linux too; it installs the game already patched), or SteamCMD from an account that owns it (`steamcmd +@sSteamCmdForcePlatformType windows +login <you> +app_update 13230 +quit`), or a copy of a Windows install;
2. rename `maps` to `Maps` (Steam ships it in lower case, and Linux file names are case-sensitive);
3. extract the Linux release of the [OldUnreal patch](https://github.com/OldUnreal/UT2004Patches/releases) over it. It needs glibc 2.34 or newer (Debian 12+, Ubuntu 22.04+). The server binary is `System/ucc-bin-amd64`.

## 2. Special Unit and Redial

Download the mod's official **`SpecialUnit.zip`** from its [ModDB page](https://www.moddb.com/mods/special-unit/downloads) (SHA-256 `a82b3202…6293`; ModDB doesn't let scripts download it, so copy it to the server yourself), and extract the release zip, then:

```bash
bash linux/install-server.sh /home/steam/ut2004 ~/SpecialUnit.zip ~/specialunit-redial-v1.0.2
```

It checks the zip, extracts the mod into `<UT2004>/SpecialUnit`, copies `SUBotFix` and `SUTweaks`, lets the engine build `SpecialUnit/System/SpecialUnit.ini` (from `System/UT2004.ini` and the mod's `default.ini`), then applies `linux/server-settings.ini` to it with `linux/su-ini.py`:

- port 7810, the master server uplink under the name the 3374 patch gave it (`IpDrv.MasterServerLauncher`: with the old name there's no query port and no listing), `DoUplink=True`;
- `ServerPackages=SUTweaks` (players download it), and never `SUBotFix` (server-side only);
- no web admin and no map vote (a UT2004 server on the same install has its own, on the same ports and with its own game types);
- the server name, 16 players, bot skill 4, the map rotation and the movement speed.

To change any of them, copy `server-settings.ini`, edit the copy and pass it after the zip folder: it's applied last (`Key=` sets a key, `+Key=` adds a line, `-Key=` removes one). `SpecialUnit.ini` starts as a copy of `System/UT2004.ini`: if that server has its own `ServerPackages`, take them out the same way (`-ServerPackages=MyMutator`), or players would download them too. The script lists them at the end. It backs up `SpecialUnit.ini` before each run, and running it again is safe.

A UT2004 server that runs on the same install isn't touched: Special Unit runs in its own process, with `-mod=SpecialUnit` and its own ini.

## 3. Run

`linux/run-server.sh` starts the server in a loop that restarts it after a crash. Copy it anywhere and set its variables (or pass them in the environment): `UT2004`, `IP`, `PORT`, `MAP`, `BOTS`, `DIFFICULTY`. `linux/sgsu.service` is a systemd unit that runs it in a `screen`.

- Open in UDP: the game port (7810), the query port (+1, 7811) and the old GameSpy query port (+10, 7820).
- Set `IP` (`-multihome`) on a host with several addresses.
- `BOTS` is the number of players the bots fill up to: bots leave as players join. A dedicated server waits without a human; the match starts when the first player joins.
- Each run writes `System/SpecialUnit-server.log`, renamed with its end time when it stops; the 10 newest are kept. `System/SpecialUnit-restarts.log` lists the restarts.
- Each round lasts the time its map sets (10 minutes on Asteroid and Asgard, 15 on P3X-548, Chulak, Abydos and TokRa, 17 on Antartica, 20 on X303Down, 30 on IceDet).
- The bots' skill balance learns from each round and keeps its scores per map in `System/SUBotFixBalance.ini`.

## 4. Settings of the bots

In `[SUBotFix.MutSUBotFix]` of `SpecialUnit.ini` (the defaults are those of the 24/7 server):

| Setting | Default | Effect |
|---|---|---|
| `bAutoBalance` | `True` | the side that wins a map more often gets weaker bots |
| `bBalanceLearn` | `True` | the map's score moves after each round (saved in `SUBotFixBalance.ini`) |
| `BalanceScores` | built in | starting scores, e.g. `BalanceScores=SU-Chulak=-1` (negative: the Tau'ri have been winning) |
| `HumanMaxBias` | `1.0` | while a human plays (not in co-op), the skill gap between the sides stays within this many levels each way |
| `HopTransitSpeed` | `1000` | while a human plays, a bot whose side only has far spawns (Abydos's Tau'ri) stays dead as long as a drive at this speed (uu/s) to the front takes; `0` turns it off |
| `bMapRoundTime` | `True` | each round lasts its map's time, not `TimeLimit` |
| `bLogFixes` | `True` | what the bots' fixes do, in the server log |
