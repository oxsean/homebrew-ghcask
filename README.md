# ghcask

## Documentation

- [中文 README](README.zh-CN.md)

`ghcask` is a Homebrew external command that turns GitHub Release assets or direct package URLs into local Homebrew casks. It is for macOS apps that publish `.dmg`, `.zip`, `.tar.gz`, or `.tgz` files but are not available in the official Homebrew Cask index.

## Why ghcask?

- Install more Mac apps with Homebrew, even when they are not listed in the official Homebrew Cask index or GitHub is not their download home.
- Replace release-page hunting, manual downloads, and drag-and-drop installs with one familiar command.
- Keep everyday app management in one workflow: install, update, reinstall, inspect, uninstall, and clean up from the terminal.
- Try prereleases when you need them, pin known-good versions when stability matters, and return to your chosen release track when you are ready.
- Bring your generated app setup to another Mac with `Brewghcask.json` and Brewfile-friendly cask entries.
- Stay in control without waiting for a public cask review or publishing personal cask definitions.

## Install

```sh
brew tap oxsean/ghcask
brew ghcask doctor
```

`brew ghcask init` is available as an explicit repair/setup command, but normal commands create the local generated tap automatically.

## Quick Start

```sh
# Install the latest stable GitHub Release and then install the app through Homebrew.
brew ghcask install owner/repo

# Install from a direct .dmg, .zip, .tar.gz, or .tgz package URL.
brew ghcask install cask-name --url https://example.com/downloads/App.dmg

# Full GitHub repository URLs are accepted.
brew ghcask install https://github.com/owner/repo

# GitHub release tag URLs install that specific release.
brew ghcask install https://github.com/owner/repo/releases/tag/v1.2.3

# Generate the local cask without installing the app.
brew ghcask install owner/repo --no-install

# Allow prerelease releases.
brew ghcask install owner/repo --prerelease

# Install a specific GitHub Release tag or version.
brew ghcask install owner/repo --version v1.2.3

# Specific GitHub versions are pinned by default; unpin by cask name to follow the saved release track again.
brew ghcask unpin cask-name
brew ghcask unpin owner/repo

# Set the cask version explicitly for a direct URL source.
brew ghcask install cask-name --url https://example.com/App.dmg --version 1.2.3
```

## How It Works

For a GitHub repository, `ghcask`:

1. finds the selected GitHub Release;
2. selects a macOS `.dmg`, `.zip`, `.tar.gz`, or `.tgz` asset for the local architecture;
3. downloads the asset and calculates `sha256`;
4. infers the `.app` bundle when possible;
5. writes a generated cask into a local generated tap;
6. moves the downloaded package into Homebrew's cask cache;
7. delegates install, reinstall, upgrade, and uninstall operations to Homebrew.

If the generated cask already exists, `install` uses the existing local cask and skips the GitHub lookup. Use `update` to refresh GitHub release metadata.

For a direct package URL, `ghcask`:

1. validates that the URL points to a `.dmg`, `.zip`, `.tar.gz`, or `.tgz`;
2. downloads the package and calculates `sha256`;
3. infers the `.app` bundle and version when possible;
4. writes a generated cask with `source_type: url`;
5. moves the downloaded package into Homebrew's cask cache;
6. delegates install and reinstall operations to Homebrew.

Direct URL sources are not checkable for newer upstream releases. To switch a direct URL cask to a newer package, run `reinstall` with the new URL.

## Commands

```sh
# Prepare or repair local generated cask storage.
brew ghcask init

# Generate a cask from GitHub Releases and install it.
brew ghcask install owner/repo

# Generate a cask from a direct package URL and install it.
brew ghcask install cask-name --url https://example.com/downloads/App.dmg

# Refresh local cask metadata without upgrading installed apps.
brew ghcask update

# Refresh local casks and let Homebrew upgrade installed managed apps.
brew ghcask upgrade

# Clear one pinned GitHub cask and upgrade it on the saved release track.
brew ghcask upgrade cask-name --force

# Show managed casks with newer selected GitHub releases.
brew ghcask outdated

# Also compare pinned casks with their saved release track.
brew ghcask outdated --all

# Pin or unpin the generated GitHub cask update policy by cask name.
brew ghcask pin cask-name
brew ghcask unpin cask-name
brew ghcask pin owner/repo
brew ghcask unpin owner/repo

# List locally managed casks.
brew ghcask list

# Show source, repository/package URL, release policy, asset, sha256, cask, and install details.
brew ghcask info cask-name
brew ghcask info owner/repo

# Reinstall one managed cask through Homebrew.
brew ghcask reinstall cask-name
brew ghcask reinstall owner/repo

# Pin a GitHub cask to a specific release and reinstall it.
brew ghcask reinstall owner/repo --version v1.2.3
brew ghcask reinstall https://github.com/owner/repo/releases/tag/v1.2.3

# Switch a GitHub cask to the prerelease or stable release track and reinstall it.
brew ghcask reinstall cask-name --prerelease
brew ghcask reinstall cask-name --stable

# Replace a direct URL source and reinstall the app.
brew ghcask reinstall cask-name --url https://example.com/downloads/App-2.0.0.dmg

# Uninstall the app through Homebrew and remove generated metadata.
brew ghcask uninstall cask-name
brew ghcask uninstall owner/repo

# Remove generated metadata while keeping the app installed.
brew ghcask uninstall cask-name --keep-installed

# Preview uninstall without changing local state.
brew ghcask uninstall cask-name --dry-run

# Remove stale ghcask records after deleted cask files or Homebrew uninstall.
brew ghcask cleanup

# Preview cleanup changes without modifying the registry.
brew ghcask cleanup --dry-run

# Export generated Casks/*.rb and ghcask.json to ./Brewghcask.json.
brew ghcask dump

# Export to a custom path or the global ghcask JSON dump path.
brew ghcask dump --file ~/Backup/Brewghcask.json --force
brew ghcask dump --global --force

# Restore generated local cask state from ./Brewghcask.json.
brew ghcask restore

# Restore from a custom path or the global ghcask JSON dump path.
brew ghcask restore --file ~/Backup/Brewghcask.json --force
brew ghcask restore --global --force

# Preview restore changes without writing local state.
brew ghcask restore --dry-run

# Diagnose Homebrew, GitHub access, and local generated cask state.
brew ghcask doctor
```

## Options

### Install Options

- `--url URL`: install directly from a `.dmg`, `.zip`, `.tar.gz`, or `.tgz` package URL. In this mode, the positional argument must be the cask name.
- `--asset PATTERN`: select a release asset by glob pattern.
- `--app NAME`: set the `.app` bundle name explicitly.
- `--cask CASK`: set the generated cask name.
- `--name NAME`: set the display name.
- `--prerelease`: allow prerelease releases.
- `--version VERSION`: install a specific GitHub Release tag or version.
- `--arch ARCH`: override local architecture detection. In direct URL mode, this is recorded as metadata only and does not change the package URL.
- `--dry-run`: show the selected release/asset metadata and write/trust/cache/install actions without writing files or installing. Direct URL dry runs may download to a temporary location for checksum and app inference, but they do not write casks, update the registry, cache packages, or install.
- `--no-install`: generate the local cask without installing.
- `--trust`: run `brew trust --cask` immediately after writing the generated local cask. This is Homebrew tap trust, not macOS Gatekeeper quarantine bypass.

For direct URL installs, `--asset`, `--cask`, and `--prerelease` are GitHub-only options and are rejected.

### Update Options

- `--dry-run`: show the refresh plan without writing files or upgrading apps.

Direct URL casks skip source refresh during `update`. Use `brew ghcask reinstall cask-name --url NEW_URL` to replace a direct URL source.

### Upgrade Options

- `--dry-run`: show the refresh and upgrade plan without writing files or upgrading apps.
- `--force`: clear one explicit GitHub cask's pinned version before upgrading on its saved release track.

Direct URL casks are delegated to Homebrew during `upgrade`. `upgrade --force` is GitHub-only.
Before delegation, `upgrade` reads installed cask versions in a batch and skips casks that already match the generated cask version.

### Outdated Options

- `--all`: also compare pinned casks against their saved release track.

Direct URL casks are skipped by default. With `--all`, they are reported as not checkable.

### Pin and Unpin

- `pin cask-name|owner/repo`: keep a GitHub cask on its current generated release during `update` and `upgrade`.
- `unpin cask-name|owner/repo`: clear the pinned release so the GitHub cask follows its saved release track again.

Installing or reinstalling a GitHub cask with `--version` pins it automatically by setting `requested_version`; `release_policy` continues to store the saved stable or prerelease track. Direct URL casks do not use pinning; replace them with `reinstall cask-name --url NEW_URL`.

### Reinstall Options

- `--url URL`: replace the direct package URL before reinstalling.
- `--app NAME`: set the `.app` bundle name explicitly when refreshing metadata.
- `--name NAME`: set the display name when refreshing metadata.
- `--version VERSION`: for GitHub sources, select and pin a specific release before reinstalling. With `--url`, override the inferred direct URL package version.
- `--prerelease`: switch a GitHub cask to the latest prerelease policy, refresh it, and reinstall it.
- `--stable`: switch a GitHub cask to the latest stable policy, refresh it, and reinstall it.
- `--arch ARCH`: override architecture metadata when refreshing metadata. In direct URL mode, this is recorded as metadata only and does not change the package URL.
- `--force`: pass `--force` to Homebrew reinstall so existing artifacts can be overwritten.
- `--dry-run`: preview the Homebrew reinstall command. With `--version`, `--prerelease`, `--stable`, a GitHub tag URL, or `--url`, preview refreshed metadata without writing files, caching packages, or reinstalling.

`--version`, `--prerelease`, and `--stable` are mutually exclusive. Without one of those, a GitHub tag URL, or `--url`, `reinstall` uses the existing generated cask and does not refresh source metadata.

### Uninstall Options

- `--keep-installed`: remove ghcask metadata and generated cask file without uninstalling the app.
- `--dry-run`: preview uninstall without removing apps, metadata, or generated cask files.

### Dump and Restore Options

- `--file PATH`: use a custom `Brewghcask.json` path.
- `--global`: use `~/.homebrew/Brewghcask.json`.
- `--force`: overwrite dump output or restore same-name casks.
- `--dry-run`: preview dump or restore without writing local state.

## Backup and Restore

For a simple machine-to-machine backup, export the generated casks and registry on the old Mac, then restore them before running `brew bundle` on the new Mac:

```sh
# Old Mac
brew ghcask dump --global --force

# New Mac
brew tap oxsean/ghcask
brew trust --tap oxsean/ghcask
brew ghcask restore --global
brew bundle
```

`Brewghcask.json` stores generated cask definitions and metadata only. It does not include downloaded packages, installed app bundles, or Homebrew's cache.

## GitHub Access

`ghcask` prefers the GitHub CLI when `gh` is installed and authenticated. If `gh` is unavailable or unauthenticated, it falls back to `curl`.

Public repositories can work with anonymous GitHub API calls, but anonymous access has lower rate limits. For more reliable access, use one of:

```sh
gh auth login
export GH_TOKEN=...
export GITHUB_TOKEN=...
```

`ghcask` never calls `gh auth status --show-token`.

## Local Data and Brewfile

Generated casks and registry metadata are stored under the local generated tap:

```text
$(brew --repository)/Library/Taps/ghcask/homebrew-local/
```

The distribution tap stays clean.

After a cask has been generated, Brewfile entries can reference it directly:

```ruby
tap "oxsean/ghcask"
cask "ghcask/local/example"
```

On a new machine, restore generated local casks before running `brew bundle`:

```sh
brew tap oxsean/ghcask
brew ghcask restore --global
brew bundle
```

`brew ghcask dump` exports generated `Casks/*.rb` files and `ghcask.json` into `Brewghcask.json`. It applies the same stale-record filtering as `cleanup`. `restore` restores entries from the dump; `--force` overwrites same-name casks.

## Development QA

```sh
script/test
ruby cmd/brew-ghcask --help
ruby cmd/brew-ghcask doctor --dry-run
GHCASK_BREW_REPOSITORY="$(mktemp -d)" ruby cmd/brew-ghcask install cli/cli --dry-run --arch arm64
```

## License

Licensed under the [Apache License 2.0](LICENSE).
