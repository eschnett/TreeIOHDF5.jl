#!/bin/bash
# One summary a case of bench/checkpoint_stress.jl, as the old job scripts
# printed it after each case: the case's header, the damaged iterations and
# the ranks that owned the damage, the writes another rank did not see, the
# first BAD and UNSEEN lines, and the first errors. The `[after]` command of
# jobs/checkpoint-stress*.jl, with the job directories as arguments:
#
#     bash bench/stress_summary.sh <job directory>...

for d in "$@"; do
    out=$d/output.log
    echo "=== $(basename "$(dirname "$d")")"
    [ -f "$out" ] || { echo "  no output"; continue; }
    grep -E "^# " "$out"
    echo "  damaged iterations: $(grep '^BAD' "$out" | awk '{print $3}' | sort -u | wc -l);" \
         "ranks: $(grep '^BAD' "$out" | awk '{print $8}' | sort -u | tr '\n' ' ');" \
         "unseen: $(grep -c '^UNSEEN' "$out")"
    grep -E '^(BAD|UNSEEN)' "$out" | head -4 | cut -c1-200
    grep -m3 -E 'ERROR' "$out"
done
true
