# Dev Artifacts Cleaner

**Author:** Carlos Biagolini-Jr.

**LinkedIn:** [https://www.linkedin.com/in/biagolini/](https://www.linkedin.com/in/biagolini/)

**Medium:** [https://medium.com/@biagolini](https://medium.com/@biagolini)

---

## Overview

This repository provides small, dependency-free Bash scripts that reclaim disk space on a macOS developer machine by removing recreatable content, plus read-only tools to understand where the space actually went. There are four scripts:

- `clean-dev-artifacts.sh` removes recreatable development artifacts (Terraform provider caches, `node_modules`, Angular CLI caches, Python virtual environments and caches) from a configurable list of directories.
- `clean-system-caches.sh` removes recreatable macOS user caches and stale, old versions of tools (Homebrew leftovers, old kiro-cli versions, updater caches), with opt-in flags for heavier targets such as package-manager caches (uv, npm), Apple aerial wallpapers, Xcode device-support symbols, and Docker build cache and unused images.
- `disk-usage-report.sh` (read-only) shows the real per-volume APFS usage, because `du` overcounts `/System` due to firmlinks and snapshot block sharing.
- `deep-disk-scan.sh` (read-only, uses sudo) performs a full privileged scan of the Data volume and writes a timestamped report into `.output/`.

The cleanup scripts are dry-run by default, ask for confirmation before deleting, and never touch user documents or synced cloud folders. Wherever a tool ships its own cache cleaner (for example `uv cache clean`, `npm cache clean`, `brew cleanup`), the scripts call it instead of `rm -rf`, which is safer because some tools hardlink cache entries into active environments.

## Quick Start

All scripts live in this repository directory. Start by entering it:

```bash
cd ShellDevArtifactsCleaner
```

Clean macOS caches and old tool versions. Always run without `--apply` first to preview the plan; the dry-run deletes nothing:

```bash
# 1) Preview the full cleanup (Library caches + uv + npm + Homebrew + Docker images):
./clean-system-caches.sh --home-cache --docker

# 2) Run it for real (asks you to type "yes"):
./clean-system-caches.sh --home-cache --docker --apply

# 3) Everything, including wallpapers and Xcode DeviceSupport:
./clean-system-caches.sh --all --apply
```

What each part does, using native commands: `uv cache clean` for the uv cache, `npm cache clean --force` for the npm cache, `brew cleanup -s --prune=all` plus removal of stuck cask installers under Homebrew's `tmp/.caskroom`, and for Docker `docker builder prune -a && docker image prune -a`, which removes build cache and unused images (they are re-downloaded when you next need them) while keeping your volumes intact.

Built-in protections: credential caches (`~/.aws/*/cache`, `~/.cache/claude`) are never touched, Docker volumes are only pruned with the separate `--docker-volumes` flag, and the Claude Desktop sandbox VMs are not touched by this script.

The other scripts in the repository:

```bash
# Remove dev artifacts (.terraform, node_modules, .angular, venvs)
# from the directories listed in targets.conf:
./clean-dev-artifacts.sh            # preview
./clean-dev-artifacts.sh --apply    # run

# Show the real per-volume APFS disk usage (read-only):
./disk-usage-report.sh

# Deep privileged scan (sudo), saved into .output/ (read-only):
./deep-disk-scan.sh
```

## The Problem

Development workspaces accumulate large, disposable artifacts. A single machine with dozens of projects can easily hold tens of gigabytes of `.terraform` provider caches, `node_modules` trees, `.angular` caches, and Python virtualenvs. These directories are trivially recreatable, yet they silently fill the disk until the system slows down or runs out of space.

Deleting them by hand is tedious and risky. A naive `find ... -name env -delete` can also destroy real source code, because names like `env` appear inside dependencies (for example `node_modules/.../env`).

## The Solution

The script scans a list of root directories that you define in an external configuration file and removes only well-known, recreatable artifacts:

- `.terraform` — Terraform provider cache and plugins, rebuilt by `terraform init`.
- `node_modules` — npm dependencies, rebuilt by `npm install`.
- `.angular` — Angular CLI cache, rebuilt on the next build.
- Python virtual environments — detected by the presence of a `pyvenv.cfg` file at the folder root, which avoids false positives such as library folders named `env`.
- `__pycache__`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache` — disposable Python caches.

Two design choices keep it safe. First, it is dry-run by default: it lists everything it would remove, with per-item sizes and a total, and only deletes when you pass `--apply` and then type an explicit confirmation. Second, it uses `find -prune` so the scan never descends into a folder already marked for removal, which keeps the run fast and prevents double counting.

The list of directories to clean lives in `targets.conf`, which is intentionally excluded from version control through `.gitignore`. This keeps machine-specific, potentially private paths out of the repository. A `targets.conf.example` template is committed so anyone cloning the repository knows the expected format.

## Repository Structure

```
.
├── clean-dev-artifacts.sh    # Removes dev artifacts from configured directories
├── clean-system-caches.sh    # Removes macOS caches and old tool versions
├── disk-usage-report.sh      # Read-only: real per-volume APFS usage
├── deep-disk-scan.sh         # Read-only (sudo): full Data-volume scan to .output/
├── targets.conf.example      # Template listing the directories to scan
├── targets.conf              # Your local, gitignored copy (create from the example)
├── .gitignore
└── README.md
```

## Configuration

Create your local configuration from the template and edit it with your own paths:

```bash
cp targets.conf.example targets.conf
```

Each line is one directory. Blank lines and lines starting with `#` are ignored. A leading `~` and environment variables such as `$HOME` are expanded. Directories that do not exist are reported and skipped rather than causing an error.

```
~/projects/
$HOME/work/repositories/
/absolute/path/to/another/workspace/
```

## Usage

The script never deletes anything unless you explicitly ask it to.

Preview what would be removed (dry-run, the default):

```bash
./clean-dev-artifacts.sh
```

Delete for real. The script prints the full plan and then asks you to type `yes`:

```bash
./clean-dev-artifacts.sh --apply
```

Use a configuration file other than the default `targets.conf`:

```bash
./clean-dev-artifacts.sh --config /path/to/other.conf
./clean-dev-artifacts.sh --config /path/to/other.conf --apply
```

Show the built-in help:

```bash
./clean-dev-artifacts.sh --help
```

Make sure the script is executable after cloning:

```bash
chmod +x clean-dev-artifacts.sh
```

## System Caches Cleaner

`clean-system-caches.sh` targets recreatable macOS user caches and stale, old versions of tools. Like the other script, it is dry-run by default and only deletes with `--apply` after an explicit confirmation.

Default targets (safe, recreatable):

- Everything under `~/Library/Caches` (browsers, package managers, app caches).
- `brew cleanup -s --prune=all` (old formula versions, cached downloads, scrollback) and stuck cask installers under Homebrew's `tmp/.caskroom`.
- Old kiro-cli versions under `~/Library/Application Support/kiro-cli/kas`, keeping only the newest.
- Updater/installer leftovers (`*.ShipIt` caches).

Opt-in heavy targets, off by default:

- `--home-cache` cleans `~/.cache` and other package-manager caches using each tool's own command when available: `uv cache clean` for uv and `npm cache clean --force` for npm. Credential caches (`~/.aws/*/cache`, `~/.cache/claude`) are always skipped.
- `--wallpaper` removes Apple aerial wallpaper videos (re-downloaded when selected).
- `--xcode` removes Xcode iOS DeviceSupport symbols (regenerated on device connect).
- `--docker` prunes Docker build cache and unused images while keeping all volumes safe. Removed images are re-downloaded automatically when you next need them.
- `--docker-volumes` also prunes unused Docker volumes. Use with care: unused volumes may hold databases of stopped projects.
- `--all` enables `--home-cache`, `--wallpaper`, `--xcode`, and the safe `--docker` (it does not enable `--docker-volumes`).

Package managers are cleaned with their native commands rather than raw `rm -rf`, because tools like uv hardlink cache entries into active environments; using the tool's own cleaner avoids breaking live virtualenvs.

Examples:

```bash
./clean-system-caches.sh                       # dry-run, default targets
./clean-system-caches.sh --apply               # delete default targets
./clean-system-caches.sh --home-cache          # preview incl. uv/npm caches
./clean-system-caches.sh --wallpaper --xcode   # preview with heavy targets
./clean-system-caches.sh --all --apply         # everything (safe docker), delete
./clean-system-caches.sh --docker-volumes --apply  # also prune docker volumes
```


The removed artifacts are regenerated the next time you work on a project:

- Terraform: `terraform init`
- Node and Angular: `npm install`
- Python: `python -m venv .venv` followed by `pip install -r requirements.txt`

Your Terraform state is not affected. The `.terraform` directory holds only provider plugins and local cache; local state files such as `terraform.tfstate` live outside it, and remote state is untouched.

## Compatibility

The script is written for Bash and works with the Bash 3.2 that ships with macOS, so it does not rely on `mapfile` or other Bash 4+ features. It uses only standard Unix tools (`find`, `du`, `awk`, `sort`, `bc`).

## References

- [Terraform: Provider Installation and the .terraform directory](https://developer.hashicorp.com/terraform/cli/config/config-file)
- [npm: node_modules folder](https://docs.npmjs.com/cli/v10/configuring-npm/folders)
- [Python: venv and pyvenv.cfg](https://docs.python.org/3/library/venv.html)
