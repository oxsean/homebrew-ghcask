# ghcask

**English** | [中文](README.zh-CN.md)

`ghcask` is a Homebrew external command (`brew ghcask`) that turns GitHub Release
assets or direct package URLs into locally-generated Homebrew casks. It is for
macOS apps and CLI tools not in the official Homebrew Cask index that ship a
`.dmg`, `.pkg`, `.zip`, a tarball (`.tar.gz`/`.tgz`/`.tar.xz`/`.tar.bz2`/`.tar.zst`),
or a bare executable. A bundled `.app` becomes an `app` cask, a `.pkg` becomes a
`pkg` cask (with a `pkgutil` uninstall when the identifier can be read), and a
single Mach-O executable becomes a `binary` cask (with `manpage` and shell
completions wired up when the archive bundles them next to the binary).

ghcask **never installs apps itself**. It generates a cask, primes Homebrew's
cache, and then delegates `install` / `reinstall` / `upgrade` / `uninstall` to
`brew` — so managed apps behave like any other cask.

Pure Ruby, stdlib only (no gems, no Bundler). macOS only.

## Install

```sh
brew tap oxsean/ghcask
brew ghcask doctor
```

Normal commands create the generated local tap automatically; `brew ghcask init`
is the explicit setup/repair entry point.

## Quick start

```sh
# Latest stable GitHub Release, then install through Homebrew.
brew ghcask install owner/repo

# A direct package URL (the positional argument is the cask name).
brew ghcask install cask-name --url https://example.com/App.dmg

# Full repository URLs and release-tag URLs are accepted.
brew ghcask install https://github.com/owner/repo
brew ghcask install https://github.com/owner/repo/releases/tag/v1.2.3

# Generate the cask without installing (accepts multiple GitHub targets).
brew ghcask generate owner/repo owner/other-repo

# Allow prereleases, or pin a specific version.
brew ghcask install owner/repo --prerelease
brew ghcask install owner/repo --version v1.2.3
# Move a prerelease cask back onto the stable track.
brew ghcask reinstall owner/repo --stable

# Search GitHub for a repo (most-starred first), then install it.
brew ghcask search hosts file manager
# If asset auto-selection is ambiguous, the error lists the candidates — pick one.
brew ghcask install owner/repo --asset '*-arm64.dmg' --arch arm64

# Preview the generated cask and the brew command without writing or installing.
brew ghcask install owner/repo --dry-run

# Disambiguate when a package bundles several apps/binaries.
brew ghcask install owner/repo --app "Example.app"   # or --cmd NAME for a CLI binary

# Override the inferred cask name, or pre-trust the generated cask (-t).
brew ghcask install owner/repo --cask my-name -t

# Machine-readable output for scripts (list and info).
brew ghcask list --json

# Skip macOS quarantine for an unsigned app (-s = --no-quarantine).
brew ghcask install owner/repo -s

# Pass flags ghcask doesn't recognize straight to brew, after `--`.
# Works on install, reinstall, upgrade, and uninstall.
brew ghcask install owner/repo -- --appdir=/Applications --verbose
```

## Commands

| Command | What it does |
| --- | --- |
| `init` | Prepare or repair the generated local tap |
| `generate owner/repo [...]` | Generate cask(s) without installing |
| `install owner/repo [...]` | Generate and install |
| `install cask --url URL` | Generate and install from a direct URL |
| `reinstall cask\|owner/repo [...]` | Reinstall through Homebrew |
| `update` | Refresh all GitHub cask metadata (no upgrade) |
| `upgrade [cask ...]` | Refresh, then let Homebrew upgrade installed apps (`--greedy`: include self-updating casks) |
| `outdated [cask ...]` | Show installed casks behind the latest release (`--all`: every managed cask, installed or not; `--greedy`: include self-updating casks) |
| `list` / `info` | Inspect managed casks (`--json` for machine-readable output) |
| `search QUERY` | Search GitHub repositories, most-starred first (like `brew search`) |
| `pin` / `unpin` | Pin a GitHub cask to a release, or follow its track |
| `uninstall` / `remove` / `rm` | Uninstall and mark the entry uninstalled |
| `cleanup [cask ...]` | Prune stale records, or force-remove a named one |
| `dump` / `restore` | Back up / restore via `Brewghcask.json` |
| `doctor` | Check the external tools ghcask relies on |

Run `brew ghcask --help` for the full option list.

## Quarantine

macOS quarantines downloaded apps; unsigned apps then refuse to launch. ghcask
supports `-s` / `--no-quarantine` on `install` and `reinstall`:

- The chosen policy is stored in the registry, so `upgrade`, `dump`, and `restore`
  all honor it.
- `--no-quarantine` is passed to `brew install`, **and** ghcask strips the
  `com.apple.quarantine` attribute from the app after `install`, `reinstall`, and
  `upgrade`.
- The app path comes from Homebrew's real artifact targets
  (`brew info --cask --json=v2`), so a custom appdir works correctly.
- `--no-quarantine` only changes how ghcask installs an app you trust; it is not a
  blanket Gatekeeper bypass. Only use it for software you trust.

`brew ghcask info <cask>` shows the current `Quarantine: enabled/disabled` state.

## Uninstall / zap

`brew ghcask uninstall <cask>` removes the app through Homebrew. For app casks,
ghcask also generates a `zap` stanza keyed on the app's bundle identifier, so:

```sh
brew ghcask uninstall <cask> --zap
```

quits the app and moves its leftover user files (preferences, caches,
Application Support, …) to the Trash. `--zap` is opt-in and reversible (Trash,
not delete). pkg and binary casks get no `zap` stanza.

## Brew alignment

ghcask tries to behave like native `brew` where it can, and documents where it
deliberately differs:

- `upgrade` skips pinned casks. To move a pinned cask onto its track,
  `unpin` it first, then `upgrade`. `upgrade -f/--force` forwards `--force` to brew
  (overwrite files); it never re-upgrades an already-current cask — that's
  `reinstall --force`.
- `upgrade` reads installed versions in one batch and skips casks already at the
  generated version (more proactive than a raw `brew upgrade` passthrough).
- `--force` re-downloads from the source (and passes `--force` to brew). Without it,
  install/reinstall prefer local: a GitHub cask reuses its registry entry, a direct-URL
  cask reuses Homebrew's cached download when the URL is unchanged. This is broader than
  brew's `--force` (which overwrites the install but keeps the cached download) — ghcask
  folds re-fetching in because it has no `fetch`. `update`/`upgrade` always check the source;
  their `--force` re-fetches even an already-current cask (like `brew update --force`).
- Apps that update themselves (a Sparkle `SUFeedURL` or a bundled
  `Sparkle.framework`) get `auto_updates true`, so `update` / `upgrade` /
  `outdated` skip them unless you pass `--greedy` (like `brew upgrade
  --greedy`). `outdated --all` also lists them; force a one-off refresh
  with `reinstall <cask> --force`.
- `uninstall` / `remove` / `rm` are aliases; if the app is already gone they warn
  and still mark the entry uninstalled.
- `cleanup [cask]` force-removes a named generated cask record; with no argument it
  prunes stale records (deleted cask file / uninstalled / removed by brew).
- `generate` creates the local cask without installing the app. Like `install`,
  it accepts multiple GitHub targets; a direct-URL source takes exactly one target.
- Direct-URL casks cannot be checked for upstream updates, so `update` / `outdated`
  skip them. Replace one with `reinstall <cask> --url NEW_URL`.

## Pinning

Pinning is implicit: a cask is pinned when it has a requested version.
`--version` pins on install/reinstall; `pin` / `unpin` toggle it. The underlying
`latest-stable` / `latest-prerelease` track is always recorded, so `unpin` returns
the cask to that track.

## Backup and restore

```sh
# Old Mac
brew ghcask dump --global --force

# New Mac
brew tap oxsean/ghcask
brew ghcask restore --global --install   # restore + install the missing casks in one pass
```

`restore --install` installs the restored casks that aren't installed yet
(idempotent — already-installed casks are skipped), so a new machine needs one
command instead of a separate `brew bundle` pass. Drop `--install` to only write
the cask definitions. Use `--file PATH` to read or write a custom location instead
of the default `Brewghcask.json` (or `--global`).

`Brewghcask.json` stores generated cask definitions and registry entries (including
the quarantine policy) only — not downloaded packages or installed apps. After a
cask is generated, Brewfile entries can reference it directly:

```ruby
tap "oxsean/ghcask"
cask "ghcask/local/example"
```

## GitHub access

ghcask prefers the GitHub CLI when `gh` is installed and authenticated, and falls
back to anonymous `curl` (or `GH_TOKEN` / `GITHUB_TOKEN`) otherwise. For reliable
access on private repos or to avoid anonymous rate limits:

```sh
gh auth login
export GH_TOKEN=...
```

**Both metadata and asset downloads are authenticated.** Release assets are fetched
with the same backend as the lookup: `gh release download` when `gh` is
authenticated, or the GitHub API asset endpoint with an `Authorization` header when
a token is set. A bare anonymous `curl` only works for public repos.

**Private repositories**: ghcask downloads the asset (authenticated) and primes
Homebrew's cache, so `install` works. The generated cask's `url` is the standard
release URL, which Homebrew can re-fetch only if it has credentials; for a private
repo, a later re-download after `brew cleanup` needs your GitHub auth in the
environment. Re-run `brew ghcask reinstall <cask> --force` to re-prime the cache.
`install --url` pointing at a GitHub-hosted file — a release asset
(`github.com/.../releases/download/...`) or a committed file
(`raw.githubusercontent.com/...`) — is downloaded with your token (from the env
or `gh auth token`), so private files work. A `--url` on any other host uses a
plain curl with no auth (the token is never sent off GitHub).

## Development

```sh
script/test                                   # full Minitest suite
ruby -Ilib -Itest test/install_test.rb        # one test file
ruby -Ilib -Itest test/install_test.rb -n /quarantine/   # filter by name
ruby -c cmd/brew-ghcask                        # syntax check
GHCASK_BREW_REPOSITORY="$(mktemp -d)" ruby cmd/brew-ghcask install cli/cli --dry-run --arch arm64
```

## License

Licensed under the [Apache License 2.0](LICENSE).
