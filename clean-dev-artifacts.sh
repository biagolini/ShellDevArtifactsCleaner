#!/usr/bin/env bash
#
# clean-dev-artifacts.sh
# Reclaims disk space by removing recreatable development artifacts from a list
# of target directories provided in an external configuration file.
#
# Artifacts removed:
#   - .terraform         Terraform provider cache/plugins (rebuilt by 'terraform init')
#   - node_modules       npm dependencies (rebuilt by 'npm install')
#   - .angular           Angular CLI cache (rebuilt on the next build)
#   - Python virtualenvs detected by a 'pyvenv.cfg' file at the folder root
#   - __pycache__ / .pytest_cache / .mypy_cache / .ruff_cache  Python caches
#
# Safety notes:
#   - Virtualenvs are detected by the presence of 'pyvenv.cfg', which avoids
#     false positives such as 'node_modules/.../env' that are library code.
#   - 'find -prune' stops the scan from descending into a folder already marked
#     for removal, so caches nested inside node_modules/venv are not listed twice.
#   - The script is dry-run by default. It only deletes with the '--apply' flag,
#     and even then it asks for an explicit confirmation.
#
# Usage:
#   ./clean-dev-artifacts.sh                 # dry-run using ./targets.conf
#   ./clean-dev-artifacts.sh --apply         # delete (asks for confirmation)
#   ./clean-dev-artifacts.sh -c custom.conf  # use a custom config file
#   ./clean-dev-artifacts.sh --config custom.conf --apply
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/targets.conf"
APPLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)
      APPLY=true
      shift
      ;;
    -c|--config)
      CONFIG_FILE="${2:-}"
      if [[ -z "$CONFIG_FILE" ]]; then
        echo "ERROR: $1 requires a file path argument." >&2
        exit 1
      fi
      shift 2
      ;;
    -h|--help)
      grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      echo "Try: $0 --help" >&2
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Load target directories from the configuration file
# ---------------------------------------------------------------------------
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: configuration file not found: $CONFIG_FILE" >&2
  echo "Create it from the template: cp targets.conf.example targets.conf" >&2
  exit 1
fi

# Read non-empty, non-comment lines. Support '~' and environment variables.
ROOTS=()
while IFS= read -r raw || [[ -n "$raw" ]]; do
  # Strip leading/trailing whitespace.
  line="$(printf '%s' "$raw" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  # Skip blank lines and comments.
  [[ -z "$line" || "$line" == \#* ]] && continue
  # Expand a leading '~' to $HOME.
  line="${line/#\~/$HOME}"
  # Expand environment variables such as $HOME embedded in the path.
  line="$(eval printf '%s' "\"$line\"")"
  ROOTS+=("$line")
done < "$CONFIG_FILE"

if [[ ${#ROOTS[@]} -eq 0 ]]; then
  echo "ERROR: no target directories defined in $CONFIG_FILE" >&2
  exit 1
fi

# Validate that every configured directory exists.
VALID_ROOTS=()
echo "Target directories:"
for root in "${ROOTS[@]}"; do
  if [[ -d "$root" ]]; then
    echo "  [ok]      $root"
    VALID_ROOTS+=("$root")
  else
    echo "  [missing] $root  (skipped)"
  fi
done
echo

if [[ ${#VALID_ROOTS[@]} -eq 0 ]]; then
  echo "ERROR: none of the configured directories exist. Nothing to do." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Collect removal targets across all valid roots
# ---------------------------------------------------------------------------
TARGETS=()
add_target() { [[ -n "$1" ]] && TARGETS+=("$1"); }

for ROOT in "${VALID_ROOTS[@]}"; do
  # 1) node_modules, .terraform, .angular (pruned: we do not descend into them)
  while IFS= read -r line; do
    add_target "$line"
  done < <(
    find "$ROOT" -type d \( -name node_modules -o -name .terraform -o -name .angular \) -prune -print 2>/dev/null
  )

  # 2) real Python virtualenvs: folders that contain a 'pyvenv.cfg' file
  while IFS= read -r cfg; do
    add_target "$(dirname "$cfg")"
  done < <(
    find "$ROOT" -type f -name pyvenv.cfg 2>/dev/null
  )

  # 3) disposable Python caches (pruning the big folders above for speed)
  while IFS= read -r line; do
    add_target "$line"
  done < <(
    find "$ROOT" \
      \( -type d \( -name node_modules -o -name .terraform -o -name .angular \) -prune \) \
      -o \( -type d \( -name __pycache__ -o -name .pytest_cache -o -name .mypy_cache -o -name .ruff_cache \) -print \) \
      2>/dev/null
  )
done

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "No artifacts found to remove."
  exit 0
fi

# ---------------------------------------------------------------------------
# Summarize what will be removed
# ---------------------------------------------------------------------------
TOTAL_KB=0
declare -i N_NODE=0 N_TF=0 N_NG=0 N_VENV=0 N_PYC=0
for dir in "${TARGETS[@]}"; do
  [[ -d "$dir" ]] || continue
  size_kb=$(du -sk "$dir" 2>/dev/null | awk '{print $1}'); size_kb=${size_kb:-0}
  TOTAL_KB=$(( TOTAL_KB + size_kb ))
  case "$dir" in
    */node_modules) N_NODE+=1 ;;
    */.terraform)   N_TF+=1 ;;
    */.angular)     N_NG+=1 ;;
    */__pycache__|*/.pytest_cache|*/.mypy_cache|*/.ruff_cache) N_PYC+=1 ;;
    *) N_VENV+=1 ;;
  esac
done

# Ordered listing (largest first), capped for readability.
LISTING="$(
  for dir in "${TARGETS[@]}"; do
    [[ -d "$dir" ]] || continue
    du -sh "$dir" 2>/dev/null
  done | sort -rh
)"

echo "Artifacts that will be removed (largest first):"
echo "------------------------------------------------------------"
# Use awk (not 'head') to print the first 40 lines. awk reads the whole stream,
# so it never closes the pipe early and cannot trigger SIGPIPE under pipefail.
echo "$LISTING" | awk 'NR<=40'
TOTAL_ITEMS_SHOWN=$(echo "$LISTING" | grep -c '' || true)
if [[ "$TOTAL_ITEMS_SHOWN" -gt 40 ]]; then
  echo "  ... (showing 40 largest of $TOTAL_ITEMS_SHOWN items; total below counts all)"
fi
echo "------------------------------------------------------------"
printf "Breakdown: node_modules=%d  .terraform=%d  .angular=%d  venv=%d  py-cache=%d\n" \
  "$N_NODE" "$N_TF" "$N_NG" "$N_VENV" "$N_PYC"
printf "Total items: %d\n" "${#TARGETS[@]}"
printf "Total to reclaim: %.2f GB\n" "$(echo "$TOTAL_KB/1024/1024" | bc -l)"
echo

# ---------------------------------------------------------------------------
# Apply or stop at dry-run
# ---------------------------------------------------------------------------
if [[ "$APPLY" != true ]]; then
  echo "Dry-run mode. Nothing was removed."
  echo "To delete for real, run: $0 --apply"
  exit 0
fi

read -r -p "Confirm removal of ALL items above? Type 'yes' to proceed: " ANSWER
if [[ "$ANSWER" != "yes" ]]; then
  echo "Cancelled. Nothing was removed."
  exit 0
fi

REMOVED=0
for dir in "${TARGETS[@]}"; do
  [[ -d "$dir" ]] || continue
  if rm -rf "$dir"; then
    REMOVED=$(( REMOVED + 1 ))
  else
    echo "FAILED to remove: $dir" >&2
  fi
done

echo
echo "Done. $REMOVED items removed."
echo "Reminders when you return to each project:"
echo "  - Terraform:     terraform init"
echo "  - Node/Angular:  npm install"
echo "  - Python:        python -m venv .venv  &&  pip install -r requirements.txt"
