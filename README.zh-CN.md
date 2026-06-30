# ghcask

[English](README.md) | **中文**

`ghcask` 是一个 Homebrew 外部命令（`brew ghcask`），把 GitHub Release 资源或直接
的安装包 URL 转换成本地生成的 Homebrew cask。它面向那些不在官方 Homebrew Cask 索引
里、但提供 `.dmg`、`.pkg`、`.zip`、tarball（`.tar.gz`/`.tgz`/`.tar.xz`/`.tar.bz2`/
`.tar.zst`）或裸可执行文件的 macOS 应用和命令行工具。打包的 `.app` 生成 `app` cask，
`.pkg` 生成 `pkg` cask（能读到标识符时附带 `pkgutil` 卸载），单个 Mach-O 可执行文件
生成 `binary` cask（当压缩包里随附 `manpage` 和补全脚本时一并接好）。

ghcask **从不自己安装应用**。它生成 cask、预热 Homebrew 缓存，然后把 `install` /
`reinstall` / `upgrade` / `uninstall` 委托给 `brew`，因此被管理的应用和普通 cask 行为一致。

纯 Ruby，仅用标准库（无 gem、无 Bundler）。仅限 macOS。

## 安装

```sh
brew tap oxsean/ghcask
brew ghcask doctor
```

普通命令会自动创建本地生成的 tap；`brew ghcask init` 是显式的初始化/修复入口。

## 快速开始

```sh
# 最新稳定版 GitHub Release，然后通过 Homebrew 安装。
brew ghcask install owner/repo

# 直接的安装包 URL（位置参数是 cask 名）。
brew ghcask install cask-name --url https://example.com/App.dmg

# 支持完整仓库 URL 和 release tag URL。
brew ghcask install https://github.com/owner/repo
brew ghcask install https://github.com/owner/repo/releases/tag/v1.2.3

# 只生成 cask 而不安装（可接受多个 GitHub 目标）。
brew ghcask generate owner/repo owner/other-repo

# 允许预发布版，或锁定指定版本。
brew ghcask install owner/repo --prerelease
brew ghcask install owner/repo --version v1.2.3
# 把预发布 cask 切回稳定轨道。
brew ghcask reinstall owner/repo --stable

# 在 GitHub 上按 star 搜索仓库，然后安装。
brew ghcask search hosts file manager
# 资产自动选择有歧义时，错误信息会列出候选——用 --asset 挑一个。
brew ghcask install owner/repo --asset '*-arm64.dmg' --arch arm64

# 预览将生成的 cask 和 brew 命令，但不写入也不安装。
brew ghcask install owner/repo --dry-run

# 当压缩包内含多个应用/可执行文件时用于消歧。
brew ghcask install owner/repo --app "Example.app"   # CLI 工具用 --cmd NAME

# 覆盖推断出的 cask 名，或预先 trust 生成的 cask（-t）。
brew ghcask install owner/repo --cask my-name -t

# 面向脚本的机器可读输出（list 和 info）。
brew ghcask list --json

# 为未签名应用跳过 macOS quarantine（-s = --no-quarantine）。
brew ghcask install owner/repo -s

# 把 ghcask 不识别的参数在 `--` 之后直接透传给 brew。
# install、reinstall、upgrade、uninstall 都支持。
brew ghcask install owner/repo -- --appdir=/Applications --verbose
```

## 命令

| 命令 | 作用 |
| --- | --- |
| `init` | 准备或修复本地生成的 tap |
| `generate owner/repo [...]` | 只生成 cask，不安装 |
| `install owner/repo [...]` | 生成并安装 |
| `install cask --url URL` | 从直接 URL 生成并安装 |
| `reinstall cask\|owner/repo [...]` | 通过 Homebrew 重新安装 |
| `update` | 刷新所有 GitHub cask 元数据（不升级） |
| `upgrade [cask ...]` | 刷新后让 Homebrew 升级已安装的应用（`--greedy`：含自更新 cask） |
| `outdated [cask ...]` | 列出落后于最新发布的已安装 cask（`--all`：所有被管理的 cask，无论是否安装；`--greedy`：含自更新 cask） |
| `list` / `info` | 查看被管理的 cask（`--json` 输出机器可读格式） |
| `search QUERY` | 按 star 搜索 GitHub 仓库（类似 `brew search`） |
| `pin` / `unpin` | 把 GitHub cask 锁定到某个发布，或恢复跟随其发布轨道 |
| `uninstall` / `remove` / `rm` | 卸载并把条目标记为已卸载 |
| `cleanup [cask ...]` | 清理过期记录，或强制移除指定记录 |
| `dump` / `restore` | 通过 `Brewghcask.json` 备份 / 恢复 |
| `doctor` | 检查 ghcask 依赖的外部工具 |

运行 `brew ghcask --help` 查看完整选项列表。

## Quarantine（隔离属性）

macOS 会给下载的应用加上 quarantine 属性，未签名应用会因此拒绝启动。ghcask 在
`install` 和 `reinstall` 上支持 `-s` / `--no-quarantine`：

- 所选策略会存进 registry，因此 `upgrade`、`dump`、`restore` 都会遵循它。
- `--no-quarantine` 会传给 `brew install`，**并且** ghcask 会在 `install`、
  `reinstall`、`upgrade` 之后从应用上剥除 `com.apple.quarantine` 属性。
- 应用路径来自 Homebrew 的真实 artifact 目标（`brew info --cask --json=v2`），
  因此自定义 appdir 也能正确处理。
- `--no-quarantine` 只改变 ghcask 安装你信任的应用的方式，并非全局绕过 Gatekeeper。
  只对你信任的软件使用它。

`brew ghcask info <cask>` 会显示当前的 `Quarantine: enabled/disabled` 状态。

## 卸载 / zap

`brew ghcask uninstall <cask>` 通过 Homebrew 移除应用。对于 app cask，ghcask 还会
生成一个以应用 bundle identifier 为基础的 `zap` 段，因此：

```sh
brew ghcask uninstall <cask> --zap
```

会退出应用，并把它遗留的用户文件（偏好设置、缓存、Application Support 等）移到废纸篓。
`--zap` 需显式开启，且可恢复（移到废纸篓，而非删除）。pkg 和 binary cask 不会生成
`zap` 段。

## 与 brew 对齐

ghcask 尽量在能对齐处表现得和原生 `brew` 一致，并标注它有意不同的地方：

- `upgrade` 会跳过被锁定的 cask。要把锁定的 cask 移回其轨道，先 `unpin`
  再 `upgrade`。`upgrade -f/--force` 会把 `--force` 透传给 brew（覆盖文件）；它不会
  重新升级已是最新的 cask —— 那是 `reinstall --force` 的职责。
- `upgrade` 一次性批量读取已安装版本，并跳过已经处于生成版本的 cask（比直接透传
  `brew upgrade` 更主动）。
- `--force` 从源头重新下载（并把 `--force` 透传给 brew）。不加时 install/reinstall 优先用
  本地：GitHub cask 复用注册表条目，直接 URL cask 在 URL 未变时复用 Homebrew 的下载缓存。
  这比 brew 自己的 `--force`（只覆盖安装、仍用缓存）更宽——因为 ghcask 没有 `fetch`，把
  "重抓"折进了 `--force`。`update`/`upgrade` 总是查源头;它们的 `--force` 会连"已是最新"的
cask 也重新抓取(对齐 `brew update --force`)。
- 自更新的应用（带有 Sparkle 的 `SUFeedURL` 或随附 `Sparkle.framework`）会被打上
  `auto_updates true`，因此 `update` / `upgrade` / `outdated` 默认跳过它们，除非加
  `--greedy`（对齐 `brew upgrade --greedy`）。`outdated --all` 也会列出它们；要单次
  强制刷新用 `reinstall <cask> --force`。
- `uninstall` / `remove` / `rm` 互为别名；若应用已不在，会给出警告并仍把条目标记为已卸载。
- `cleanup [cask]` 强制移除指定的生成记录；不带参数时清理过期记录（cask 文件已删除 /
  已卸载 / 被 brew 移除）。
- `generate` 只生成本地 cask 而不安装应用。与 `install` 一样可接受多个 GitHub 目标；
  直接 URL 源只接受一个目标。
- 直接 URL 的 cask 无法检查上游更新，因此 `update` / `outdated` 会跳过它们。用
  `reinstall <cask> --url NEW_URL` 替换。

## 锁定（Pinning）

锁定是隐式的：一个 cask 在拥有「请求版本」时即为锁定。`--version` 在 install/reinstall
时锁定，`pin` / `unpin` 切换它。底层的 `latest-stable` / `latest-prerelease` 轨道始终被
记录，因此 `unpin` 会让 cask 回到该轨道。

## 备份与恢复

```sh
# 旧电脑
brew ghcask dump --global --force

# 新电脑
brew tap oxsean/ghcask
brew ghcask restore --global --install   # 一次完成恢复 + 安装缺失的 cask
```

`restore --install` 会安装尚未安装的已恢复 cask（幂等——已安装的会跳过），因此新机器
只需一条命令，而不必再单独跑一遍 `brew bundle`。去掉 `--install` 则只写入 cask 定义。
用 `--file PATH` 可指定自定义路径，替代默认的 `Brewghcask.json`（或 `--global`）。

`Brewghcask.json` 只存储生成的 cask 定义和 registry 条目（包含 quarantine 策略）——
不含下载的安装包或已安装的应用。cask 生成后，Brewfile 可以直接引用它：

```ruby
tap "oxsean/ghcask"
cask "ghcask/local/example"
```

## GitHub 访问

ghcask 在 `gh` 已安装并已认证时优先用 GitHub CLI，否则回退到匿名 `curl`（或
`GH_TOKEN` / `GITHUB_TOKEN`）。要在私有仓库上可靠访问、或避免匿名速率限制：

```sh
gh auth login
export GH_TOKEN=...
```

**元数据和资源下载都会认证。** Release 资源用与查询相同的后端获取：`gh` 已认证时用
`gh release download`，或在设置了 token 时用带 `Authorization` 头的 GitHub API 资源
端点。纯匿名 `curl` 只对公开仓库有效。

**私有仓库**：ghcask 会（带认证地）下载资源并预热 Homebrew 缓存，因此 `install` 可用。
生成的 cask 的 `url` 是标准的 release URL，Homebrew 只有在拥有凭据时才能重新获取；对于
私有仓库，`brew cleanup` 之后的再次下载需要环境里有你的 GitHub 认证。重跑
`brew ghcask reinstall <cask> --force` 可重新预热缓存。指向 GitHub 托管文件的
`install --url`——release 资源（`github.com/.../releases/download/...`）或仓库内文件
（`raw.githubusercontent.com/...`）——会用你的 token（来自环境或 `gh auth token`）下载，
因此私有文件可用。指向其它主机的 `--url` 使用无认证的纯 curl（token 绝不会发往 GitHub 之外）。

## 开发

```sh
script/test                                   # 完整 Minitest 测试套件
ruby -Ilib -Itest test/install_test.rb        # 运行单个测试文件
ruby -Ilib -Itest test/install_test.rb -n /quarantine/   # 按名称过滤
ruby -c cmd/brew-ghcask                        # 语法检查
GHCASK_BREW_REPOSITORY="$(mktemp -d)" ruby cmd/brew-ghcask install cli/cli --dry-run --arch arm64
```

## 许可证

基于 [Apache License 2.0](LICENSE) 授权。
