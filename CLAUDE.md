# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`ghcask` is a Homebrew external command (`brew ghcask`) that turns GitHub Release assets or direct package URLs into locally-generated Homebrew casks for macOS apps not in the official Cask index. The repo doubles as the distribution tap (`oxsean/ghcask`): `cmd/brew-ghcask` is what `brew` discovers as the `ghcask` subcommand.

Pure Ruby, **stdlib only — no gems, no Bundler, no Rakefile**. This is deliberate: the command must run under whatever Ruby Homebrew provides. macOS-only (uses `hdiutil`, `ditto`, `plutil`, `xattr`, `uname`).

## Commands

```sh
script/test                                   # full Minitest suite
ruby -Ilib -Itest test/install_test.rb        # one test file (both -I flags required)
ruby -Ilib -Itest test/install_test.rb -n /quarantine/   # filter by test name
ruby -c cmd/brew-ghcask                        # syntax-check (CI runs this over all lib/ + test/)

ruby cmd/brew-ghcask --help                    # run the CLI locally without installing the tap
GHCASK_BREW_REPOSITORY="$(mktemp -d)" ruby cmd/brew-ghcask install cli/cli --dry-run --arch arm64
```

`GHCASK_BREW_REPOSITORY` overrides the Homebrew repo path (where the generated tap lives) — essential for running/testing without touching the real Homebrew install. CI (`.github/workflows/test.yml`) runs on macos-latest / Ruby 3.3: `ruby -c` over every file, then `script/test`.

## Architecture

Entry: `cmd/brew-ghcask` → `Ghcask::CLI.run(ARGV)` (`lib/ghcask/cli.rb`). The CLI is a pure dispatcher: it splits off the subcommand and calls a handler in `lib/ghcask/commands/`, returning the handler's integer exit code (0/1).

```
commands/                       one handler per cohesive command group
  base.rb                       DI collaborators, cask resolution, error funnel
  install.rb                    install / generate / reinstall   (materialize pipeline)
  upgrade.rb                    update / upgrade / outdated       (release refresh)
  inventory.rb                  list / info / search / pin / unpin
  remove.rb                     uninstall / remove / rm / cleanup
  archive.rb                    dump / restore  (Brewghcask.json)
  doctor.rb / init.rb           doctor / init

domain
  entry.rb                      Entry: the one definition of the registry schema
  catalog.rb / registry.rb      Catalog (name → Entry) + atomic JSON persistence
  local_tap.rb                  paths of the generated tap
  cask_file.rb                  render an Entry into a Ruby cask file
  homebrew.rb                   Brew: every `brew` interaction + Cache + CaskInfo
  quarantine.rb                 strip com.apple.quarantine from installed paths

sources                         polymorphism that removes url-vs-github branching
  source.rb                     Source base + GithubSource + UrlSource + Resolution

source plumbing
  repo_ref.rb / direct_url.rb   parse owner/repo, GitHub URLs, direct package URLs
  github.rb                     release lookup (gh + curl backends, ReleaseSelector)
  package_format.rb             extension → artifact-type table (one source of truth)
  asset_selector.rb             score release assets for the local arch
  package.rb                    curl download, sha256, app/pkg/binary inference

infra
  command_runner.rb             single Open3 wrapper (capture + which)
  errors.rb                     one Ghcask::Error base; typed subclasses
  release.rb                    Release/Asset structs, strip_v, concise_desc
```

**Command handlers** (`Commands::*`, all subclass `Commands::Base`):
- `Install` — `install`, `generate`, `reinstall`. One pipeline: build a `Source`, then reuse the existing cask or refresh it (resolve → download → infer app → write cask → cache → delegate to brew).
- `Upgrade` — `update`, `upgrade`, `outdated` (`--all` shows every local cask, not just installed-and-behind).
- `Inventory` — `list`, `info`, `search` (GitHub repo keyword search, most-starred first), `pin`, `unpin`.
- `Remove` — `uninstall`/`remove`/`rm` (`--zap` also trashes app data), `cleanup`.
- `Archive` — `dump`, `restore` (`restore --install` provisions restored casks). `Doctor`, `Init`.

`Commands::Base` holds the dependency-injected collaborators (`github:`, `tap:`, `package:`, `runner:`, `brew:`, `quarantine:`), built **lazily** so `doctor` never shells out to resolve the Homebrew repo. It also owns `guard` (the one rescue→`Error: <msg>`→exit-1 funnel) and `resolve_entry`.

**Domain model**:
- `Entry` (`entry.rb`) — the single definition of the registry schema. Every command reads/writes casks through it (`github?`, `url?`, `pinned?`, `quarantine?`), never raw string keys. `to_h`/`from_h` round-trip JSON.
- `Catalog` + `Registry` — `Catalog` is the in-memory `{name => Entry}` map; `Registry` does atomic JSON persistence of it.
- `Source` / `GithubSource` / `UrlSource` (`source.rb`) — **polymorphism that removes url-vs-github branching.** Both expose `resolve`, `download`, `build_entry`, `previewable_without_download?` (GithubSource adds `preview_entry` for the no-download dry-run path); the pipeline branches on `entry.checkable?`, not `source_type`.
- `Homebrew::Brew` (`homebrew.rb`) — **every `brew` interaction in one place**: command building, output streaming, error summarizing, `--json=v2` parsing (`Homebrew::CaskInfo`), the cache move, trust. `Homebrew.repository` resolves the repo path (honors `GHCASK_BREW_REPOSITORY`).
- `Quarantine` (`quarantine.rb`) — strips `com.apple.quarantine` via `xattr` from Homebrew's real artifact paths.
- `PackageFormat` (`package_format.rb`) — the one extension → artifact-type table (`.dmg/.pkg/.zip/.tar.{gz,xz,bz2,zst}/.tgz`). Asset scoring, unpacking, and URL validation all read it; add a format here once.
- `CaskFile`, `LocalTap`, `GitHub` (backends + selector), `AssetSelector`, `Package`, `RepoRef`, `DirectUrl`, `CommandRunner`, `errors.rb`, `release.rb` (`concise_desc`, `strip_v`).

### Key model concepts

- **ghcask delegates installation to brew.** It generates the cask + primes the cache, then shells out to `brew {install,reinstall,upgrade,uninstall} --cask ghcask/local/<name>`. "Install" bugs usually live in cask generation or the delegated command.
- **Two source types** (`Entry#source_type`): `github` and `url`. Branch via the `Source` subclasses and `entry.url?`/`entry.checkable?`, not scattered conditionals. Direct-URL casks can't be update-checked; they're replaced via `reinstall --url`.
- **Three artifact types**, inferred from the package by `Package` and rendered by `CaskFile`: *app* (`.app` → `app` stanza, plus a `zap` block when `bundle_id` is reverse-DNS and `auto_updates true` when Sparkle is detected), *pkg* (`.pkg` → `pkg` + `pkgutil:` uninstall; no zap; quarantine skipped), *binary* (CLI tool → `binary` + optional `target:` from `--cmd`, plus manpage/bash/zsh/fish completion stanzas from `entry.extras`). `entry.pkg?`/`entry.binary?` select the path.
- **One error base.** Everything expected is a `Ghcask::Error` subclass (`errors.rb`); `guard` rescues that single type. Match the actionable, command-naming message style (`Re-run with --app Example.app.`).
- **Pinning is implicit**: a non-empty `requested_version` means pinned. `--version` sets it; `pin`/`unpin` toggle it; `release_policy` (`latest-stable | latest-prerelease | url`) still records the track.
- **`install_state`**: `generated → pending-install → installed`, or `uninstalled`. `cleanup`/`dump` filter stale/uninstalled entries.
- **Quarantine** is install-time only — it is NOT in the cask DSL. `--no-quarantine` is stored on the `Entry`, passed to `brew install`, and then the xattr is stripped after install/reinstall/upgrade. `upgrade` inherits the stored policy. `info` shows it; `doctor` checks `xattr`.
- The `GitHub` client normalizes BOTH `gh` JSON (camelCase) and REST JSON (snake_case) — keep both spellings working in `normalize_release`/`normalize_asset`.

### Brew-alignment notes

**Principle:** mirror native `brew` semantics wherever ghcask can; when a divergence is unavoidable, surface it to the user (a message or annotation) rather than diverging silently.

- No `fetch` command — it would collide with `brew fetch`'s download-only meaning. ghcask's verb for "create the cask without installing" is `generate`.
- `--force` means **re-fetch from the source**: it skips ghcask's cache/entry reuse so the package is re-downloaded, and it forwards `--force` to brew. This is broader than brew's own `--force` (which overwrites the install but keeps the cached download) — ghcask folds re-fetching in because it has no `fetch`. Without `--force`, install/reinstall prefer local: GitHub casks reuse the registry entry, direct-URL casks reuse Homebrew's cached download when the URL is unchanged (the cache is keyed by `SHA256(url)`). `update`/`upgrade` always query the source for a newer release; their `--force` re-fetches even an already-current cask (bypasses the "already current" skip, like `brew update --force`).

## Conventions

- Every file starts with `# frozen_string_literal: true`.
- **Dependency injection is the testing seam**: handlers take `github:`/`tap:`/`package:`/`runner:`/`brew:`/`quarantine:`. Tests inject fakes from `test/support/fakes.rb` and point the tap at a tmpdir via `GhcaskTest::Case`. Preserve these constructor params when refactoring.
- External processes go through `CommandRunner` (`Open3.capture3` wrapper). The one exception is `Package#download`'s progress-bar curl, which needs the TTY.
- Tests subclass `GhcaskTest::Case` (`test/test_helper.rb`), which provides `tap`, captured IO (`stdout`/`stderr`), and `entry`/`url_entry`/`release`/`seed` builders.
