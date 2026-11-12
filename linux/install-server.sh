#!/usr/bin/env bash
# Install Special Unit and Special Unit: Redial into a dedicated UT2004 server (Linux, OldUnreal 3374).
#
# Usage: install-server.sh <UT2004 dir> <SpecialUnit.zip> <extracted release zip> [settings.ini...]
#   <extracted release zip>: specialunit-redial-v*.zip, extracted (it holds files/ and linux/)
#   settings.ini: applied to SpecialUnit.ini after linux/server-settings.ini (see su-ini.py), e.g. your
#   server name, or the ServerPackages of another server on the same install to take out
#
# The mod goes next to the stock game (<UT2004 dir>/SpecialUnit), so a UT2004 server on the same install
# keeps working: Special Unit runs as a separate process, with -mod=SpecialUnit and its own SpecialUnit.ini.
# Running it again is safe: files are overwritten, SpecialUnit.ini is backed up and the
# settings are applied again (the map rotation restarts at its first map).
set -euo pipefail
UT=${1:?UT2004 dir}; ZIP=${2:?SpecialUnit.zip}; REL=${3:?extracted release zip}; shift 3
SHA=a82b32021193eb6f0d293524b9e5d9544d6255b52986abd7d1386092b69d6293
HERE=$(cd "$(dirname "$0")" && pwd)
UCC=$UT/System/ucc-bin-amd64
[ -x "$UCC" ] || UCC=$UT/System/ucc-bin
[ -x "$UCC" ] || { echo "no ucc-bin in $UT/System (is the OldUnreal 3374 patch installed?)"; exit 1; }
[ -f "$REL/files/SpecialUnit/System/SUBotFix.u" ] || { echo "$REL is not an extracted release zip (files/ missing)"; exit 1; }

echo "== checking $ZIP (the official ModDB release)"
echo "$SHA  $ZIP" | sha256sum -c -

echo "== extracting the mod into $UT/SpecialUnit"
if command -v unzip > /dev/null; then unzip -q -o "$ZIP" -d "$UT"; else python3 -m zipfile -e "$ZIP" "$UT"; fi
SU=$UT/SpecialUnit/System
[ -f "$SU/SpecialUnit.u" ] || { echo "extraction failed: $SU/SpecialUnit.u missing"; exit 1; }

echo "== Special Unit: Redial files"
cp -r "$REL/files/." "$UT/"

echo "== SpecialUnit.ini"
if [ ! -f "$SU/SpecialUnit.ini" ]; then
    # first start of the mod: the engine builds SpecialUnit.ini from System/UT2004.ini and the mod's default.ini
    (cd "$UT/System" && "$UCC" help -mod=SpecialUnit -nohomedir > /dev/null 2>&1 || true)
fi
[ -f "$SU/SpecialUnit.ini" ] || { echo "SpecialUnit.ini was not generated"; exit 1; }
cp "$SU/SpecialUnit.ini" "$SU/SpecialUnit.ini.bak-$(date +%Y%m%d-%H%M%S)"
python3 -I "$HERE/su-ini.py" "$SU/SpecialUnit.ini" "$HERE/server-settings.ini" "$@"
grep -q '^ServerActors=IpDrv.MasterServerLauncher' "$SU/SpecialUnit.ini" || echo "WARNING: no MasterServerLauncher in SpecialUnit.ini: the server will not be listed"
grep -q '^ServerPackages=SUBotFix' "$SU/SpecialUnit.ini" && echo "WARNING: SUBotFix must NOT be in ServerPackages"
grep -q '^ServerPackages=SUTweaks' "$SU/SpecialUnit.ini" || echo "WARNING: ServerPackages=SUTweaks is missing (SU Speed)"
echo "ServerPackages that players download (take out any that belong to another server on this install):"
grep '^ServerPackages=' "$SU/SpecialUnit.ini" | sed 's/^ServerPackages=/  /' | tr '\n' ' '; echo

echo "done. Next: start linux/run-server.sh (or the linux/sgsu.service unit)"
