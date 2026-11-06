# clash-egress-guard

[English](README.md)

📺 **视频教程**（9 分钟，中文旁白和字幕）：[在 B 站观看](https://www.bilibili.com/video/BV1114q6nEbS/)

一个**实验性**的 Windows 出口保护工具，配合
[Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev)（Mihomo 内核）使用，
代理失效时自动断网，不会回落直连。

- **保护模式**：所有公网流量经 TUN 走你在 Clash 里已有的某个出站。Windows 防火墙默认阻止出站，
  所以 Clash 或 TUN 一旦停止，流量不会从物理网卡直连出去。
- **直播模式**：临时关闭保护、使用本地直连（例如需要 UDP 或直连的直播软件），双击即可切回保护模式。

每次安装、每次切回保护模式都会自动检查：确认出口国家/IP，停止 Clash 服务后确认 TCP 直连被阻止，
再恢复服务并重新检查出口。

> [!WARNING]
> 本工具会修改整台电脑的 Windows 防火墙：保护模式下默认出站为**阻止**，
> 原有的本地出站**允许**规则会全部停用，UDP 也会被拒绝。安装前请读完本页，并确保 `restore.cmd` 可用。

## 工作原理

| 层 | 作用 |
| --- | --- |
| Clash 策略 | 追加到 Clash Verge Rev 的全局扩展脚本（`profiles/Script.js`），更新订阅也不会丢失。强制 `mode: rule`、`ipv6: false`、TUN（`gvisor`、`auto-route`、`strict-route`、DNS 劫持），以及经你的出站走 DoH 的 fake-ip DNS。规则变为 `NETWORK,udp,REJECT` → `MATCH,<出站>`。出站必须能解析到明确的代理节点；含 `DIRECT`/`REJECT` 成员、循环引用、只含 provider 的分组都会被拒绝。 |
| 防火墙 | 只放行：回环 `127.0.0.1`、TUN 网卡、Mihomo 内核到代理第一跳 IP/端口（TCP）、Mihomo 内核到引导 DNS 的 53 端口、DHCP。其余出站一律默认阻止。 |
| 检查 | `ipinfo.io` 和 `ip-api.com` 报告的出口必须符合 `expectedCountry`（设置了 `expectedIp` 时还要求 IP 一致）。服务停止后，对 `1.1.1.1:443` 和 `[2606:4700:4700::1111]:443` 的 TCP 探测必须失败。 |
| 安全措施 | 改动前先备份 4 个 Clash 文件并导出整份防火墙配置（`netsh advfirewall export`）。准备阶段会记录 Mihomo 程序的 SHA-256。安装失败会回滚防火墙并核验回滚结果。 |

## 环境要求

- Windows 10 或 11，系统自带的 Windows PowerShell 5.1，管理员账户。
- 已安装**服务模式**的 Clash Verge Rev（默认服务名 `clash_verge_service`）。
- `PATH` 中有 Node.js 20 或更高版本。
- Clash 里有一个可用的代理节点或分组，第一跳是通过 TCP 连接的固定主机。

## 两种安装方式

- **自己操作**：按下面的[安装](#安装)步骤来（[视频从 02:24 开始](https://www.bilibili.com/video/BV1114q6nEbS/?t=144)）。
- **交给 AI Agent**：如果你电脑上有能运行命令的 Agent（例如 Claude Code、Codex），大部分步骤可以交给它，它会按照 [AGENTS.md](AGENTS.md) 来操作（[视频从 05:07 开始](https://www.bilibili.com/video/BV1114q6nEbS/?t=307)）。

### 交给 AI Agent

先自己完成这几件事：安装 Clash Verge Rev、开启服务模式、确认节点能用。然后把下面这段话发给你的 Agent：

```text
请按照 https://github.com/tweetyluckless/clash-egress-guard 里的 AGENTS.md，帮我在这台电脑上安装 clash-egress-guard。
需要管理员确认的步骤告诉我，我自己来点。不要读取或输出我的节点密码和订阅链接。
```

Agent 会检查你的电脑环境、下载项目，并用 `npm run inspect` 列出你的节点（不会显示密码），
然后问你用哪个节点、出口应该在哪个国家，再写好 `config.local.json`，运行准备步骤。

有一步只能你自己做：Agent 请你双击 `install.cmd` 时，在管理员提示里点“是”。Agent 点不了这个弹窗。
安装中途会短暂断网，Agent 可能暂时掉线。以后切换模式也要你自己点“是”，切完可以让 Agent 读取结果文件帮你确认。

> [!CAUTION]
> 不要让 Agent 直接打开 Clash 的配置文件，里面有订阅链接和节点密码，Agent 读到的内容都会发送给它的 AI 服务商。
> 万一整机断网，Agent 也连不上，这时请自己运行 `live.cmd` 恢复直连，或运行 `restore.cmd` 卸载保护。

## 安装

```bash
git clone https://github.com/tweetyluckless/clash-egress-guard.git
```

```bash
cd clash-egress-guard
```

```bash
npm ci
```

1. 把 `config.example.json` 复制为 `config.local.json` 并修改。该文件不会提交到 git。
   不知道怎么填，可以用两个命令帮忙：`npm run inspect` 列出你的节点和分组，只显示名称、服务器和端口，不会显示密码；
   `npm run inspect -- --outbound "<名称>"` 会算出这个出站的 `upstream`，配置不可行时也会提示。

   | 字段 | 含义 |
   | --- | --- |
   | `outbound` | 所有流量必须使用的现有代理或代理组名称。 |
   | `upstream.host` / `upstream.port` | Mihomo 为该出站**直接**连接的服务器；链式代理填第一个节点的服务器。TUN 之外只放行这一个地址。 |
   | `expectedCountry` | 出口必须对应的国家代码，例如 `JP`。 |
   | `expectedIp` | 可选。填写后出口 IP 必须完全一致。 |
   | `clashExe`、`coreExe` | `clash-verge.exe` 和 `verge-mihomo.exe` 的路径。 |
   | `clashDataDir` | 可选，默认 `%APPDATA%\io.github.clash-verge-rev.clash-verge-rev`。 |
   | `serviceName` | Clash Verge 服务名。 |
   | `tunDevice` | 要创建的 TUN 网卡名（3～32 个字母、数字、`_` 或 `-`）。 |
   | `bootstrapDns` | 内核解析上游主机时可用的 IPv4 DNS。 |
   | `appsToCloseBeforeLive` | 可选。进程名（不带 `.exe`）；其中任何一个还在运行时，直播模式会拒绝启动。 |
   | `stateDir` | 可选。备份和状态文件的位置，默认 `%LOCALAPPDATA%\clash-egress-guard\state`，必须在源码目录之外。 |

2. 在 Clash Verge Rev 中开启服务模式，并选中包含该出站的配置。
3. 准备安装。这一步**不改动系统**，只校验配置、经 Clash 混合端口检查出站、备份 Clash 文件并生成待应用的保护版本：

   ```bash
   npm run prepare-config
   ```

4. 双击 `install.cmd`，在管理员提示中点“是”。只有输出显示 `"phase": "complete"` 才算安装成功。
5. 可选：为两种模式创建桌面快捷方式：

   ```bash
   powershell -NoProfile -ExecutionPolicy Bypass -File Create-Shortcuts.ps1
   ```

## 日常使用

| 操作 | 入口 |
| --- | --- |
| 临时直连 | `live.cmd`：停止 Clash，关闭 TUN 和系统代理，恢复原有出站允许规则，并把默认出站改为允许。 |
| 恢复保护 | `protect.cmd`：先阻止直连，再启动 Clash，检查出口，做断线测试，并检查恢复后的出口。 |

两者都需要在管理员提示中确认。只有状态目录里的 `mode-status.json` 显示 `"phase": "complete"`，
且 `effectiveMode` 是你要的模式，才算切换成功。切换失败时，脚本会尝试回到保护模式。

重启电脑后防火墙设置仍然有效。如果 Clash Verge Rev 设置了开机自启，TUN 会自动恢复；没有的话运行 `protect.cmd`。

## 恢复与卸载

`restore.cmd` 会导入安装前的防火墙快照，从备份恢复 4 个 Clash 文件并重启 Clash。它用于紧急恢复，
不是模式切换。安装期间**不要删除状态目录**，里面存着唯一的备份。

## 限制

- 保护模式下 UDP 被阻止。QUIC 会回退到 TCP，但游戏、语音通话和 SRT 推流可能无法使用，这些场景请用直播模式。
- Clash 的 IPv6 被关闭，防火墙也会阻止 IPv6 直连。
- 上游主机的 IP 变化，或 Mihomo 内核更新（哈希已锁定）后，保护会进入断网状态。
  这时用 `live.cmd` 或 `restore.cmd` 恢复网络，然后重新准备并安装。
- 不支持组策略下发的出站规则或被排除在防火墙之外的网卡，安装程序会在改动前停止。
- 断线检查只探测几个示例地址，并非完整的泄漏审计。
- 本工具只控制网络出口，不会改变其他可能透露位置的信息，例如账号资料、浏览器指纹或时区。
- 本项目与 Clash Verge Rev、Mihomo 官方无关。

## 开发

```bash
npm test
```

```bash
npm run test:powershell
```

PowerShell 测试会模拟防火墙和注册表命令，不会改动真实的防火墙或代理设置。

## 许可证

[MIT](LICENSE)
