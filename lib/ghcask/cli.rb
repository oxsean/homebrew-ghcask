# frozen_string_literal: true

require "ghcask/doctor"
require "ghcask/archive"
require "ghcask/installer"
require "ghcask/local_tap"
require "ghcask/manager"
require "ghcask/version"

module Ghcask
  class CLI
    HELP = <<~HELP
      ghcask #{VERSION}

      Usage:
        brew ghcask <command> [options]

      Commands:
        init                                      Prepare or repair local generated cask storage
        install owner/repo                        Generate a local cask from GitHub Releases and install it
        install cask-name --url URL               Generate and install a local cask from a direct package URL
        update                                    Refresh all local cask metadata without upgrading apps
        outdated                                  Show managed casks with newer selected releases
        upgrade [cask-name]                       Refresh local casks and let Homebrew upgrade managed apps
        list                                      List managed casks
        info cask-name|owner/repo                 Show details for one managed cask
        reinstall cask-name|owner/repo            Reinstall one managed cask through Homebrew
        reinstall owner/repo --version VERSION    Pin a GitHub cask to a specific release and reinstall it
        reinstall cask-name --url URL             Replace a direct URL source and reinstall the managed cask
        pin cask-name|owner/repo                  Pin a GitHub cask to its current generated release
        unpin cask-name|owner/repo                Follow the saved GitHub release track again
        uninstall cask-name|owner/repo            Uninstall one managed cask and remove generated metadata
        cleanup [--dry-run]                       Remove registry entries for deleted local casks
        dump [options]                            Export generated casks and registry to Brewghcask.json
        restore [options]                         Restore generated casks and registry from Brewghcask.json
        doctor [--dry-run]                        Diagnose local tools and generated cask state

      Repository formats:
        owner/repo
        https://github.com/owner/repo
        https://github.com/owner/repo/releases/tag/v1.2.3

      Options:
        -h, --help    Show this help
        --version     Show ghcask version
        --dry-run     Preview supported commands without writing local state

      Install options:
        --url URL             Install directly from a .dmg, .zip, .tar.gz, or .tgz package URL
        --asset PATTERN       Select release asset by glob pattern
        --app NAME            Set .app bundle name explicitly
        --cask CASK           Set generated cask name
        --name NAME           Set display name
        --prerelease          Allow prerelease releases
        --version VERSION     Install and pin a specific release tag or version
        --arch ARCH           Override local architecture
        --no-install          Generate the local cask without installing
        --trust               Trust the generated local cask after writing it

      Reinstall options:
        --url URL             Replace the direct package URL before reinstalling
        --app NAME            Set .app bundle name explicitly
        --name NAME           Set display name
        --version VERSION     Select and pin a GitHub release or set a direct URL cask version
        --prerelease          Switch a GitHub cask to latest-prerelease and reinstall
        --stable              Switch a GitHub cask to latest-stable and reinstall
        --arch ARCH           Override local architecture metadata
        --force               Pass --force to Homebrew reinstall

      Upgrade options:
        --force    Clear one explicit GitHub cask pin before upgrading

      Outdated options:
        --all    Also compare pinned casks with their saved release track

      Pin and unpin:
        pin      Keep a GitHub cask on its current generated release during update
        unpin    Clear the pinned release and follow the saved release track

      Uninstall options:
        --keep-installed    Remove ghcask metadata without uninstalling the app

      Dump and restore options:
        --file PATH    Use a custom Brewghcask.json path
        --global       Use ~/.homebrew/Brewghcask.json
        --force        Overwrite dump output or restore same-name casks
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

      case command
      when nil, "help", "-h", "--help"
        @stdout.puts HELP
        0
      when "--version"
        @stdout.puts VERSION
        0
      when "doctor"
        Doctor.new(@argv, stdout: @stdout, stderr: @stderr).run
      when "init"
        init
      when "install"
        Installer.new(@argv, stdout: @stdout, stderr: @stderr).run
      when "update"
        Manager.new(@argv, stdout: @stdout, stderr: @stderr).update(upgrade: false)
      when "upgrade"
        Manager.new(@argv, stdout: @stdout, stderr: @stderr).update(upgrade: true)
      when "outdated"
        Manager.new(@argv, stdout: @stdout, stderr: @stderr).outdated
      when "list"
        Manager.new(@argv, stdout: @stdout, stderr: @stderr).list
      when "info"
        Manager.new(@argv, stdout: @stdout, stderr: @stderr).info
      when "reinstall"
        Manager.new(@argv, stdout: @stdout, stderr: @stderr).reinstall
      when "pin"
        Manager.new(@argv, stdout: @stdout, stderr: @stderr).pin
      when "unpin"
        Manager.new(@argv, stdout: @stdout, stderr: @stderr).unpin
      when "uninstall"
        Manager.new(@argv, stdout: @stdout, stderr: @stderr).uninstall
      when "cleanup"
        Manager.new(@argv, stdout: @stdout, stderr: @stderr).cleanup
      when "dump"
        Archive.new(@argv, stdout: @stdout, stderr: @stderr).dump
      when "restore"
        Archive.new(@argv, stdout: @stdout, stderr: @stderr).restore
      else
        @stderr.puts "ghcask: unknown command: #{command}"
        @stderr.puts "Run `brew ghcask --help` for usage."
        1
      end
    end

    private

    def init
      if @argv.include?("-h") || @argv.include?("--help")
        @stdout.puts <<~HELP
          Usage:
            brew ghcask init

          Prepare or repair local generated cask storage.
        HELP
        return 0
      end

      unless @argv.empty?
        @stderr.puts "ghcask init: unknown option #{@argv.first}"
        return 1
      end

      tap = LocalTap.new
      tap.init
      @stdout.puts "Initialized ghcask local tap:"
      @stdout.puts "  tap: #{tap.root}"
      @stdout.puts "  casks: #{tap.casks_dir}"
      @stdout.puts "  registry: #{tap.registry_path}"
      0
    rescue Homebrew::Error, Registry::Error => e
      @stderr.puts "ghcask init: #{e.message}"
      1
    end
  end
end
