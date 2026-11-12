#!/usr/bin/env bash
# Build SUBotFix.u and SUTweaks.u from src/ with the UT2004 compiler (ucc make), in a Windows UT2004 install
# that has Special Unit (Git Bash; see docs/BUILDING.md).
# Usage: tools/build.sh <UT2004 dir>
# The packages land in <UT2004 dir>/SpecialUnit/System, with their .ucl. The mod's SpecialUnit.ini must
# list them after SU_SpaceCrafts:  EditPackages=SUBotFix  and  EditPackages=SUTweaks  ([Editor.EditorEngine]).
set -eu
REPO=$(cd "$(dirname "$0")/.." && pwd)
U=$(cd "${1:?UT2004 dir}" && pwd)
INI=$U/SpecialUnit/System/SpecialUnit.ini
[ -f "$INI" ] || { echo "$INI not found: start the mod once (UT2004.exe -mod=SpecialUnit)"; exit 1; }
for p in SUBotFix SUTweaks; do
    tr -d '\r' < "$INI" | grep -qx "EditPackages=$p" || { echo "add EditPackages=$p to [Editor.EditorEngine] in $INI"; exit 1; }
    mkdir -p "$U/$p/Classes"
    rm -f "$U/$p/Classes/"*.uc
    cp "$REPO/src/$p/Classes/"*.uc "$U/$p/Classes/"
    # ucc make only builds the packages whose .u is missing
    rm -f "$U/System/$p.u" "$U/SpecialUnit/System/$p.u"
done
LOG=$U/System/make-redial.log
(cd "$U/System" && ./UCC.exe make -mod=SpecialUnit -nohomedir -silent > "$LOG" 2>&1) || true
tr -d '\r' < "$LOG" | grep -E 'Error|Warning' | grep -v '^Loading' || true
for p in SUBotFix SUTweaks; do
    [ -f "$U/System/$p.u" ] || { echo "BUILD FAILED: $p (see $LOG)"; exit 1; }
    mv "$U/System/$p.u" "$U/SpecialUnit/System/$p.u"
    echo "built $U/SpecialUnit/System/$p.u"
done
