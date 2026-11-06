# Instructions for AI agents

These instructions are for an AI agent (Claude Code, Codex and similar) that a user has asked
to install or operate clash-egress-guard on their Windows PC. People should read
[README.md](README.md) instead.

The guard changes Windows Firewall for the whole machine. A mistake can leave the user
offline, and then you are offline too. Work carefully, talk to the user in their language,
and stop at each step marked **HANDOFF**.

## Rules

1. **Never elevate.** Do not run `install.cmd`, `protect.cmd`, `live.cmd`, `restore.cmd`,
   `Install.ps1`, `ApplyPolicy.ps1`, `Modes.ps1` or `Restore.ps1`. Do not try to bypass or
   automate the administrator (UAC) prompt. Ask the user to double-click the `.cmd` file and
   click **Yes**.
2. **Never read the user's proxy secrets.** Do not open, print or copy files in the Clash
   Verge Rev data directory (`%APPDATA%\io.github.clash-verge-rev.clash-verge-rev`), and do
   not open the `backup` or `staged` copies in the state directory. They contain
   subscription URLs, passwords, UUIDs and keys. Use `npm run inspect` instead. It prints
   only names, types, servers and ports.
3. **Never delete or edit the state directory** (`%LOCALAPPDATA%\clash-egress-guard\state`,
   or the `stateDir` in `config.local.json`). It holds the only backups of the firewall and
   the Clash files. You may read only `status.json`, `mode-status.json` and `manifest.json`
   there.
4. **Do not change the firewall, Clash settings, subscriptions or services any other way.**
   Never turn off Windows Firewall to fix a problem.
5. **Let the user decide.** Ask which outbound to use and which country the egress should
   be in. Do not guess.
6. Do not commit, upload or paste `config.local.json`.

## Install

1. **Check the prerequisites.** Report anything missing and stop until the user fixes it.
   - Windows 10 or 11.
   - `node -v` prints v20 or later. If it doesn't, ask the user to install Node.js LTS.
   - Clash Verge Rev is installed. The defaults are
     `C:\Program Files\Clash Verge\clash-verge.exe` and `verge-mihomo.exe`.
   - Service mode is running: `Get-Service clash_verge_service` shows `Running`. If it
     doesn't, ask the user to install service mode in Clash Verge Rev's settings.
   - Clash Verge Rev is open, and the user's proxy works.
2. **Get the code and install dependencies:**

   ```bash
   git clone https://github.com/tweetyluckless/clash-egress-guard.git
   ```

   ```bash
   cd clash-egress-guard
   ```

   ```bash
   npm ci
   ```

   ```bash
   npm test
   ```

3. **List the outbounds:**

   ```bash
   npm run inspect
   ```

   Show the user the proxy and group names (and the `selected` member of each group), then
   ask two things:
   - Which outbound must carry all traffic?
   - Which egress country is expected (an ISO code such as `JP`)?

   Also ask whether they know the exact egress IP. It is optional. If `controller` says
   `unavailable`, ask the user to start Clash Verge Rev and run the command again.
4. **Find the first hop:**

   ```bash
   npm run inspect -- --outbound "<name>"
   ```

   - If `problems` is not empty, explain each problem and stop until the user picks another
     outbound or changes Clash. A common case is a group that switches nodes automatically.
   - Pass on any `notes`. For example, changing a select group's choice later breaks the
     guard until the user prepares and installs again.
   - Otherwise, use `suggestedConfig`.
5. **Write the config.** Copy `config.example.json` to `config.local.json`. Set `outbound`,
   `upstream`, `expectedCountry` and, if the user gave one, `expectedIp`. Check that
   `clashExe` and `coreExe` exist. Leave the other fields at their defaults unless the
   user's install is different.
6. **Prepare.** This step makes no system changes. Success prints `"prepared":true`.

   ```bash
   npm run prepare-config
   ```

   - `A preparation already exists`: there is an earlier installation. Delete nothing. Read
     `status.json`, and ask the user whether the guard is still installed.
   - `Unexpected egress`: the outbound does not reach the expected country. Report the IP
     and country, then ask the user what to do.
7. **HANDOFF.** First tell the user how to recover if the network stays down, because you
   won't be able to help while it is down:
   - `live.cmd` restores direct access and keeps the installation.
   - `restore.cmd` removes the guard and restores the firewall and the Clash files.

   Then ask them to double-click `install.cmd` in the project folder and click **Yes** on
   the administrator prompt. Warn them that the network drops for a moment and that you may
   lose your connection. Ask them to tell you when the window shows `"phase": "complete"`
   or an error. Wait for their reply.
8. **Verify.** Read `status.json` in the state directory.
   - If `phase` is `complete`, run `node guard.cjs policy-check` and
     `node guard.cjs direct-check`, then report the egress IP and country.
   - Otherwise, report `details.error` and `details.failedStep`. Don't retry blindly.
     Explain the error and ask the user what to do.
9. **Optional shortcuts.** This command needs no elevation:

   ```bash
   powershell -NoProfile -ExecutionPolicy Bypass -File Create-Shortcuts.ps1
   ```

## Switching modes later

The user switches modes by double-clicking `live.cmd` or `protect.cmd` (or a shortcut) and
approving the prompt. Afterwards, read `mode-status.json`:

- Success is `"phase": "complete"` with the expected `details.effectiveMode`.
- On `"phase": "failed"`, report `details.error` and `details.recovery`.

If `appsToCloseBeforeLive` lists your own process, Live mode refuses to start while you run.
Tell the user before they switch.
