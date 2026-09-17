#!/usr/bin/env bash
#
# disk-usage-report.sh
# Shows the REAL disk usage on macOS broken down per APFS volume, using the
# APFS accounting from 'diskutil' instead of 'du'.
#
# Why this exists:
#   On modern macOS the disk is one APFS "container" shared by several volumes
#   (System, Data, Preboot, Recovery, VM). Tools like 'du' cross firmlinks and
#   count snapshot-shared blocks multiple times, so 'du /System' can report
#   hundreds of GB that do not physically exist. 'diskutil' reads the real
#   per-volume "Capacity Consumed" from the filesystem metadata, which is the
#   source of truth.
#
# What it reports:
#   - Container total, used, and free (physical truth)
#   - Per-volume consumed capacity with roles (System/Data/Preboot/...)
#   - Purgeable space (space macOS can reclaim on demand; 'df' hides it)
#   - Local APFS snapshots on the boot volume
#
# Usage:
#   ./disk-usage-report.sh
#
# Read-only: this script never modifies anything.
#
set -euo pipefail

# Identify the APFS container backing the boot volume (usually disk3).
# 'APFS Container' from diskutil info gives the container disk directly.
CONTAINER="$(diskutil info / 2>/dev/null | awk -F: '/APFS Container:/ {gsub(/ /,"",$2); print $2}')"
[[ -z "$CONTAINER" ]] && CONTAINER="$(diskutil info / 2>/dev/null | awk -F: '/Part of Whole/ {gsub(/ /,"",$2); print $2}')"
[[ -z "$CONTAINER" ]] && CONTAINER="disk3"

bytes_to_h() { # $1 bytes -> human readable
  awk -v b="$1" 'BEGIN{
    split("B KB MB GB TB",u); i=1;
    while (b>=1024 && i<5){ b/=1024; i++ }
    printf "%.1f %s", b, u[i]
  }'
}

echo "==================================================================="
echo " macOS Disk Usage Report (APFS real accounting)"
echo " Host: $(scutil --get ComputerName 2>/dev/null || hostname)"
echo " macOS: $(sw_vers -productVersion 2>/dev/null) ($(sw_vers -buildVersion 2>/dev/null))"
echo " Date: $(date '+%Y-%m-%d %H:%M:%S %z')"
echo " Container: $CONTAINER"
echo "==================================================================="
echo

# ---------------------------------------------------------------------------
# Container-level totals (physical truth)
# ---------------------------------------------------------------------------
APFS="$(diskutil apfs list "$CONTAINER" 2>/dev/null)"
if [[ -z "$APFS" ]]; then
  echo "ERROR: could not read APFS info for container $CONTAINER." >&2
  echo "Falling back to df:" >&2
  df -h / /System/Volumes/Data 2>/dev/null
  exit 1
fi

CEIL="$(echo "$APFS"  | awk -F'[()]' '/Size \(Capacity Ceiling\)/ {print}' | grep -oE '[0-9]+ B' | head -1 | awk '{print $1}')"
USED="$(echo "$APFS"  | awk '/Capacity In Use By Volumes/ {print}' | grep -oE '[0-9]+ B' | head -1 | awk '{print $1}')"
FREE="$(echo "$APFS"  | awk '/Capacity Not Allocated/ {print}' | grep -oE '[0-9]+ B' | head -1 | awk '{print $1}')"

echo "CONTAINER TOTALS (physical)"
echo "-------------------------------------------------------------------"
printf "  %-28s %s\n" "Total capacity:"  "$(bytes_to_h "${CEIL:-0}")"
printf "  %-28s %s\n" "Used by all volumes:" "$(bytes_to_h "${USED:-0}")"
printf "  %-28s %s\n" "Free (not allocated):" "$(bytes_to_h "${FREE:-0}")"
echo

# ---------------------------------------------------------------------------
# Per-volume breakdown
# ---------------------------------------------------------------------------
echo "PER-VOLUME CONSUMED CAPACITY"
echo "-------------------------------------------------------------------"
printf "  %-10s %-26s %-22s %s\n" "DISK" "NAME" "ROLE / MOUNT" "CONSUMED"
echo "  ---------- -------------------------- ---------------------- ----------"

# Parse the volume blocks. Each volume starts with "APFS Volume Disk (Role)".
echo "$APFS" | awk '
  /APFS Volume Disk \(Role\)/ {
    if (disk != "") print_row();
    # e.g. "disk3s1 (Data)"
    match($0, /disk[0-9]+s[0-9]+/); disk = substr($0, RSTART, RLENGTH);
    match($0, /\(([^)]+)\)[[:space:]]*$/); role = substr($0, RSTART+1, RLENGTH-2);
    name=""; mount=""; consumed="";
    next
  }
  /Name:/                { sub(/^[^:]*:[[:space:]]*/,""); sub(/[[:space:]]*\(Case.*$/,""); name=$0 }
  /Mount Point:/         { sub(/^[^:]*:[[:space:]]*/,""); mount=$0 }
  /Snapshot Mount Point:/{ sub(/^[^:]*:[[:space:]]*/,""); if (mount=="Not Mounted" || mount=="") mount=$0" (snap)" }
  /Capacity Consumed:/   { match($0,/[0-9]+ B/); consumed=substr($0,RSTART,RLENGTH); sub(/ B/,"",consumed) }
  END { if (disk != "") print_row() }
  function human(b,   u,i){ split("B KB MB GB TB",u); i=1; while(b>=1024 && i<5){b/=1024;i++} return sprintf("%.1f %s", b, u[i]) }
  function print_row(){
    mp = (mount=="" ? "-" : mount);
    printf "  %-10s %-26s %-22s %s\n", disk, substr(name,1,26), substr(role" / "mp,1,22), human(consumed+0);
  }
'
echo

# ---------------------------------------------------------------------------
# Purgeable space (df hides it; diskutil shows it)
# ---------------------------------------------------------------------------
echo "PURGEABLE & FREE (boot data volume)"
echo "-------------------------------------------------------------------"
diskutil info /System/Volumes/Data 2>/dev/null \
  | grep -iE "Volume Free Space|Container Free Space|Purgeable" \
  | sed 's/^[[:space:]]*/  /'
echo

# ---------------------------------------------------------------------------
# Local snapshots (can silently hold space)
# ---------------------------------------------------------------------------
echo "LOCAL APFS SNAPSHOTS (/)"
echo "-------------------------------------------------------------------"
SNAPS="$(tmutil listlocalsnapshots / 2>/dev/null | grep -v '^Snapshots for' || true)"
if [[ -z "$SNAPS" ]]; then
  echo "  none (no local Time Machine snapshots holding space)"
else
  echo "$SNAPS" | sed 's/^/  /'
fi
echo

echo "Note: 'du' overcounts /System due to firmlinks and snapshot block"
echo "sharing. The numbers above come from APFS accounting and are the truth."
