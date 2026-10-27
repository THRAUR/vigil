#!/bin/sh
# Lid-closed test for Vigil.
#
#   scripts/lid-test.sh [MINUTES] [LOG]      (defaults: 11, ~/vigil-lid-test.log)
#
# Holds the Mac awake through `vigil run` and logs a line every 10 s. Close the lid any time in
# the first 15 minutes; the hold lasts until the lid has been closed for MINUTES, then it lets go
# and logs 5 more minutes without a hold. Expected log: a line every ~10 s with lid=closed through
# the held phase, then a gap (Vigil puts the closed Mac to sleep), then lines again once you open it.
set -u

lid() { ioreg -r -k AppleClamshellState -d 1 | awk -F'= ' '/"AppleClamshellState"/ { print ($2 == "Yes") ? "closed" : "open"; exit }'; }
flag() { if ioreg -r -n IOPMrootDomain -d 1 | grep -q '"SleepDisabled" = Yes'; then echo 1; else echo 0; fi; }
power() { pmset -g batt | awk -F"'" 'NR == 1 { src = $2 } NR == 2 && match($0, /[0-9]+%/) { pct = substr($0, RSTART, RLENGTH) } END { print src ", " pct }'; }
line() { printf '%s  %-6s lid=%-6s SleepDisabled=%s  %s\n' "$(date +%T)" "$1" "$(lid)" "$(flag)" "$(power)" >> "$LOG"; }

if [ "${1:-}" = "--held" ]; then # the part that runs inside `vigil run`
    MIN=$2
    LOG=$3
    WAIT=60 # minutes to wait for the lid to close
    start=$(date +%s)
    closed_at=""
    while :; do
        line held
        now=$(date +%s)
        if [ "$(lid)" = closed ]; then
            [ -z "$closed_at" ] && closed_at=$now
            [ $((now - closed_at)) -ge $((MIN * 60)) ] && break
        elif [ -n "$closed_at" ]; then
            echo "$(date +%T) the lid opened after $((now - closed_at)) s closed; the count starts again" >> "$LOG"
            closed_at=""
        fi
        if [ -z "$closed_at" ] && [ $((now - start)) -ge $((WAIT * 60)) ]; then
            echo "$(date +%T) the lid never stayed closed; giving up" >> "$LOG"
            break
        fi
        sleep 10
    done
    exit 0
fi

MIN=${1:-11}
LOG=${2:-$HOME/vigil-lid-test.log}
VIGIL=$(command -v vigil || echo "$HOME/Applications/Vigil.app/Contents/MacOS/vigil")
: > "$LOG"
echo "$(date +%T) start: holding until the lid has stayed closed for $MIN min" >> "$LOG"
"$VIGIL" run --reason "lid test" -- "$0" --held "$MIN" "$LOG" 2>> "$LOG"
echo "$(date +%T) hold released; logging 5 more minutes without a hold" >> "$LOG"
i=0
while [ $i -lt 30 ]; do
    line unheld
    sleep 10
    i=$((i + 1))
done
echo "$(date +%T) done" >> "$LOG"
