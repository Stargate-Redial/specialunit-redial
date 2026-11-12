# Building SUBotFix and SUTweaks

The two packages are UnrealScript, compiled by the game's own compiler (`ucc make`) in a Windows UT2004 install with the OldUnreal 3374 patch and Special Unit.

1. In `SpecialUnit\System\SpecialUnit.ini` (start the mod once to create it), add to `[Editor.EditorEngine]`, after `EditPackages=SU_SpaceCrafts`:

   ```ini
   EditPackages=SUBotFix
   EditPackages=SUTweaks
   ```

2. From Git Bash: `bash tools/build.sh "<UT2004 folder>"`. It copies `src/<package>/Classes` into `<UT2004>/<package>/Classes`, deletes the old `.u` (`ucc make` only builds missing packages), runs `UCC.exe make -mod=SpecialUnit` and moves `SUBotFix.u` and `SUTweaks.u` into `SpecialUnit\System`. In mod mode, `ucc make` writes the `.ucl` files (what the menus list) there directly.

## Rules

- **Never rebuild `SpecialUnit.u` or `SU_SpaceCrafts.u`.** Every player has the ModDB files: a server running a rebuilt package has another GUID, and players get a version mismatch. Everything here is done from separate packages.
- **SUBotFix stays out of `ServerPackages`.** It only runs on the server; players don't need it.
- **SUTweaks is in `ServerPackages`:** players download it from servers, and movement is predicted on their side. Every build gets a new GUID, so a rebuilt SUTweaks can't join servers that run the released one, and the other way round. Change it only under a new package name (`SUTweaks2`), never under the same one.
- Exported script of the mod is for reading only, and must never be published: the mod's licence forbids re-releasing it.

## How SUBotFix works

`MutSUBotFix` is a mutator. When a map loads, it analyses the navigation network for the mod's soldiers (20x55 where the maps were pathed for 26x44), resizes the paths they fit, links objectives and islands with new paths (`ReachSpec`s created at run time and written with the `POKE` console command), and floods the floor to lay corridors where a map has none. During the match it replaces the team AI's squads (`SUBotSquadAI`) and steers the bots where the stock AI stops: objectives, crystals, rings, vehicles, pilots, medics, ammo, stuck bots. Each fix is described in a comment above its code, with the measurements that justified it.
