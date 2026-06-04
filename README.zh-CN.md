# ghcask

## 文档

- [English README](README.md)

`ghcask` 是一个 Homebrew 外部命令，用来把 GitHub Release asset 或直接 package URL 转换成本地 Homebrew cask。它适合那些发布了 `.dmg`、`.zip`、`.tar.gz` 或 `.tgz`，但还没有进入官方 Homebrew Cask 索引的 macOS 应用。

## 为什么需要 ghcask？

- 让更多 Mac 应用进入你的 Homebrew 工作流，即使它们还没有进入官方 Homebrew Cask 索引，或者下载地址并不在 GitHub 上。
- 告别反复打开 release 页面、手动下载、拖拽安装，用一个熟悉的命令完成安装。
- 日常 app 管理保持统一：安装、更新、重新安装、查看信息、移除和清理都可以在终端完成。
- 需要尝鲜时可以选择 prerelease，追求稳定时可以固定到确定版本，准备好后再切回保存的 release 轨道。
- 通过 `Brewghcask.json` 和 Brewfile 友好的 cask 条目，把同一套 app 配置带到另一台 Mac。
- 不必等待公开 cask 审核，也不必发布个人 cask 定义，自己的工具链自己掌控。

## 安装

```sh
brew tap oxsean/ghcask
brew ghcask doctor
```

`brew ghcask init` 保留为显式修复或准备命令；正常命令会自动创建本地 generated tap。

## 快速开始

```sh
# 安装最新稳定版 GitHub Release，并通过 Homebrew 安装 app。
brew ghcask install owner/repo

# 从直接 .dmg、.zip、.tar.gz 或 .tgz package URL 安装。
brew ghcask install cask-name --url https://example.com/downloads/App.dmg

# 也支持完整 GitHub 仓库地址。
brew ghcask install https://github.com/owner/repo

# GitHub release tag URL 会安装这个指定 release。
brew ghcask install https://github.com/owner/repo/releases/tag/v1.2.3

# 只生成本地 cask，不安装 app。
brew ghcask install owner/repo --no-install

# 允许选择 prerelease 版本。
brew ghcask install owner/repo --prerelease

# 安装指定 GitHub Release tag 或版本。
brew ghcask install owner/repo --version v1.2.3

# 指定 GitHub 版本会默认 pin；用 cask name 取消 pin 后继续跟随保存的 release 轨道。
brew ghcask unpin cask-name
brew ghcask unpin owner/repo

# 为直接 URL source 显式设置 cask 版本。
brew ghcask install cask-name --url https://example.com/App.dmg --version 1.2.3
```

## 工作方式

对 GitHub 仓库，`ghcask` 会：

1. 找到选中的 GitHub Release；
2. 根据本机架构选择 macOS `.dmg`、`.zip`、`.tar.gz` 或 `.tgz` asset；
3. 下载 asset 并计算 `sha256`；
4. 尽可能推导 `.app` bundle；
5. 把生成的 cask 写入本地 generated tap；
6. 把下载好的安装包移动到 Homebrew cask cache；
7. 把安装、重新安装、升级和卸载交给 Homebrew。

如果本地已经存在同名 generated cask，`install` 会使用已有本地 cask，并跳过 GitHub 查询。需要刷新 GitHub Release 元数据时使用 `update`。

对直接 package URL，`ghcask` 会：

1. 校验 URL 是否指向 `.dmg`、`.zip`、`.tar.gz` 或 `.tgz`；
2. 下载安装包并计算 `sha256`；
3. 尽可能推导 `.app` bundle 和版本；
4. 写入带有 `source_type: url` 的 generated cask；
5. 把下载好的安装包移动到 Homebrew cask cache；
6. 把安装和重新安装交给 Homebrew。

直接 URL source 无法自动检查上游是否有新版本。要把直接 URL cask 切换到新的安装包，使用带新 URL 的 `reinstall`。

## 命令

```sh
# 准备或修复本地 generated cask 存储。
brew ghcask init

# 从 GitHub Releases 生成 cask 并安装。
brew ghcask install owner/repo

# 从直接 package URL 生成 cask 并安装。
brew ghcask install cask-name --url https://example.com/downloads/App.dmg

# 刷新本地 cask metadata，不升级已安装 app。
brew ghcask update

# 刷新本地 cask，并让 Homebrew 升级已安装的托管 app。
brew ghcask upgrade

# 清除某个 GitHub cask 的 pinned 版本，并按保存的 release 轨道升级。
brew ghcask upgrade cask-name --force

# 查看哪些托管 cask 有新的 GitHub Release。
brew ghcask outdated

# 对 pinned cask，也按保存的 release 轨道检查是否更新。
brew ghcask outdated --all

# 用 cask name 固定或取消固定 GitHub cask 的更新策略。
brew ghcask pin cask-name
brew ghcask unpin cask-name
brew ghcask pin owner/repo
brew ghcask unpin owner/repo

# 列出本地托管的 cask。
brew ghcask list

# 查看 source、仓库或 package URL、release policy、asset、sha256、cask 和安装信息。
brew ghcask info cask-name
brew ghcask info owner/repo

# 通过 Homebrew 重新安装某个托管 cask。
brew ghcask reinstall cask-name
brew ghcask reinstall owner/repo

# 把 GitHub cask 固定到指定 release，并重新安装。
brew ghcask reinstall owner/repo --version v1.2.3
brew ghcask reinstall https://github.com/owner/repo/releases/tag/v1.2.3

# 把 GitHub cask 切到 prerelease 或 stable release 轨道，并重新安装。
brew ghcask reinstall cask-name --prerelease
brew ghcask reinstall cask-name --stable

# 替换直接 URL source，并重新安装 app。
brew ghcask reinstall cask-name --url https://example.com/downloads/App-2.0.0.dmg

# 通过 Homebrew 卸载 app，并移除 generated metadata。
brew ghcask uninstall cask-name
brew ghcask uninstall owner/repo

# 只移除 ghcask 元数据，保留已安装 app。
brew ghcask uninstall cask-name --keep-installed

# 预览 uninstall，不修改本地状态。
brew ghcask uninstall cask-name --dry-run

# 清理 cask 文件已删除，或已被 Homebrew 原生命令卸载后的 stale 记录。
brew ghcask cleanup

# 预览 cleanup 会清理哪些记录，不修改 registry。
brew ghcask cleanup --dry-run

# 导出生成的 Casks/*.rb 和 ghcask.json 到 ./Brewghcask.json。
brew ghcask dump

# 导出到自定义路径或全局 ghcask JSON dump 路径。
brew ghcask dump --file ~/Backup/Brewghcask.json --force
brew ghcask dump --global --force

# 从 ./Brewghcask.json 恢复本地 generated cask 状态。
brew ghcask restore

# 从自定义路径或全局 ghcask JSON dump 路径恢复。
brew ghcask restore --file ~/Backup/Brewghcask.json --force
brew ghcask restore --global --force

# 预览 restore 结果，不写入本地状态。
brew ghcask restore --dry-run

# 诊断 Homebrew、GitHub 访问和本地 generated cask 状态。
brew ghcask doctor
```

## 选项

### Install 选项

- `--url URL`：直接从 `.dmg`、`.zip`、`.tar.gz` 或 `.tgz` package URL 安装。使用这个模式时，位置参数必须是 cask 名称。
- `--asset PATTERN`：用 glob pattern 选择 release asset。
- `--app NAME`：显式设置 `.app` bundle 名称。
- `--cask CASK`：设置生成的 cask 名称。
- `--name NAME`：设置显示名称。
- `--prerelease`：允许选择 prerelease 版本。
- `--version VERSION`：安装指定 GitHub Release tag 或版本。
- `--arch ARCH`：覆盖本机架构推导。直接 URL 模式下只记录为 metadata，不会改变 package URL。
- `--dry-run`：展示选中的 release/asset metadata，以及 write/trust/cache/install 动作计划，不写文件、不安装。直接 URL dry-run 可能会下载到临时目录用于计算 checksum 和推导 app，但不会写 cask、更新 registry、缓存 package 或安装。
- `--no-install`：只生成本地 cask，不安装。
- `--trust`：写入生成的本地 cask 后立即执行 `brew trust --cask`。这是 Homebrew tap trust，不是绕过 macOS Gatekeeper quarantine。

直接 URL install 中，`--asset`、`--cask` 和 `--prerelease` 是 GitHub-only 选项，会被拒绝。

### Update 选项

- `--dry-run`：展示刷新计划，不写文件、不升级 app。

直接 URL cask 在 `update` 时会跳过 source refresh。要替换直接 URL source，使用 `brew ghcask reinstall cask-name --url NEW_URL`。

### Upgrade 选项

- `--dry-run`：展示刷新和升级计划，不写文件、不升级 app。
- `--force`：升级前清除一个显式指定的 GitHub cask 的 pinned 版本，并按保存的 release 轨道升级。

直接 URL cask 在 `upgrade` 时交给 Homebrew 处理。`upgrade --force` 只适用于 GitHub source。
在交给 Homebrew 前，`upgrade` 会批量读取已安装 cask 版本；如果已安装版本和生成的 cask version 一致，就会跳过这个 cask。

### Outdated 选项

- `--all`：对 pinned cask，也按保存的 release 轨道比较。

直接 URL cask 默认跳过。使用 `--all` 时，会显示为 not checkable。

### Pin 和 Unpin

- `pin cask-name|owner/repo`：让 GitHub cask 在 `update` 和 `upgrade` 时保持当前 generated release。
- `unpin cask-name|owner/repo`：清除 pinned release，让 GitHub cask 继续跟随保存的 release 轨道。

用 `--version` 安装或重新安装 GitHub cask 会通过设置 `requested_version` 自动 pin；`release_policy` 继续保存 stable 或 prerelease 轨道。直接 URL cask 不使用 pinning；要替换它，使用 `reinstall cask-name --url NEW_URL`。

### Reinstall 选项

- `--url URL`：重新安装前替换直接 package URL。
- `--app NAME`：刷新 metadata 时，显式设置 `.app` bundle 名称。
- `--name NAME`：刷新 metadata 时，设置显示名称。
- `--version VERSION`：对 GitHub source，选择并固定到指定 release 后重新安装。和 `--url` 一起使用时，覆盖直接 URL package 的推导版本。
- `--prerelease`：把 GitHub cask 切到最新 prerelease 策略，刷新并重新安装。
- `--stable`：把 GitHub cask 切到最新 stable 策略，刷新并重新安装。
- `--arch ARCH`：刷新 metadata 时，覆盖架构元数据。直接 URL 模式下只记录为 metadata，不会改变 package URL。
- `--force`：把 `--force` 传给 Homebrew reinstall，用于覆盖已有 artifacts。
- `--dry-run`：预览 Homebrew reinstall 命令。和 `--version`、`--prerelease`、`--stable`、GitHub tag URL 或 `--url` 一起使用时，预览刷新后的 metadata，不写文件、不缓存 package、不重新安装。

`--version`、`--prerelease` 和 `--stable` 互斥。不带这些选项、GitHub tag URL 或 `--url` 时，`reinstall` 使用现有生成的 cask，不刷新 source metadata。

### Uninstall 选项

- `--keep-installed`：只移除 ghcask metadata 和生成的 cask 文件，不卸载 app。
- `--dry-run`：预览 uninstall，不移除 app、metadata 或生成的 cask 文件。

### Dump 和 Restore 选项

- `--file PATH`：使用自定义 `Brewghcask.json` 路径。
- `--global`：使用 `~/.homebrew/Brewghcask.json`。
- `--force`：覆盖 dump 输出，或 restore 时覆盖同名 cask。
- `--dry-run`：预览 dump 或 restore，不写入本地状态。

## 备份与恢复

最简单的跨机器备份方式：在旧机器导出 generated cask 和 registry，在新机器先恢复它们，再执行 `brew bundle`：

```sh
# 旧机器
brew ghcask dump --global --force

# 新机器
brew tap oxsean/ghcask
brew ghcask restore --global
brew trust --tap oxsean/ghcask
brew bundle
```

`Brewghcask.json` 只保存生成的 cask 定义和 metadata，不包含下载好的安装包、已安装的 app bundle 或 Homebrew cache。

## GitHub 访问

`ghcask` 会优先使用已经安装并登录的 GitHub CLI。如果 `gh` 不存在或未登录，会回退到 `curl`。

公开仓库可以匿名访问 GitHub API，但匿名访问的 rate limit 更低。为了更稳定，可以使用：

```sh
gh auth login
export GH_TOKEN=...
export GITHUB_TOKEN=...
```

`ghcask` 不会调用 `gh auth status --show-token`。

## 本地数据和 Brewfile

生成的 cask 和 registry 元数据会保存在本地 generated tap：

```text
$(brew --repository)/Library/Taps/ghcask/homebrew-local/
```

distribution tap 会保持干净。

生成 cask 后，Brewfile 可以直接引用它：

```ruby
tap "oxsean/ghcask"
cask "ghcask/local/example"
```

在新机器上，先恢复 generated cask，再执行 `brew bundle`：

```sh
brew tap oxsean/ghcask
brew trust --tap oxsean/ghcask
brew ghcask restore --global
brew bundle
```

`brew ghcask dump` 会把生成的 `Casks/*.rb` 文件和 `ghcask.json` 导出成 `Brewghcask.json`。导出前会应用和 `cleanup` 相同的 stale 记录过滤。`restore` 会恢复 dump 中的条目；`--force` 会覆盖同名 cask。

## 开发 QA

```sh
script/test
ruby cmd/brew-ghcask --help
ruby cmd/brew-ghcask doctor --dry-run
GHCASK_BREW_REPOSITORY="$(mktemp -d)" ruby cmd/brew-ghcask install cli/cli --dry-run --arch arm64
```

## 许可证

本项目基于 [Apache License 2.0](LICENSE) 许可发布。
