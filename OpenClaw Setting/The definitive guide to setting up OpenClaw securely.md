# The definitive guide to setting up OpenClaw securely

OpenClaw is the fastest-growing open-source AI agent in history — and one of the most dangerous tools to misconfigure. This MIT-licensed personal assistant runs on your machine with shell access, browser control, file operations, and email/calendar management, all triggered through messaging apps like WhatsApp, Telegram, and Discord. With 310,000+ GitHub stars and tens of thousands of live deployments, it has become critical infrastructure for developers and power users. Yet security researchers have found over 42,000 publicly exposed instances, most with authentication bypasses. This guide covers every layer of setup and hardening — from first install to production-grade defense — drawing from official documentation, the project's own security team, and battle-tested community guides.

OpenClaw (formerly Clawdbot, then Moltbot) was created by Austrian developer Peter Steinberger and first published in November 2025. The core architecture is a single long-running Node.js process called the Gateway, which listens on port 18789 and acts as the control plane for all messaging channels, agent sessions, tool dispatch, and state persistence. Configuration, memory, and skills are stored as Markdown and JSON files in `~/.openclaw/`. It connects to external LLMs (Claude, GPT, Gemini, DeepSeek, or local models via Ollama) and extends capabilities through a portable skill system. The security model assumes one trusted operator per gateway — there is no separate governance layer between a misconfigured gateway and a live agent acting on production systems.

## Choosing your installation method matters more than you think

OpenClaw offers six primary installation paths, each with different security profiles. The right choice depends on your technical comfort, deployment target, and how much you want pre-hardened for you.

**Quick install script** is the fastest path. On macOS or Linux, run `curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh | bash`. On Windows, use PowerShell: `iwr -useb https://openclaw.ai/install.ps1 | iex`. The script detects Node.js (22+ required, 24 recommended), installs the CLI globally via npm, and launches the onboarding wizard. For environments where piping to bash is unacceptable, install manually with `npm install -g openclaw@latest` followed by `openclaw onboard --install-daemon`.

**From source** gives full auditability. Clone the repository (`git clone https://github.com/openclaw/openclaw.git`), install with `pnpm install`, build with `pnpm build`, then link globally. This is the path for anyone who wants to read every line before execution — and given that fake OpenClaw repositories distributing GhostSocks malware have been documented in the wild, verifying you're cloning from `github.com/openclaw/openclaw` is a non-trivial security step.

**Docker** provides container isolation out of the box. Run `./scripts/docker/setup.sh` from the cloned repo, or pull the official image directly: `ghcr.io/openclaw/openclaw:latest`. Docker Compose exposes ports 18789 (Gateway) and 18790 (Bridge), with persistence via bind-mounted volumes for `~/.openclaw` and the workspace directory. One critical detail for browser automation: set `shm_size: '2gb'` and mount `/dev/shm` in your compose file — without this, headless Chromium crashes silently inside the container.

**DigitalOcean 1-Click Deploy** is the most security-hardened turnkey option, starting at $24/month. The image ships with a pre-generated gateway token, hardened firewall rules, non-root execution (dedicated `openclaw` system user), Docker container isolation, Caddy reverse proxy with automatic TLS, and Fail2ban. The config file lives at `/opt/openclaw.env` and is owned by root, meaning the agent user cannot modify its own credentials — a meaningful defense-in-depth choice.

**Nix** (`openclaw/nix-openclaw`) delivers fully declarative, reproducible configuration. Every dependency is locked. Updates happen via `home-manager switch`; rollbacks are instant via `home-manager generations`. **NVIDIA NemoClaw** wraps OpenClaw in Landlock, seccomp, and network namespace isolation using the NVIDIA OpenShell runtime — the strongest sandbox option available, though still in early preview as of March 2026.

## The onboarding wizard and what it actually configures

Running `openclaw onboard` launches a guided TUI that sets up everything: Gateway binding, authentication, LLM provider, messaging channels, workspace, skills, and daemon installation. The wizard offers QuickStart (sensible defaults) and Advanced (full control) modes.

The most security-relevant decisions happen early. The wizard asks for a bind mode — choose `loopback` (binds to `127.0.0.1` only) unless you have a specific reason not to. It generates a gateway authentication token automatically; this is the shared secret that protects your entire agent. It asks for your LLM provider — Anthropic API key is the default recommendation, but OpenAI, Google Gemini, Ollama (local), and dozens of others are supported. Use `--secret-input-mode ref` to store API keys as environment variable references rather than plaintext in the config file.

Channel setup follows. Telegram is the fastest to connect (create a bot via @BotFather, paste the token). WhatsApp requires scanning a QR code from Settings → Linked Devices. Discord requires creating a bot application in the Developer Portal with Message Content Intent enabled. Each channel defaults to a pairing policy for DMs — unknown senders receive a short-lived code they must share with you for approval before the bot responds.

The final step installs the Gateway as a system daemon: launchd on macOS, systemd on Linux, a Windows Service on Windows. The `--install-daemon` flag handles this automatically. After installation, verify everything with `openclaw doctor` (config audit), `openclaw status` (gateway health), and `openclaw dashboard` (opens the Control UI in your browser). For non-interactive deployments (CI/CD, automation), the wizard accepts all parameters as flags:

```bash
openclaw onboard --non-interactive \
  --mode local \
  --auth-choice apiKey \
  --anthropic-api-key "$ANTHROPIC_API_KEY" \
  --gateway-port 18789 \
  --gateway-bind loopback \
  --install-daemon
```

## Six security surfaces that determine your exposure

OpenClaw's security model is best understood as a dependency chain of six control surfaces, where failure at any lower layer undermines everything above it.

**Host-level control** is the foundation. The `~/.openclaw/` directory contains your config, credentials, chat history, and agent memory. File permissions must be restricted to `0600` for sensitive files and `700` for the state directory. Never run OpenClaw as root — use a dedicated system user. Environment variables are visible to any process with shell access on the same machine, which means API keys stored in `.env` are exposed if an agent has unrestricted `exec` permission. The DigitalOcean 1-Click image addresses this by running as a non-root user whose config is owned by root.

**Channel access and sender control** determines who can trigger your agent. The pairing model is strong by default: unknown DM senders are blocked until manually approved. The most common mistake is weakening this — setting `dmPolicy: "open"` or `allowFrom: ["*"]` to avoid friction. In group chats, enable mention gating (`requireMention: true`) so the bot only responds when explicitly tagged. Set `contextVisibility: "allowlist"` or `"allowlist_quote"` to prevent supplemental context from non-allowlisted senders from being injected into the agent's prompt.

**Tool permissions and execution risk** carry the most consequential blast radius. OpenClaw's sandbox has three modes: `"off"` (all tools run directly on host), `"non-main"` (group chats and secondary threads sandboxed in Docker; primary session on host), and `"all"` (every session sandboxed). The exec approval system is a critical safety interlock — configure `tools.exec.ask: "always"` to require human approval for every shell command, or use allowlists to pre-approve known-safe binaries. Commands flagged as `elevated` always run on the host even when sandboxed, so `tools.elevated.enabled: false` is the safest default. The sandbox fails closed: if Docker isn't available but sandbox mode is on, the tool throws an error rather than silently falling back to host execution.

**Gateway exposure** is where most real-world compromises happen. Binding to `0.0.0.0` without authentication exposes your agent — and everything it can access — to the internet. A Shodan scan in January 2026 found nearly 1,000 publicly accessible instances with zero authentication. Security researcher Jamieson O'Reilly demonstrated trivially accessing Anthropic API keys, Telegram tokens, Slack accounts, and months of chat histories from exposed gateways. The ClawJacked vulnerability showed that even localhost binding wasn't safe: malicious website JavaScript could open a WebSocket to `127.0.0.1:18789`, brute-force the password (rate limiter exempted localhost), and silently register as a trusted device. This was patched within 24 hours but illustrates the attack surface.

## How to lock down remote access properly

The Gateway should always bind to `127.0.0.1` (the default `loopback` mode). Remote access should flow through a secure tunnel, never direct port exposure.

**Tailscale** has first-class integration. Setting `gateway.tailscale.mode: "serve"` uses Tailscale Serve to create an HTTPS endpoint visible only to devices on your private tailnet. No port forwarding, no certificate management, no public exposure. The Gateway authenticates requests using Tailscale identity headers (`tailscale-user-login`), verified against the local Tailscale daemon. This is the recommended approach for most users. Avoid `"funnel"` mode, which exposes the Gateway to the public internet — the security audit flags `gateway.tailscale_funnel` as a critical finding.

**SSH tunneling** is the alternative. Keep the Gateway on loopback and tunnel from your remote machine: `ssh -N -L 18789:127.0.0.1:18789 user@host`. SSH over Tailscale adds WireGuard encryption end-to-end.

**Reverse proxy setups** (Caddy or nginx) should terminate TLS at the proxy, set `X-Forwarded-For` to `$remote_addr` (not `$proxy_add_x_forwarded_for`, which preserves untrusted headers), and configure `gateway.trustedProxies` tightly. For non-loopback Control UI access, `gateway.controlUi.allowedOrigins` must list your specific proxy URL — never set it to `["*"]`. Rate limiting at the proxy layer is critical for preventing runaway API costs from brute-force or DoS attempts.

## Skill vetting is your biggest supply chain risk

OpenClaw's skill system — directories containing a `SKILL.md` file with metadata and tool instructions — is the project's most powerful feature and its most dangerous attack surface. Installing a ClawHub skill is operationally equivalent to running third-party code on your server with your credentials.

The ClawHavoc campaign in January 2026 planted hundreds of malicious skills on ClawHub containing Atomic Stealer payloads that harvested API keys, injected keyloggers, and wrote malicious content into `MEMORY.md` and `SOUL.md` for persistent cross-session effect. Cisco's AI security team analyzed 31,000 agent skills and found 26% contained at least one vulnerability, with critical findings including active data exfiltration via silent `curl` calls and direct prompt injection. The ClawHub registry has had minimal moderation infrastructure — as one OpenClaw maintainer warned on Discord, "if you can't understand how to run a command line, this is far too dangerous of a project for you to use safely."

Before installing any skill, review its contents manually. Search for dangerous patterns: `exec`, `spawn`, `child_process`, `subprocess`, `fetch`, `axios`, `process.env`, `SECRET`, `KEY`, `TOKEN`. Use Cisco's open-source Skill Scanner (`github.com/cisco-ai-defense/skill-scanner`) for automated static and behavioral analysis. Maintain blocklists of known malicious skill names and watch for typosquats (`clawdhub`, `clawhud`, `clawhubb`). The safest practice is to fork and audit every skill before installing, treating the entire ClawHub registry as untrusted by default.

## A hardened baseline configuration to start from

The official security documentation and community hardening guides converge on a concrete starting configuration. This baseline locks down the most common attack vectors while remaining functional for personal use:

```json
{
  "gateway": {
    "mode": "local",
    "bind": "loopback",
    "auth": {
      "mode": "token",
      "token": { "$env": "OPENCLAW_GATEWAY_TOKEN" }
    },
    "tailscale": { "mode": "serve" },
    "controlUi": { "dangerouslyDisableDeviceAuth": false }
  },
  "agents": {
    "defaults": {
      "sandbox": { "mode": "non-main", "scope": "session" },
      "heartbeat": {
        "every": "30m",
        "lightContext": true,
        "isolatedSession": true
      }
    }
  },
  "tools": {
    "exec": {
      "security": "allowlist",
      "ask": "always"
    },
    "elevated": { "enabled": false },
    "fs": { "workspaceOnly": true }
  },
  "channels": {
    "whatsapp": {
      "dmPolicy": "pairing",
      "groups": { "*": { "requireMention": true } }
    }
  }
}
```

Store your gateway token in an environment variable, not the config file. Set provider-side API spending limits — Anthropic and OpenAI both support hard caps in their billing dashboards. Run `openclaw security audit --deep` after every configuration change and after every skill install. Use `openclaw sandbox explain` to verify the effective sandbox and tool policy for any agent session. Back up `~/.openclaw/workspace/` as a git repository with nightly automated commits. Disable mDNS broadcasting with `OPENCLAW_DISABLE_BONJOUR=1` to avoid leaking infrastructure metadata on local networks.

## Conclusion: security is configuration discipline

OpenClaw's security model is fundamentally trust-the-operator. There is no cloud governance layer, no managed policy engine, no safety net between a misconfigured `openclaw.json` and an agent with root-equivalent power. The defaults have improved significantly — gateway auth is now fail-closed, pairing is on by default, the security audit tool catches common mistakes — but the architecture places the burden squarely on whoever runs the gateway.

The three most impactful hardening steps, in order: never bind to anything other than loopback (use Tailscale Serve or SSH tunnels for remote access), keep sandbox mode at `"non-main"` or higher with exec approvals set to `"always"`, and audit every skill before installation as if it were untrusted code execution — because it is. For teams evaluating OpenClaw for production, the SlowMist 3-Tier Defense Matrix and Fernando Lucktemberg's progressive hardening guide provide the most concrete, command-level implementation paths available. NVIDIA NemoClaw offers the strongest isolation for those willing to accept its early-preview status. The project's dedicated security lead (Jamieson O'Reilly, founder of Dvuln) and active vulnerability disclosure process via `security@openclaw.ai` signal genuine commitment to improving the security posture — but as of April 2026, deploying OpenClaw safely still requires meaningful infrastructure expertise and ongoing operational vigilance.
