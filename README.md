# OpenClaw Mac Mini Setup

Automated setup for running [OpenClaw](https://github.com/openclaw/openclaw) as a dedicated AI agent on a 2014 Intel Mac mini. A single script installs all dependencies, configures security hardening, and starts the Gateway daemon — reachable via Telegram and powered by free cloud LLMs.

```
┌─────────────────────────────────────────────────────┐
│  Mac Mini (macOS Monterey 12.x, 8GB DDR3)           │
│                                                     │
│  User: openclaw (standard, non-admin)               │
│                                                     │
│  ┌─────────────────┐  ┌──────────────────────────┐  │
│  │ OpenClaw Gateway │  │ Ollama                   │  │
│  │ (Node.js, :18789)│  │ Qwen 3 1.7B (fallback)  │  │
│  │ loopback only    │  │ loopback only (:11434)   │  │
│  └────────┬─────────┘  └──────────────────────────┘  │
│           │                                          │
│  ┌────────┴─────────┐  ┌──────────────────────────┐  │
│  │ Tailscale Serve  │  │ launchd                  │  │
│  │ (HTTPS, tailnet) │  │ (Gateway + Ollama daemons)│  │
│  └──────────────────┘  └──────────────────────────┘  │
└───────────────────────────┬─────────────────────────┘
                            │
              ┌─────────────┼─────────────────┐
              ▼             ▼                 ▼
         Telegram       Groq API        Gemini API
         (channel)      (primary LLM)   (fallback LLM)
```

## Prerequisites

| Requirement | Details |
|-------------|---------|
| Hardware | 2014 Mac mini (Intel i5-4278U, 8GB DDR3) |
| macOS | Monterey 12.x (latest supported for this hardware) |
| Account | An admin user account on the Mac |
| Network | Internet connection (Ethernet recommended for always-on) |
| Telegram | A Telegram account on your phone |
| Tailscale | A Tailscale account ([sign up free](https://login.tailscale.com/start)) |
| Groq API key | Free at [console.groq.com](https://console.groq.com) |
| Gemini API key | Free at [aistudio.google.com/apikey](https://aistudio.google.com/apikey) |

## Before you run

Prepare these before starting the script — it will prompt for each at the right time:

1. **Create a Telegram bot**: Open Telegram, message [@BotFather](https://t.me/BotFather), send `/newbot`, follow the prompts. Copy the bot token.
2. **Get a Groq API key**: Sign up at console.groq.com, go to API Keys, create one.
3. **Get a Gemini API key**: Sign up at aistudio.google.com, click "Create API key".
4. **Tailscale auth key** (optional): Generate one at [login.tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys) to skip browser login. Or just have browser access for interactive login.

## Running the script

```bash
chmod +x setup-openclaw.sh
sudo ./setup-openclaw.sh
```

The script requires `sudo` because it:
- Creates a dedicated `openclaw` macOS user
- Installs Homebrew (system-level on Intel: `/usr/local`)
- Manages system daemons (Tailscale, Ollama via `brew services`)

All OpenClaw-specific commands run as the `openclaw` user via `sudo -u openclaw`.

### Preflight-only mode

To test prerequisites without installing anything:

```bash
sudo ./setup-openclaw.sh --preflight-only
```

### Using an existing user account

By default, the script creates a dedicated `openclaw` user. To use your existing account instead:

```bash
sudo ./setup-openclaw.sh --user yourusername
```

**Note**: Using a personal account means OpenClaw shares your user's permissions. The dedicated `openclaw` user provides better security isolation.

If your account is non-admin, ask an admin to run the command above on your behalf.

## What happens at each phase

| Phase | What it does | Interactive? |
|-------|-------------|--------------|
| 0. Preflight | Checks macOS version, architecture, network, disk space | No |
| 1. Configure user | Creates `openclaw` user or configures existing user (with `--user`) | No |
| 2. Prerequisites | Installs Xcode CLT, Homebrew, nvm, Node.js 22, git | **Yes** — Xcode CLT shows a system dialog (click Install, then Agree) |
| 3. Tailscale | Installs and authenticates Tailscale | **Yes** — paste auth key or open login URL in browser |
| 4. Ollama | Installs Ollama, pulls Qwen 3 1.7B model | No (downloads ~1.2GB) |
| 5. OpenClaw | Installs OpenClaw via npm | No |
| 6. Secrets | Prompts for Groq key, Gemini key, Telegram bot token | **Yes** — paste each key when prompted |
| 7. Configure | Runs `openclaw onboard`, writes hardened config | No |
| 8. Harden | Sets file permissions, runs security audit | No |
| 9. Verify | Runs 10 health checks, prints pass/fail summary | No |

**Estimated total time**: 15–25 minutes (mostly downloading).

## What gets installed

| Component | Location | Purpose |
|-----------|----------|---------|
| `openclaw` user | `/Users/openclaw/` | Dedicated non-admin service account |
| Xcode CLT | System | Build tools (required by Homebrew) |
| Homebrew | `/usr/local/` | Package manager |
| nvm | `/Users/openclaw/.nvm/` | Node.js version manager (per-user) |
| Node.js 22 | `/Users/openclaw/.nvm/versions/` | OpenClaw runtime |
| OpenClaw | npm global (openclaw user) | AI agent framework |
| Ollama | `/usr/local/bin/ollama` | Local LLM inference server |
| Qwen 3 1.7B | `~/.ollama/models/` | Local fallback model (1.2GB) |
| Tailscale | `/usr/local/bin/tailscale` | Secure remote access (WireGuard VPN) |
| OpenClaw config | `/Users/openclaw/.openclaw/` | Config, env, state |

## Security model

The setup follows the hardened baseline from [The definitive guide to setting up OpenClaw securely](OpenClaw%20Setting/The%20definitive%20guide%20to%20setting%20up%20OpenClaw%20securely.md):

### What's locked down

| Surface | Setting | Effect |
|---------|---------|--------|
| Gateway binding | `loopback` | Only reachable on 127.0.0.1 — no network exposure |
| Gateway auth | Token via `$env` ref | Token stored in `.env` file (mode 600), not in config |
| Remote access | Tailscale Serve | HTTPS endpoint visible only on your private tailnet |
| Shell commands | `exec.ask: "always"` | Every shell command requires approval |
| Elevated tools | Disabled | No root-level tool execution |
| Filesystem | `workspaceOnly: true` | Agent can only access its workspace directory |
| Sandbox | `non-main` | Group chats and secondary threads are sandboxed |
| mDNS | Disabled | `OPENCLAW_DISABLE_BONJOUR=1` prevents network metadata leaks |
| Telegram | `dmPolicy: "pairing"` | Unknown senders blocked until you approve them |
| macOS user | Standard (non-admin) | Cannot sudo or install system software |

### Trust boundaries

```
You (phone) ──Telegram──> Bot API ──webhook──> Gateway (loopback)
                                                  │
                                    ┌─────────────┼─────────────┐
                                    ▼             ▼             ▼
                                  Groq         Gemini       Ollama
                                (cloud)       (cloud)      (local)
```

- **What leaves the machine**: Prompts and tool definitions go to Groq and Gemini for inference. Free-tier data policies apply (Groq does not train on prompts; Gemini free tier may use data to improve products).
- **What stays local**: All config, credentials, chat history, agent memory, and any data processed by the Ollama fallback model.

### Skills warning

The script installs **zero community skills**. Before installing any skill from ClawHub, review its contents manually. See the security guide's section on the ClawHavoc campaign and skill vetting.

## RAM budget

Expected memory usage with all services running:

| Component | RAM (approx.) |
|-----------|---------------|
| macOS overhead | 2.0–3.0 GB |
| OpenClaw Gateway | 0.2–0.4 GB |
| Ollama + Qwen 3 1.7B (when loaded) | 1.2–1.5 GB |
| Tailscale daemon | ~50 MB |
| **Total (idle)** | **~3.5–5.0 GB** |
| Browser automation (when active) | +0.5–1.0 GB |

With 8GB total, this leaves 3–4.5GB free at idle. If RAM pressure becomes an issue:
- Ollama unloads models after inactivity (`OLLAMA_MAX_LOADED_MODELS=1` is already set)
- Avoid running browser automation and local model inference simultaneously
- Consider switching to cloud-only by removing `ollama/qwen3:1.7b` from the fallback chain

## Daily operation

### Check status

```bash
sudo -u openclaw -i bash -c 'source ~/.nvm/nvm.sh && source ~/.openclaw/.env && openclaw status'
```

### Open the dashboard

```bash
sudo -u openclaw -i bash -c 'source ~/.nvm/nvm.sh && source ~/.openclaw/.env && openclaw dashboard'
```

### Restart the Gateway

```bash
# Find and restart the launchd service
sudo -u openclaw launchctl kickstart -kp gui/$(id -u openclaw)/ai.openclaw.gateway
```

### View logs

```bash
log show --predicate 'process == "openclaw"' --last 1h
```

### Update OpenClaw

```bash
sudo -u openclaw -i bash -c 'source ~/.nvm/nvm.sh && npm update -g openclaw'
```

### Run a security audit

```bash
sudo -u openclaw -i bash -c 'source ~/.nvm/nvm.sh && source ~/.openclaw/.env && openclaw security audit --deep'
```

## Troubleshooting

### Gateway not running after reboot

The Gateway runs as a launchd LaunchAgent for the `openclaw` user. LaunchAgents only start when the user logs in. Options:

1. **Enable auto-login** for the `openclaw` user (less secure — anyone with physical access can reach the desktop):
   ```bash
   sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser openclaw
   ```
2. **Convert to a LaunchDaemon** (runs without login, but requires root-level plist management). See Apple's [launchd documentation](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html).

### Ollama model not responding

```bash
# Check if Ollama is running
brew services list | grep ollama

# Restart it
brew services restart ollama

# Verify the model is available
curl -s http://localhost:11434/api/tags | grep qwen3
```

### Telegram bot not responding

1. Verify the Gateway is running (`openclaw status`)
2. Check the bot token is correct in `/Users/openclaw/.openclaw/.env`
3. Ensure you've approved the pairing request after sending the first message
4. Check the Gateway logs for errors

### Tailscale disconnected

```bash
# Check status
tailscale status

# Re-authenticate
sudo tailscale up
```

### "Permission denied" errors

```bash
# Re-apply correct ownership and permissions
sudo chown -R openclaw:staff /Users/openclaw/.openclaw/
sudo chmod 700 /Users/openclaw/.openclaw/
sudo find /Users/openclaw/.openclaw/ -type f -exec chmod 600 {} +
sudo find /Users/openclaw/.openclaw/ -type d -exec chmod 700 {} +
```

### Re-running the script

The script is idempotent — it tracks completed phases in `/Users/openclaw/.openclaw/.setup-state`. Re-running skips phases that already succeeded.

To force a phase to re-run, remove its name from the state file:

```bash
sudo nano /Users/openclaw/.openclaw/.setup-state
# Delete the line for the phase you want to re-run, then save
```

To start completely fresh:

```bash
sudo rm /Users/openclaw/.openclaw/.setup-state
sudo ./setup-openclaw.sh
```

## Uninstallation

To cleanly remove everything:

```bash
# 1. Stop services
sudo -u openclaw launchctl bootout gui/$(id -u openclaw)/ai.openclaw.gateway 2>/dev/null
brew services stop ollama
brew services stop tailscale

# 2. Uninstall OpenClaw
sudo -u openclaw -i bash -c 'source ~/.nvm/nvm.sh && npm uninstall -g openclaw'

# 3. Remove Ollama model and service
ollama rm qwen3:1.7b
brew uninstall ollama

# 4. Remove the dedicated user and home directory
sudo sysadminctl -deleteUser openclaw -secure

# 5. (Optional) Remove Tailscale
brew uninstall tailscale

# 6. (Optional) Remove Homebrew entirely
# See https://github.com/homebrew/install#uninstall
```

## Reference

- [Running OpenClaw on an 8GB Intel Mac Mini](OpenClaw%20Setting/Running%20OpenClaw%20on%20an%208GB%20Intel%20Mac%20Mini.md) — hardware analysis, cloud API comparison, model benchmarks
- [The definitive guide to setting up OpenClaw securely](OpenClaw%20Setting/The%20definitive%20guide%20to%20setting%20up%20OpenClaw%20securely.md) — security surfaces, hardening, skill vetting
