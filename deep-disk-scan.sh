#!/usr/bin/env bash
#
# deep-disk-scan.sh
# Deep, privileged scan of the APFS Data volume to fully account for used space.
# Writes a timestamped report into ./.output/ (gitignored) so the result can be
# reviewed without exposing local paths in the repository.
#
# It needs sudo to read system areas such as /private/var. You will be asked
# for your password once.
#
# Usage:
#   ./deep-disk-scan.sh            # writes .output/deep-disk-scan-<timestamp>.txt
#
# Read-only: this script only measures. It never deletes or modifies anything.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/.output"
mkdir -p "$OUT_DIR"
STAMP="$(date '+%Y%m%d-%H%M%S')"
OUT="$OUT_DIR/deep-disk-scan-$STAMP.txt"

DATA="/System/Volumes/Data"

# Confirm sudo up front (single prompt), so the long scan runs uninterrupted.
echo "This scan needs administrator rights to read system areas (e.g. /private/var)."
echo "You will be prompted for your password once."
sudo -v

{
  echo "==================================================================="
  echo " Deep Disk Scan (APFS Data volume)"
  echo " Host:  $(scutil --get ComputerName 2>/dev/null || hostname)"
  echo " macOS: $(sw_vers -productVersion 2>/dev/null) ($(sw_vers -buildVersion 2>/dev/null))"
  echo " Date:  $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "==================================================================="
  echo

  echo "===== 1) TOP OF DATA VOLUME (level 1) ====="
  sudo du -sh -x "$DATA"/* 2>/dev/null | sort -rh | head -25
  echo

  echo "===== 2) /private/var breakdown (system logs/caches/db) ====="
  sudo du -sh -x "$DATA/private/var"/* 2>/dev/null | sort -rh | head -20
  echo

  echo "===== 3) ALL USERS in /Users ====="
  sudo du -sh -x "$DATA/Users"/* 2>/dev/null | sort -rh
  echo

  echo "===== 4) LARGEST DIRECTORIES ON THE WHOLE DATA VOLUME (>2GB, depth<=6) ====="
  sudo du -h -x -d 6 "$DATA" 2>/dev/null \
    | awk '$1 ~ /[0-9]G$/ && ($1+0)>=2 {print}' | sort -rh | head -50
  echo

  echo "===== 5) TOTAL RECONCILIATION (df + diskutil) ====="
  df -h "$DATA" | awk 'NR==1 || /Data/'
  echo
  diskutil info "$DATA" 2>/dev/null | grep -iE "Volume Used|Volume Free|Purgeable|Container Free"
  echo

  echo "===== 6) APFS PER-VOLUME (real accounting) ====="
  diskutil apfs list 2>/dev/null

  echo
  echo "Scan complete."
} > "$OUT" 2>&1

echo
echo "Done. Report written to:"
echo "  $OUT"
echo
echo "Preview (first lines):"
sed -n '1,20p' "$OUT"
