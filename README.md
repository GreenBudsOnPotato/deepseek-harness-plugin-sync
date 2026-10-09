# DSH plugin sync / 两个 DSH 安装的插件同步

在同一台机器上的两个 DeepSeek Harness 安装之间同步插件：

- **桌面版**（DeepSeek Harness Desktop，Electron 应用）使用 profile `desktop`
- **网页版**（DSH Studio / `dsh web`）使用 profile `web`

两者共用同一个 `$DSH_HOME`，插件规范、加载器、`cordis.patch.yml` 补丁机制完全一致，
但插件装在**各自的 profile 目录**里，所以默认互相看不见。本仓库提供脚本把两侧的
插件依赖、bundle 顺序与兼容豁免合并成一致的集合，并只在真正缺少内容的一侧执行安装。

在任意一侧装 / 卸 / 改插件之后跑一次同步，两边就一致了。

---

## 为什么需要它

| | 桌面版 | 网页版 |
|---|---|---|
| profile | `desktop` | `web` |
| 目录 | `$DSH_HOME/profiles/desktop` | `$DSH_HOME/profiles/web` |
| 谁管插件 | 应用独占；**普通 `dsh` 命令明确拒绝操作它** | `dsh plugin --profile web ...` |

三个关键事实：

1. 插件是 npm 包，装在 profile 目录的 `package.json` + `node_modules` 里 —— 两个 profile 各装一份。
2. 桌面版的 `desktop` profile 被应用独占，只有桌面版自带的 CLI
   （`resources/app.asar/dsh/node_modules/@deepseek-ai/dsh-desktop-host/lib/cli.js`，
   用桌面版 Electron 以 Node 模式运行）才能管理它。
3. dsh 会校验插件 `peerDependencies` 里声明的 `@deepseek-ai/dsh*` 版本范围，
   不覆盖当前内核就**拒绝安装、并在启动时拒绝加载**；两个版本的内核版本不同时，
   同一个插件可能一侧能装、另一侧不能。

---

## 快速开始

```powershell
# 先看会改什么（推荐第一次这样跑）
.\sync.cmd -DryRun

# 正式同步
.\sync.cmd

# 两侧全部重装一遍（修 node_modules 损坏）
.\sync.cmd -Force
```

`sync.cmd` 只是 `scripts\Sync-DshPlugins.ps1` 的一层壳，作用是为**当前进程**加上
`-ExecutionPolicy Bypass`（脚本没有代码签名，默认策略 RemoteSigned 会拒绝加载），
不会修改任何系统级策略。也可以直接调用：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Sync-DshPlugins.ps1
```

### 自动同步

```powershell
.\watch.cmd
```

每 5 秒检查两侧的 `package.json` / `compatibility.json`，发现变化并静置 20 秒
（等安装流程结束）后自动跑一次同步。日志写在 `scripts\dsh-plugin-watch.log`。
窗口关掉即停止；要开机自启可在「任务计划程序」里加一个登录触发的任务：

```
powershell -NoProfile -ExecutionPolicy Bypass -File "<仓库目录>\scripts\Watch-DshPlugins.ps1"
```

---

## 参数

| 参数 | 作用 |
|---|---|
| `-DryRun` | 只预演，不写文件、不安装 |
| `-Force` | 两侧把全部插件重新安装一遍 |
| `-Pin 包名@版本` | 把某插件在两侧都钉到指定版本，可重复 / 可逗号分隔 |
| `-GrantExemptions` | 为不兼容插件批量申请"精确版本豁免" |
| `-AllowRunningDesktop` | 桌面版开着也照装（默认拒绝；装完需重启桌面版才生效） |
| `-SyncPatchFile` | 处理 `cordis.patch.yml`（默认不动，见下） |
| `-NoExemptions` | 不搬运兼容豁免 |
| `-ProfileA` / `-ProfileB` | 改 profile 名，默认 `desktop` / `web` |
| `-DesktopRoot` | 指定桌面版安装目录（默认自动发现） |
| `-WebCliNode` / `-WebCliScript` | 指定网页版 CLI 的 Node 与 `bin.js`（默认自动发现） |

对应环境变量：`DSH_HOME`、`DSH_DESKTOP_ROOT`、`DSH_WEB_NODE`、`DSH_WEB_CLI`。

---

## 合并规则（为什么不会来回抖）

- **dependencies**：取并集；同一个包两侧范围不同时取更新的那个版本。
- **dsh.profile.bundles**：取并集，各自保留原顺序，另一侧独有的项追加在后。
- **compatibility.json**：取并集（只会放宽，不会突然禁用本机已经能跑的插件）。
- **cordis.patch.yml**：**默认不动**。桌面版这份通常含桌面专属设置（默认模型、主题、
  账号引导等），网页版往往是空数组，强行合并会把桌面设置灌进网页版。加 `-SyncPatchFile`
  时脚本也只做提示并写 `.bak` 备份，不盲写。

脚本是幂等的：两侧一致时再跑一次不会产生任何变化。

---

## 精确版本豁免

内核升级到新的预发布线时，很多第三方插件还没更新 `peerDependencies` 声明，于是被 dsh
拒绝。dsh 为此提供**精确版本豁免**：只对「某个包的确切版本 + 确切内核版本」放行。

```powershell
dsh plugin allow-version <包>@<版本> --profile web --dsh-version <确切内核版本> --accept-risk
```

写入的位置是 profile 目录下的 `compatibility.json`，格式就是一个平铺映射：

```json
{
  "some-plugin@1.2.3": [
    "0.2.0-rc.2"
  ]
}
```

若本机安装的 CLI 版本较旧、还没有 `allow-version` 子命令（会被转发给 pnpm 并报
`Command "allow-version" not found`），`-GrantExemptions` 会按同样的官方格式直接写入该文件。
收回报废用 `dsh plugin revoke-version`，或删掉对应条目。

> 豁免是"接受风险"的显式动作：它只跳过版本声明检查，不代表插件在新内核上一定工作正常。

---

## 一个真实案例（本仓库的由来）

同一台机器上：桌面版内核 0.2.0-rc.2，网页版内核 0.1.5-rc.3，网页版装了 7 个插件。
把 7 个插件同步到桌面版时，逐个体检的结果是：

| 插件（旧版本） | 声明要求 | 0.2.0-rc.2 |
|---|---|---|
| `dsh-plugin@1.4.3` | 无 | 兼容 |
| `dsh-whale-widget@0.2.10` | 无 | 兼容 |
| `@xmanrui/dsh-im@4.20.1` | 无 | 兼容 |
| `dsh-tabbit@0.3.4` | `>=0.1.1-rc.2` | 兼容 |
| `dsh-mnemon@0.5.8` | 只到 `0.1.5-rc.1` | **不兼容** |
| `dsh-plugin-wallpaper-engine@0.7.2` | `^0.1.x` | **不兼容** |
| `dsh-find-plugin@0.3.7` | `dsh-tools ^0.1.0-rc.6` | **不兼容** |

适配方式：

- `dsh-mnemon` → 0.5.25、`dsh-plugin-wallpaper-engine` → 1.3.1、`dsh-tabbit` → 0.3.5：
  新版本把 peer 范围扩到了 `0.2.0-rc.x`，属于**真兼容**，不需要豁免；
- `dsh-plugin` → 1.5.2、`@xmanrui/dsh-im` → 4.37.0、`dsh-whale-widget` → 0.2.10：
  本身不声明 dsh peer，天然兼容；
- `dsh-find-plugin` 是唯一无法靠升级解决的（连最新 0.4.0 也只声明到 `^0.1.7-alpha.1`），
  只能使用精确版本豁免。

最终用 `-Pin` 把两侧钉到同一组版本，并在两侧写入同一条豁免，脚本复检通过。

---

## 文件说明

| 文件 | 作用 |
|---|---|
| `sync.cmd` / `watch.cmd` | 双击或命令行入口（自动加 `-ExecutionPolicy Bypass`） |
| `scripts/Sync-DshPlugins.ps1` | 双向同步主脚本 |
| `scripts/Watch-DshPlugins.ps1` | 监视模式，改动后自动同步 |
| `scripts/*.log` | 运行日志（已被 `.gitignore` 忽略） |
| `backup-*/` | 本地备份快照（已被 `.gitignore` 忽略） |

脚本只读写 `<DSH_HOME>/profiles/<profile>` 这两个目录，不碰会话、凭据等其它数据。

## 回滚

同步前先备份 profile 里的配置：

```powershell
$home = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
foreach ($p in 'desktop','web') {
    $dst = Join-Path $PSScriptRoot "backup-$stamp\$p"
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Copy-Item "$home\profiles\$p\package.json","$home\profiles\$p\cordis.patch.yml","$home\profiles\$p\pnpm-lock.yaml" $dst -Force -ErrorAction SilentlyContinue
}
```

恢复时把文件拷回对应 profile 目录，再执行 `.\sync.cmd -Force` 让 `node_modules`
与清单对齐。

## 环境要求

- Windows + Windows PowerShell 5.1 或更高（脚本为纯 ASCII，兼容 5.1 的 ANSI 解析行为）
- 已安装 DeepSeek Harness Desktop（桌面版）与带 `dsh` 命令的网页版
- 首次同步桌面版之前，桌面版至少要启动过一次（用来自动生成它的 profile 目录）

## License

MIT
