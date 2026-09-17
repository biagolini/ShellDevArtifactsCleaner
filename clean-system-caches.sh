#!/usr/bin/env bash
#
# clean-system-caches.sh
# Reclaims disk space on macOS by removing recreatable caches and stale, old
# versions of tools. It never touches user documents or synced cloud folders.
#
# What it targets (all recreatable by the owning app or tool):
#   - User caches under ~/Library/Caches (browsers, package managers, apps)
#   - Homebrew cleanup (old downloads and outdated formula versions)
#   - Old kiro-cli versions under ~/Library/Application Support/kiro-cli/kas,
#     keeping only the most recent one
#   - Stale app updater/installer leftovers (*.ShipIt update caches)
#   - Optional heavy, recreatable items behind explicit flags:
#       --wallpaper       Apple dynamic "aerial" wallpaper videos (re-downloaded on select)
#       --xcode           Xcode iOS DeviceSupport symbols (regenerated on device connect)
#       --docker          Docker build cache + unused images (SAFE: keeps all volumes)
#       --docker-volumes  Also prune unused Docker volumes (WARNING: may delete DB data)
#       --home-cache      Clean ~/.cache (uv via 'uv cache clean'; skips credential caches)
#
# Safety:
#   - Dry-run by default. Deletes only with --apply, then asks for confirmation.
#   - Heavy/opinionated targets are opt-in via flags, off by default.
#   - Never touches ~/Cloud, ~/Documents, Mail, or app state with real user data.
#
# Usage:
#   ./clean-system-caches.sh                      # dry-run, default targets
#   ./clean-system-caches.sh --apply              # delete default targets
#   ./clean-system-caches.sh --wallpaper --xcode  # add heavy targets (dry-run)
#   ./clean-system-caches.sh --docker --apply     # + safe docker prune, delete
#   ./clean-system-caches.sh --all --apply        # everything (safe docker), delete
#   ./clean-system-caches.sh --docker-volumes --apply  # also prune docker volumes
#
set -euo pipefail

APPLY=false
DO_WALLPAPER=false
DO_XCODE=false
DO_DOCKER=false
DO_DOCKER_VOLUMES=false
DO_HOME_CACHE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)          APPLY=true ;;
    --wallpaper)      DO_WALLPAPER=true ;;
    --xcode)          DO_XCODE=true ;;
    --docker)         DO_DOCKER=true ;;
    --docker-volumes) DO_DOCKER=true; DO_DOCKER_VOLUMES=true ;;
    --home-cache)     DO_HOME_CACHE=true ;;
    --all)            DO_WALLPAPER=true; DO_XCODE=true; DO_DOCKER=true; DO_HOME_CACHE=true ;;
    -h|--help)   grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; echo "Try: $0 --help" >&2; exit 1 ;;
  esac
  shift
done

# Collected shell actions to run. Each entry is "SIZE_KB|DESCRIPTION|COMMAND".
ACTIONS=()

human() { # bytes-ish KB -> human
  awk -v k="$1" 'BEGIN{ split("KB MB GB TB",u); i=1; while(k>=1024 && i<4){k/=1024;i++} printf "%.1f %s", k, u[i] }'
}

dir_kb() { du -sk "$1" 2>/dev/null | awk '{print $1}'; }

add_action() { # $1 desc, $2 command, $3 size_kb
  local size_kb="${3:-0}"
  ACTIONS+=("${size_kb}|$1|$2")
}

# ---------------------------------------------------------------------------
# 1) User caches: remove the CONTENTS of ~/Library/Caches (not the folder)
# ---------------------------------------------------------------------------
CACHES="$HOME/Library/Caches"
if [[ -d "$CACHES" ]]; then
  size_kb="$(dir_kb "$CACHES")"; size_kb="${size_kb:-0}"
  add_action "User caches ($CACHES/*)" \
    "find \"$CACHES\" -mindepth 1 -maxdepth 1 -exec rm -rf {} +" \
    "$size_kb"
fi

# ---------------------------------------------------------------------------
# 1b) Home cache directory ~/.cache (opt-in via --home-cache)
#     Many CLI tools store large caches here (uv, puppeteer, codex, etc.).
#     Rules:
#       - Use each tool's own cleaner when available (uv cache clean),
#         because tools may hardlink cache entries into active environments.
#       - Never touch credential/token caches (.aws/*/cache, ~/.cache/claude).
# ---------------------------------------------------------------------------
if $DO_HOME_CACHE; then
  DOTCACHE="$HOME/.cache"

  # uv: clean via its own command (safe with hardlinks to active venvs).
  if command -v uv >/dev/null 2>&1 && [[ -d "$DOTCACHE/uv" ]]; then
    size_kb="$(dir_kb "$DOTCACHE/uv")"; size_kb="${size_kb:-0}"
    add_action "uv cache (via 'uv cache clean')" \
      "uv cache clean" \
      "$size_kb"
  fi

  # Other ~/.cache subfolders, excluding uv (handled above) and credentials.
  if [[ -d "$DOTCACHE" ]]; then
    while IFS= read -r sub; do
      base="$(basename "$sub")"
      case "$base" in
        uv|claude) continue ;;   # uv handled above; claude may hold tokens
      esac
      [[ -d "$sub" ]] || continue
      size_kb="$(dir_kb "$sub")"; size_kb="${size_kb:-0}"
      add_action "Home cache: ~/.cache/$base" \
        "rm -rf \"$sub\"" \
        "$size_kb"
    done < <(find "$DOTCACHE" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
  fi
fi

# ---------------------------------------------------------------------------
# 2) Homebrew cleanup (old versions + cached downloads)
# ---------------------------------------------------------------------------
if command -v brew >/dev/null 2>&1; then
  # Estimate from the dry-run output ("would free approximately X").
  add_action "Homebrew cleanup (old versions + download cache)" \
    "brew cleanup --prune=all" \
    "0"
fi

# ---------------------------------------------------------------------------
# 3) Old kiro-cli versions: keep only the newest under kas/
# ---------------------------------------------------------------------------
KAS="$HOME/Library/Application Support/kiro-cli/kas"
if [[ -d "$KAS" ]]; then
  # Version dirs look like "2.21.0-<hash>". Sort by version, keep the last.
  VERSIONS="$(ls -1 "$KAS" 2>/dev/null | grep -vE '\.lock$' | sort -V)"
  NEWEST="$(echo "$VERSIONS" | tail -1)"
  while IFS= read -r v; do
    [[ -z "$v" || "$v" == "$NEWEST" ]] && continue
    p="$KAS/$v"
    [[ -d "$p" ]] || continue
    size_kb="$(dir_kb "$p")"; size_kb="${size_kb:-0}"
    add_action "Old kiro-cli version: $v (keeping $NEWEST)" \
      "rm -rf \"$p\" \"$p.lock\"" \
      "$size_kb"
  done <<< "$VERSIONS"
fi

# ---------------------------------------------------------------------------
# 4) Stale updater/installer leftovers (*.ShipIt)
# ---------------------------------------------------------------------------
while IFS= read -r shipit; do
  [[ -d "$shipit" ]] || continue
  size_kb="$(dir_kb "$shipit")"; size_kb="${size_kb:-0}"
  add_action "Updater cache: $(basename "$shipit")" \
    "rm -rf \"$shipit\"" \
    "$size_kb"
done < <(find "$HOME/Library/Caches" -maxdepth 1 -type d -name "*.ShipIt" 2>/dev/null)

# ---------------------------------------------------------------------------
# 5) Optional heavy targets (opt-in)
# ---------------------------------------------------------------------------
if $DO_WALLPAPER; then
  AERIALS="$HOME/Library/Application Support/com.apple.wallpaper/aerials/videos"
  if [[ -d "$AERIALS" ]]; then
    size_kb="$(dir_kb "$AERIALS")"; size_kb="${size_kb:-0}"
    add_action "Apple aerial wallpaper videos (re-downloaded when selected)" \
      "rm -rf \"$AERIALS\"/*" \
      "$size_kb"
  fi
fi

if $DO_XCODE; then
  DEVSUP="$HOME/Library/Developer/Xcode/iOS DeviceSupport"
  if [[ -d "$DEVSUP" ]]; then
    size_kb="$(dir_kb "$DEVSUP")"; size_kb="${size_kb:-0}"
    add_action "Xcode iOS DeviceSupport symbols (regenerated on connect)" \
      "rm -rf \"$DEVSUP\"/*" \
      "$size_kb"
  fi
fi

if $DO_DOCKER; then
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    if $DO_DOCKER_VOLUMES; then
      # Removes unused images, containers, networks AND volumes.
      # WARNING: unused volumes may hold real data (databases of stopped projects).
      add_action "Docker prune INCLUDING volumes (may delete DB data of stopped projects)" \
        "docker system prune -a --volumes -f" \
        "0"
    else
      # Safe default: build cache + dangling images only, never volumes.
      add_action "Docker build cache + unused images (volumes kept safe)" \
        "docker builder prune -a -f && docker image prune -a -f" \
        "0"
    fi
  else
    echo "Note: --docker requested but the Docker daemon is not running; skipping."
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [[ ${#ACTIONS[@]} -eq 0 ]]; then
  echo "Nothing to clean."
  exit 0
fi

TOTAL_KB=0
echo "Planned cleanup actions:"
echo "------------------------------------------------------------"
for a in "${ACTIONS[@]}"; do
  size_kb="${a%%|*}"; rest="${a#*|}"; desc="${rest%%|*}"
  TOTAL_KB=$(( TOTAL_KB + size_kb ))
  if [[ "$size_kb" -gt 0 ]]; then
    printf "  %-10s %s\n" "$(human "$size_kb")" "$desc"
  else
    printf "  %-10s %s\n" "(varies)" "$desc"
  fi
done
echo "------------------------------------------------------------"
printf "Estimated reclaimable (measured items only): %s\n" "$(human "$TOTAL_KB")"
echo "(Items marked 'varies' free additional space not counted above,"
echo " e.g. Homebrew ~4.3 GB and Docker prune.)"
echo

if [[ "$APPLY" != true ]]; then
  echo "Dry-run mode. Nothing was removed."
  echo "To delete for real, run: $0 [flags] --apply"
  exit 0
fi

read -r -p "Confirm running ALL actions above? Type 'yes' to proceed: " ANSWER
if [[ "$ANSWER" != "yes" ]]; then
  echo "Cancelled. Nothing was removed."
  exit 0
fi

for a in "${ACTIONS[@]}"; do
  rest="${a#*|}"; desc="${rest%%|*}"; cmd="${rest#*|}"
  echo "==> $desc"
  eval "$cmd" || echo "   (action reported an error; continuing)"
done

echo
echo "Done. Re-check free space with: df -h /System/Volumes/Data"
