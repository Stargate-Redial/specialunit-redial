#!/bin/bash
# Special Unit dedicated server, native Linux (UT2004 with the OldUnreal 3374 patch), with the Redial bots.
# Setup: docs/LINUX_SERVER.md. Run it as the server's user, e.g. under screen or from linux/sgsu.service.
#
# The loop restarts the server after a crash. Don't use "set -e": ucc exits with a non-zero code then.
set -uo pipefail

# --- Settings -----------------------------------------------------------------------------------------------
UT2004=${UT2004:-$HOME/ut2004}  # the UT2004 install, with Special Unit in its SpecialUnit folder
IP=${IP:-}                      # the public address on a multi-homed host (-multihome)
PORT=${PORT:-7810}              # game port; queries on PORT+1, old GameSpy queries on PORT+10
MAP=${MAP:-SU-Abydos}           # first map; then the rotation of [SpecialUnit.SUMapListMission]
BOTS=${BOTS:-8}                 # players + bots kept in the game: bots leave as players join
DIFFICULTY=${DIFFICULTY:-4}     # bot skill 0-7; at 4 bots lead their shots; at the engine default of 1 they hardly shoot back
# SUBotFix: the bots (server-side only). SUTweaks.MutSUSpeed: movement x1.4 (needs ServerPackages=SUTweaks).
MUTATORS=${MUTATORS:-SUBotFix.MutSUBotFix,SUTweaks.MutSUSpeed}
# ------------------------------------------------------------------------------------------------------------

cd "$UT2004/System" || exit 1
UCC=./ucc-bin-amd64
[ -x "$UCC" ] || UCC=./ucc-bin
LOG=SpecialUnit-server.log

while :; do
	echo "$(date '+%F %T') starting Special Unit ($PORT)" | tee -a SpecialUnit-restarts.log
	rc=0
	"$UCC" server "$MAP?game=SpecialUnit.SUGameInfo?MinPlayers=$BOTS?Difficulty=$DIFFICULTY?Port=$PORT?Mutator=$MUTATORS" \
		-mod=SpecialUnit -nohomedir -log="$LOG" ${IP:+-multihome=$IP} || rc=$?
	echo "$(date '+%F %T') server exited (code $rc), restarting in 5 s" | tee -a SpecialUnit-restarts.log

	# one log per run, stamped when it ends; keep the 10 newest
	[ -f "$LOG" ] && mv -- "$LOG" "SpecialUnit-server-$(date +%Y%m%d-%H%M%S).log"
	ls -1t SpecialUnit-server-*.log 2>/dev/null | tail -n +11 | while IFS= read -r f; do rm -f -- "$f"; done
	sleep 5
done
