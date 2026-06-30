# frozen_string_literal: true

require "ghcask/commands/archive"
require "ghcask/commands/doctor"
require "ghcask/commands/init"
require "ghcask/commands/install"
require "ghcask/commands/inventory"
require "ghcask/commands/remove"
require "ghcask/commands/upgrade"
require "ghcask/version"

module Ghcask
  # Pure dispatcher: split the subcommand off ARGV, hand the rest to a command
  # handler, return its integer exit code. All parsing/orchestration lives in the
  # handlers.
  class CLI
    HELP = <<~HELP
      ghcask #{VERSION}

      Usage:
        brew ghcask <command> [options]

      Commands:
        init                                      Prepare or repair local generated cask storage
        generate owner/repo [...]                 Generate local casks from GitHub Releases without installing
        generate cask-name --url URL              Generate a local cask from a direct package URL without installing
        install owner/repo [...]                  Generate local casks from GitHub Releases and install them
        install cask-name --url URL               Generate and install a local cask from a direct package URL
        reinstall cask-name|owner/repo [...]      Reinstall managed casks through Homebrew
        update                                    Refresh all local cask metadata without upgrading apps
        upgrade [cask-name ...]                   Refresh local casks and let Homebrew upgrade managed apps
        outdated [cask-name|owner/repo ...]       Show installed casks whose app is behind the latest release
        list                                      List managed casks
        info cask-name|owner/repo                 Show details for one managed cask
        search QUERY                              Search GitHub repositories (most-starred first)
        pin / unpin cask-name|owner/repo          Pin a GitHub cask to its release, or follow its track again
        uninstall, remove, rm cask... [--zap]     Uninstall managed casks (--zap also trashes app data)
        cleanup [cask-name|owner/repo ...]        Remove stale or selected generated cask records
        dump / restore [options]                  Back up / restore generated casks via Brewghcask.json
        doctor [--dry-run]                        Diagnose the external tools ghcask relies on

      Repository formats:
        owner/repo
        https://github.com/owner/repo
        https://github.com/owner/repo/releases/tag/v1.2.3

      Common options:
        -h, --help        Show this help
        -v, --version     Show ghcask version
        -n, --dry-run     Preview supported commands without writing local state

      Install / reinstall options:
        --url URL             Install from a direct .dmg/.pkg/.zip/.tgz/.tar.{gz,xz,bz2,zst} URL (one cask name)
        --asset PATTERN       Select release asset by glob pattern (install only)
        --app NAME            Set .app bundle name explicitly
        --cask CASK           Set generated cask name (install only)
        --name NAME           Set display name
        --cmd NAME            Command name for an installed CLI binary (binary casks only)
        --stable              Select the latest stable release explicitly
        --prerelease          Allow prerelease releases
        --version VERSION     Install and pin a specific release tag or version
        --arch ARCH           Override local architecture
        -s, --no-quarantine   Skip macOS quarantine (strips the xattr after install)
        -t, --trust           Trust the generated local cask after writing it (install only)
        -f, --force           Re-download from the source and pass --force to Homebrew

      Common brew flags forward directly (install, reinstall, upgrade, uninstall):
        -v/--verbose, -d/--debug, -q/--quiet

      Pass any other brew flag straight through after `--`:
        brew ghcask install owner/repo -- --appdir=/Apps --require-sha

      Note: `generate` and `install` accept multiple GitHub targets. `generate`
      creates the local cask without installing the app.

      Without --force, a reinstall reuses Homebrew's cached download when the source
      URL is unchanged; --force always re-downloads. `update`/`upgrade` always check
      the source; their --force re-fetches even an already-current cask.

      Upgrade skips pinned casks. To move a pinned cask onto its track, `unpin` it
      first, then `upgrade`. `upgrade -f/--force` forwards --force to brew (overwrite
      files); it never re-upgrades an already-current cask — use `reinstall --force`.

      Outdated / upgrade options:
        --all       (outdated) Show all local casks, not just installed ones behind the latest
        -g, --greedy  Also include auto_updates casks (like brew's --greedy)

      List / info options:
        --json      Output managed casks (list) or one cask (info) as JSON

      Dump / restore options:
        --file PATH    Use a custom Brewghcask.json path
        --global       Use ~/.homebrew/Brewghcask.json
        -f, --force    Overwrite dump output or restore same-name casks
        --install      (restore) also install restored casks that aren't installed yet
    HELP

    def self.run(argv, stdout: $stdout, stderr: $stderr)
      new(argv, stdout: stdout, stderr: stderr).run
    end

    def initialize(argv, stdout:, stderr:)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
    end

    def run
      command = @argv.shift
      rest = @argv

      case command
      when nil, "help", "-h", "--help"
        @stdout.puts HELP
        0
      when "--version", "-v"
        @stdout.puts "ghcask #{VERSION}"
        0
      when "doctor" then Commands::Doctor.new(rest, **io).run
      when "init" then Commands::Init.new(rest, **io).run
      when "generate" then Commands::Install.new(rest, **io).generate
      when "install" then Commands::Install.new(rest, **io).install
      when "reinstall" then Commands::Install.new(rest, **io).reinstall
      when "update" then Commands::Upgrade.new(rest, **io).update
      when "upgrade" then Commands::Upgrade.new(rest, **io).upgrade
      when "outdated" then Commands::Upgrade.new(rest, **io).outdated
      when "list" then Commands::Inventory.new(rest, **io).list
      when "info" then Commands::Inventory.new(rest, **io).info
      when "search" then Commands::Inventory.new(rest, **io).search
      when "pin" then Commands::Inventory.new(rest, **io).pin
      when "unpin" then Commands::Inventory.new(rest, **io).unpin
      when "uninstall", "remove", "rm" then Commands::Remove.new(rest, **io).uninstall
      when "cleanup" then Commands::Remove.new(rest, **io).cleanup
      when "dump" then Commands::Archive.new(rest, **io).dump
      when "restore" then Commands::Archive.new(rest, **io).restore
      else
        @stderr.puts "Error: Unknown command: #{command}"
        @stderr.puts "Run `brew ghcask --help` for usage."
        1
      end
    end

    private

    def io
      { stdout: @stdout, stderr: @stderr }
    end
  end
end
