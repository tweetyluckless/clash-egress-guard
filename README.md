# clash-egress-guard

[简体中文](README.zh-CN.md)

📺 **Video tutorial** (9 min, Chinese narration and subtitles):
[watch on Bilibili](https://www.bilibili.com/video/BV1114q6nEbS/)

An **experimental** fail-closed egress guard for Windows with
[Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev) (Mihomo core).

- **Protect mode:** all public traffic goes through one outbound you already
  have in Clash, via TUN. Windows Firewall blocks outbound traffic by default,
  so if Clash or the TUN stops, nothing goes out through the physical adapter.
- **Live mode:** temporarily turns the guard off and uses your direct
  connection, for example for streaming software that needs UDP or a direct
  route. One click switches back to Protect mode.

Every install and every switch back to Protect mode runs checks. The scripts
confirm the egress country/IP, stop the Clash service, check that direct TCP is
blocked, then restart the service and check the egress again.

> [!WARNING]
> This tool changes Windows Firewall for the whole machine. While Protect mode
> is on, the default outbound action is **Block**, all of your existing local
> outbound *allow* rules are disabled, and UDP is rejected. Read this whole
> page before you install it, and keep `restore.cmd` working.

## How it works

| Layer | What it does |
| --- | --- |
| Clash policy | Appended to Clash Verge Rev's global extend script (`profiles/Script.js`), so it survives profile updates. It forces `mode: rule`, `ipv6: false`, a TUN (`gvisor`, `auto-route`, `strict-route`, DNS hijack) and fake-ip DNS over DoH through your outbound. The rules become `NETWORK,udp,REJECT` then `MATCH,<outbound>`. The outbound must resolve to explicit proxy nodes. `DIRECT` and `REJECT` members, cycles and provider-only groups are refused. |
| Firewall | Outbound is allowed only for loopback (`127.0.0.1`), the TUN interface, the Mihomo core to your proxy's first-hop IPs/port (TCP), the Mihomo core to bootstrap DNS on port 53, and DHCP. Everything else is blocked by default. |
| Checks | The egress reported by `ipinfo.io` and `ip-api.com` must match `expectedCountry` (and `expectedIp` if set). With the service stopped, TCP probes to `1.1.1.1:443` and `[2606:4700:4700::1111]:443` must fail. |
| Safety | Before anything changes, the four Clash files are backed up and Windows Firewall is exported (`netsh advfirewall export`). The Mihomo binary is pinned by SHA-256 when you prepare. If an install fails, it rolls back the firewall and checks the rollback. |

## Requirements

- Windows 10 or 11 with the built-in Windows PowerShell 5.1, and an
  administrator account.
- Clash Verge Rev with **service mode** installed (the default service name is
  `clash_verge_service`).
- Node.js 20 or later on `PATH`.
- A working proxy node or group in Clash whose first hop is a fixed
  host reached over TCP.

## Two ways to install

- **Do it yourself:** follow [Setup](#setup) below
  ([video from 02:24](https://www.bilibili.com/video/BV1114q6nEbS/?t=144)).
- **Let an AI agent do it:** if an agent such as Claude Code or Codex can run commands on
  this PC, it can do most of the work. It follows [AGENTS.md](AGENTS.md)
  ([video from 05:07](https://www.bilibili.com/video/BV1114q6nEbS/?t=307)).

### Let an AI agent set it up

First, do these yourself: install Clash Verge Rev, turn on service mode, and make sure your
node works. Then paste this to your agent:

```text
Install clash-egress-guard on this PC by following AGENTS.md in
https://github.com/tweetyluckless/clash-egress-guard. Tell me when an administrator
prompt is needed and I will click it myself. Do not read or print my proxy passwords or
subscription URLs.
```

The agent checks your setup, downloads the project and lists your nodes with
`npm run inspect`, which never prints passwords. It then asks which node and egress country
to use, writes `config.local.json` and runs the prepare step.

There is one step only you can do. When the agent asks, double-click `install.cmd` and
click **Yes** on the administrator prompt. Agents cannot click that prompt. The network
drops for a moment during the install, so the agent may lose its connection briefly. Later
mode switches also need you to click **Yes**. Afterwards, the agent can read the result
files to check the switch.

> [!CAUTION]
> Don't let the agent open Clash's configuration files directly. They contain your
> subscription URL and node passwords, and anything the agent reads is sent to its AI
> provider. If the whole PC goes offline, the agent can't help either. Run `live.cmd` to
> get direct access back, or `restore.cmd` to remove the guard.

## Setup

```bash
git clone https://github.com/tweetyluckless/clash-egress-guard.git
```

```bash
cd clash-egress-guard
```

```bash
npm ci
```

If PowerShell says running scripts is disabled on this system, type `npm.cmd` instead of
`npm` (for example `npm.cmd ci`), or use Command Prompt.

1. Copy `config.example.json` to `config.local.json` and edit it. This file is
   git-ignored. If you're not sure what to enter, two commands can help.
   `npm run inspect` lists your proxies and groups. It prints names, servers and ports,
   never passwords. `npm run inspect -- --outbound "<name>"` works out the `upstream` for
   that outbound and warns about setups that can't work.

   | Field | Meaning |
   | --- | --- |
   | `outbound` | Name of the existing proxy or proxy group that all traffic must use. |
   | `upstream.host` / `upstream.port` | The server Mihomo connects to **directly** for that outbound. For a chained proxy, this is the first node's server. Only this endpoint can be reached outside the TUN. |
   | `expectedCountry` | ISO country code the egress must report, for example `JP`. |
   | `expectedIp` | Optional. If set, the egress IP must match exactly. |
   | `clashExe`, `coreExe` | Paths to `clash-verge.exe` and `verge-mihomo.exe`. |
   | `clashDataDir` | Optional. Defaults to `%APPDATA%\io.github.clash-verge-rev.clash-verge-rev`. |
   | `serviceName` | The Clash Verge service name. |
   | `tunDevice` | Name of the TUN adapter to create (3 to 32 characters: letters, digits, `_` or `-`). |
   | `bootstrapDns` | IPv4 resolvers the core may use to look up the upstream host. |
   | `appsToCloseBeforeLive` | Optional. Process names without `.exe`. Live mode refuses to start while any of them is running. |
   | `stateDir` | Optional. Where backups and status files are kept. Defaults to `%LOCALAPPDATA%\clash-egress-guard\state`. It must be outside the source tree. |

2. In Clash Verge Rev, turn on service mode and select the profile that
   contains your outbound.
3. Prepare the installation. This step makes **no system changes**. It
   validates the config, checks the outbound through Clash's mixed port, backs
   up the Clash files and stages the protected versions:

   ```bash
   npm run prepare-config
   ```

4. Double-click `install.cmd` and accept the administrator prompt. The install
   succeeded only if the output shows `"phase": "complete"`.
5. Optional: add desktop shortcuts for the two modes:

   ```bash
   powershell -NoProfile -ExecutionPolicy Bypass -File Create-Shortcuts.ps1
   ```

## Daily use

| Action | Entry point |
| --- | --- |
| Go direct temporarily | `live.cmd`: stops Clash, turns off TUN and the system proxy, re-enables your original outbound allow rules and sets the default outbound action to Allow. |
| Turn protection back on | `protect.cmd`: blocks direct traffic first, then starts Clash, checks the egress, runs the kill-switch test and checks recovery. |

Both commands need the administrator prompt. A switch succeeded only when
`mode-status.json` in the state directory shows `"phase": "complete"` and the
`effectiveMode` you expect. If a switch fails, the scripts try to return to
Protect mode.

The firewall settings stay in place after a reboot. If Clash Verge Rev starts
at login, the TUN comes back by itself. If it doesn't, run `protect.cmd`.

## Restore and uninstall

`restore.cmd` imports the firewall snapshot taken before install, puts back the
four Clash files from the backup and restarts Clash. It is an emergency
restore, not a mode switch. **Do not delete the state directory** while the
guard is installed, because it holds the only backups.

## Limitations

- UDP is blocked in Protect mode. QUIC falls back to TCP, but games, voice
  calls and SRT streaming may not work. Use Live mode for those.
- IPv6 is disabled in Clash, and direct IPv6 is blocked by the firewall.
- If the upstream host's IP changes, or the Mihomo core is updated (its hash
  is pinned), the guard fails closed and you have no network. Use `live.cmd` or
  `restore.cmd`, then prepare and install again.
- Outbound rules from Group Policy and interfaces excluded from the firewall
  are not supported. The installer stops before it changes anything.
- The block check probes sample addresses only. It is not a full leak audit.
- The guard controls the network egress only. It does not change anything
  else that can reveal your location, such as account data, browser
  fingerprinting or time zone.
- This project has no connection to Clash Verge Rev or Mihomo.

## Development

```bash
npm test
```

```bash
npm run test:powershell
```

The PowerShell test mocks the firewall and registry cmdlets. It never touches
the real firewall or proxy settings.

| File | Role |
| --- | --- |
| `AGENTS.md` | Step-by-step instructions and safety rules for AI agents. |
| `inspect.cjs` | Lists outbounds without secrets and works out the first hop of one outbound. |
| `guard.cjs` | Helper CLI: `prepare`, `policy-check`, `proxy-check`, `direct-check`, `blocked-check`, `configure-mode`. |
| `policy.cjs` | Builds and checks the Clash policy. The same function is injected into Clash's script runtime. |
| `settings.cjs`, `Settings.ps1` | Load and validate `config.local.json`. |
| `Install.ps1`, `ApplyPolicy.ps1` | Install the policy and the firewall rules, with rollback. |
| `Modes.ps1` | Switch between Live and Protect modes. |
| `Restore.ps1` | Emergency restore from the backups. |
| `Launch.ps1`, `*.cmd` | Entry points that request elevation. |

## License

[MIT](LICENSE)
