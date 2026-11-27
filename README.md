# 工时簿 · Work and Play

工时簿是一款个人 macOS 时间统计 App。它自动记录电脑上的有效前台活动，用来回顾一天花了多少时间在工作、加班和摸鱼，以及时间主要花在哪些 App 和网站上。统计支持按日、周、月、年和全部查看。记录保存在本机，也可以通过只读 MCP 交给 AI 写工作日报和周报。

- **普通工时与加班**按你设置的上下班、午休和临时排班统计。休息时段只保留有效工作，计入加班。
- **活动明细**可查看每段的起止、时长、来源、分类依据，以及为何计入加班。
- **网站统计**通过 Chrome 或 Edge 扩展记录域名，汇总前台访问次数、有效停留，以及工作和摸鱼时长。两个浏览器访问同一域名的数据会合并。
- **桌面与菜单栏**可在 Dock 打开主窗口。关闭窗口后仍可通过菜单栏查看状态和暂停计时。

## 安装 macOS App

系统要求为 **macOS 14 或更新版本**。下载包包含 Apple 芯片与 Intel 架构。

1. 下载通用安装包 `WorkAndPlay-1.1.1-universal.zip` 并解压。[GitHub Releases](https://github.com/xiaosu19/work-and-play/releases/latest)
2. 把 `WorkAndPlay.app` 拖到 Finder 的「应用程序」，双击打开。保留同包的 `install-chrome-host.sh`，安装浏览器扩展时会用到。升级时先退出旧版，在原路径替换 App，再打开新版。记录和规则存放在应用包外的本机数据目录。
3. 打开「设置 → 休息排班 → 按上下班设置」，填写上班、午休开始和结束、下班时间，选择应用到哪些星期。多段休息、全天休息和个别日期的临时排班也可以单独设置。

下载包使用临时签名，尚未经过 Apple 公证。macOS 可能会弹出来源确认。可查看系统提示说明，也可以按下文从源码构建。 [Apple 关于安全打开 App 的说明](https://support.apple.com/en-us/102445)

如果同时下载了 `SHA256SUMS.txt`，在两个文件所在目录运行 `shasum -a 256 -c SHA256SUMS.txt` 可以校验压缩包。

## 安装 Chrome 或 Microsoft Edge 扩展

App 单独运行即可按应用名称计时。接入网页统计需要完成**注册本机连接器**和**在浏览器加载扩展**两步。扩展随安装包提供，通过浏览器的本地扩展加载入口安装。

### 1. 注册本机连接器

在终端进入解压后的目录，运行以下命令。如果 App 存放在其他位置或已改名，把引号内的路径换成实际完整路径。脚本给当前 macOS 用户注册 Chrome 和 Edge 连接器，无需 `sudo`。

```sh
bash ./install-chrome-host.sh "/Applications/WorkAndPlay.app"
```

记下脚本输出的「扩展目录」，下一步要选择它。如果 App 放在 `/Applications`，目录为 `/Applications/WorkAndPlay.app/Contents/Resources/chrome-extension`。

### 2. 在浏览器加载扩展

| 浏览器 | 操作 |
| --- | --- |
| Chrome | 在地址栏输入 `chrome://extensions`，开启「开发者模式」，点击「加载已解压的扩展程序」并选中上一步的目录。 [Chrome 官方指南](https://developer.chrome.com/docs/extensions/get-started/tutorial/hello-world#load-unpacked) |
| Edge | 在地址栏输入 `edge://extensions`，开启「开发人员模式」，点击「加载解压缩的扩展」并选中上一步的目录。 [Edge 官方指南](https://learn.microsoft.com/en-us/microsoft-edge/extensions/getting-started/extension-sideloading) |

在 macOS 的文件选择窗口，可以按 `⌘⇧G` 粘贴完整目录路径。两个浏览器要分别加载一次。加载后，扩展列表会显示「工时簿 · 浏览器扩展」。

### 3. 确认能识别网页

1. 保持工时簿运行，在浏览器的普通窗口打开一个网页，例如 `https://developer.apple.com/`。网页在安装前已经打开时，刷新一次。
2. 从浏览器工具栏的扩展菜单打开工时簿扩展。弹窗显示「已连接工时簿，可以识别当前网页」即表示网页可读。
3. 在该网页翻页、滚动或进行其他有效互动，然后打开「时间总览 → 网站统计」核对域名、访问次数和有效停留时长。采集状态在前台网页可读时会显示「Chrome 页面级」或「Edge 页面级」。

已安装旧版扩展时，在 Chrome 或 Edge 的扩展管理页点击「重新加载」，确认扩展版本为 **1.4.0**，再刷新已打开的工作页面。如果移动了 App 或更改了名称，按新路径重跑注册脚本，并从脚本输出的目录加载扩展。

如果扩展未连接，检查 App 是否正在运行，并用当前 App 路径重跑注册脚本。如果已连接但网页没有信号，刷新页面并查看该扩展的网站访问权限。浏览器内部页面、无痕窗口和无网站权限的页面会回退到应用级统计。

## 日常使用

1. 打开「时间总览」，选择日、周、月、年或全部。点击普通工时、加班或摸鱼卡片，可查看对应来源和时段。
2. 在「网站统计」选择「设为 → 设为工作」或「设为摸鱼」，即可为未来访问保存规则。填写 `*.example.com` 或 `*example.com` 可覆盖 `example.com` 及其子域名。更具体的路径、窗口或项目条件可以在「设置 → 分类规则」里配置。
3. 在「时间片段」点击「修正」可以改一条已有记录。网站分类规则从新的有效活动开始生效，报表上的历史时长按片段原有分类汇总。

工时簿按已知 App、网站和可用窗口信号自动分类。只取得 Chrome 或 Edge 应用名且无法判断用途的片段会单列为「网页未识别」。在时间图或活动明细可以查看这些片段，新记录会标出扩展是否连接。报表里的普通工时、加班和摸鱼总数分别统计已入各自分类的片段。

在日报的「当天时间分布」展开「未计入」，可核对第一条到最后一条记录之间的空档起止和时长。明细默认收起，展开后按时长从长到短排列，每页最多 8 段。空档按当前排班显示普通时段。

| 场景 | 默认计时方式 |
| --- | --- |
| 写代码、终端操作 | 键鼠活动续计，连续空闲 180 秒后停止。 |
| 阅读文档 | 开页、翻页或有效滚动续计，默认上限 120 秒。 |
| 前台看视频 | 可在「设置 → 计时」打开前台视频计时。只有归为摸鱼、可见且正在播放的网页视频才按播放状态续计。 |
| 工作时后台放歌，或后台跑构建 | 同一时刻只统计一个前台活动。后台音乐、视频和任务不另计。 |
| 锁屏、睡眠、暂停 | 当前计时停止，恢复后使用新的活动信号。 |

在「设置 → 计时」可开启「普通时段的空闲计入摸鱼」。例如空闲上限设为 180 秒，连续 5 分钟没有键鼠操作时，超过上限的 2 分钟可记为「设备空闲」。已确认的锁屏、睡眠从状态切换起计，睡眠片段在唤醒后补记。有效阅读和前台视频优先于清醒空闲，休息与暂停时间不计入。开启后可在「摸鱼 → 应用与网站」查看设备空闲，片段会标出原因。

「时间总览 → 应用统计」按 App 汇总前台片段数、总时长、工作与摸鱼。可以查看 App 的全部片段，或点「设为」为该 App 设置后续分类。网站、路径、窗口等更具体的规则优先。

## 自动记录与 AI 接入

工时簿运行时会把已保存的有效片段按天写入本机 JSON，约每 15 秒同步一次，退出时同步已提交记录。基础片段包含应用或域名、活动类型、起止时间、时长与分类依据。

| 分类 | 本机 JSON 目录 |
| --- | --- |
| 工作，含普通工时和加班 | `~/Library/Application Support/WorkAndPlay/operation-json/work/` |
| 摸鱼 | `~/Library/Application Support/WorkAndPlay/operation-json/leisure/` |

在「记录与接口」可按日或按周查看两类记录。点「显示 JSON 文件」打开当前类别的文件夹。

### 为工作记录补充操作描述

1. 在「设置 → 操作描述 → 添加来源」指定工作网站、原生 App 或客户会话，并填写项目或客户别名。工作分类和采集授权同时匹配后，新的详细操作会自动附在对应时间片段上。保存授权时也可以添加匹配的工作分类规则。
2. 浏览器扩展 1.4.0 可识别部分网页操作、文档互动和常见的保存或提交。观察到同一页面出现新的成功状态时，尝试会更新为已确认。
3. 在「时间总览 → 时间片段」点工作记录的「操作描述」，查看来源或补记结果。个人微信或企业微信的会话识别需要辅助功能能读到精确会话标题。可以在片段下补记发送结果。
4. 在「记录与接口 → 工作记录」可从详细描述点回片段，也可以修正、排除或删除描述。

### 让外部 AI 写日报与周报

MCP 只读工作 JSON。日报和周报由接入的 AI 客户端生成。客户端需要能在同一台 Mac 启动本机 stdio 服务。

**Codex** 可在支持本机 MCP 的设置中添加服务器，也可以在终端运行以下命令。路径要与实际安装位置一致。配置完成后重启客户端，在新对话中调用工时簿。[Codex MCP 配置说明](https://learn.chatgpt.com/docs/extend/mcp?surface=cli)

```sh
codex mcp add workandplay -- "/Applications/WorkAndPlay.app/Contents/Helpers/WorkAndPlayReport" mcp
codex mcp get workandplay
```

**其他客户端** 可在「记录与接口 → 工作记录」点「复制 MCP 配置」，再添加到客户端。如果客户端使用 `mcpServers` 配置，结构如下。

```json
{
  "mcpServers": {
    "workandplay": {
      "command": "/Applications/WorkAndPlay.app/Contents/Helpers/WorkAndPlayReport",
      "args": ["mcp"]
    }
  }
}
```

验证连接时，可以先告诉 AI「调用工时簿，看看今天有没有工作记录」。`read_work_operations` 接受 `period`（`day` 或 `week`）和 `date`（`YYYY-MM-DD`）。周从周一到周日，返回值中的 `days` 列出已有本机快照的日期。升级后会同步当天已保存的片段。较早日期可在「记录与接口」查看并手动导出，周查询的覆盖日期以 `days` 为准。[MCP 本机连接规范](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#stdio)

写报告时可以告诉 AI「读取本周工作记录，按项目写周报，区分已确认和待确认结果」。详细描述少的日期仍可根据已有基础片段汇总工时。

### 本机 JSON 接口

在「记录与接口」选择类别和周期，可点「导出 JSON」或「授权命令行读取」。命令行快照的授权在 24 小时后失效，也可在界面撤销。运行时把示例日期换成要读取的日期。

```sh
"/Applications/WorkAndPlay.app/Contents/Helpers/WorkAndPlayReport" work day 2026-11-27
"/Applications/WorkAndPlay.app/Contents/Helpers/WorkAndPlayReport" work week 2026-11-27
"/Applications/WorkAndPlay.app/Contents/Helpers/WorkAndPlayReport" leisure day 2026-11-27
```

返回内容包括周期和基础片段。工作快照包含工作时长和详细操作，摸鱼快照包含摸鱼时长及来源汇总。周命令接受周内任意一天。授权后界面会显示适用的完整命令。

## 权限与本机数据

- **辅助功能**为可选权限，用于读取前台窗口标题、识别原生窗口状态和匹配指定客户会话。
- **屏幕录制**只用于单独启用的原生窗口 OCR。需要准确的窗口标题与关键词，图像和识别文本在本机内存处理，操作记录只保留匹配结果。
- **网站访问权限**决定扩展能在哪些站点识别前台网页。扩展通过本机连接器传递域名、匹配所需路径、互动时间和播放状态。工作采集授权开启后，另传动作和结果。查询参数、URL 片段、页面正文和按键内容不会写入记录。
- 数据与规则保存在 `~/Library/Application Support/WorkAndPlay/history.sqlite3`。App 无账号和云同步。休息时段的摸鱼、未分类和空闲活动在写入前过滤。

## 从源码构建和验证

需要 macOS 14 或更新版本、Apple Command Line Tools 或 Xcode，以及 Swift 6.0 或更新版本。构建和验证使用系统 SQLite。

```sh
git clone https://github.com/xiaosu19/work-and-play.git
cd work-and-play
swift run Verification
./scripts/build-app.sh
open dist/WorkAndPlay.app
```

要给此构建接入浏览器，运行 `./scripts/install-chrome-host.sh` 并按上文加载脚本输出的扩展目录。在能交叉编译 macOS 两种架构的工具链上，`./scripts/build-app.sh --universal` 可生成通用 App。

`swift run Verification` 会验证计时、分类、排班边界、SQLite 隐私和工作、摸鱼 JSON 分流。要复测真实浏览器，先构建并退出工时簿，再运行 `node scripts/verify-chrome.mjs` 或 `node scripts/verify-chrome.mjs --edge --pages-only`。测试脚本会用已安装的浏览器打开本地测试网页，使用隔离的浏览器配置和临时数据库。[项目规则](AGENTS.md) · [实现记录](DECISIONS.md)
