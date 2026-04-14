#!/usr/bin/env bash
# setup-openclaw.sh — Automated OpenClaw setup for a 2014 Intel Mac mini
# Targets: macOS Monterey 12.x, i5-4278U, 8GB DDR3
# See README.md for full documentation.
set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────

# User can be overridden via --user flag or OPENCLAW_USER env var
OPENCLAW_USER="${OPENCLAW_USER:-openclaw}"
OPENCLAW_HOME="/Users/${OPENCLAW_USER}"
OPENCLAW_DIR="${OPENCLAW_HOME}/.openclaw"
STATE_FILE="${OPENCLAW_DIR}/.setup-state"
GATEWAY_PORT=18789
OLLAMA_PORT=11434
NVM_VERSION="v0.40.3"
NODE_MAJOR=22
MIN_DISK_GB=5

# Recalculate derived paths after --user override
recalculate_paths() {
  OPENCLAW_HOME="/Users/${OPENCLAW_USER}"
  OPENCLAW_DIR="${OPENCLAW_HOME}/.openclaw"
  STATE_FILE="${OPENCLAW_DIR}/.setup-state"
}

# ── Color / output helpers ───────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()   { printf "${GREEN}[✓]${NC} %s\n" "$*"; }
info()  { printf "${BLUE}[i]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
error() { printf "${RED}[✗]${NC} %s\n" "$*" >&2; }
fatal() { error "$*"; exit 1; }
header(){ printf "\n${BOLD}═══ %s ═══${NC}\n\n" "$*"; }

prompt_continue() {
  printf "${YELLOW}>>> %s${NC}\n" "$1"
  printf "    Press Enter when ready..."
  read -r
}

# ── State management (idempotent re-runs) ────────────────────────────────────

ensure_state_dir() {
  if [[ ! -d "$OPENCLAW_DIR" ]]; then
    mkdir -p "$OPENCLAW_DIR"
    # Will fix ownership after user creation; tolerate root-owned for now.
  fi
}

phase_done() {
  [[ -f "$STATE_FILE" ]] && grep -qx "$1" "$STATE_FILE" 2>/dev/null
}

mark_done() {
  ensure_state_dir
  echo "$1" >> "$STATE_FILE"
  log "Phase '$1' complete."
}

# ── Retry helper ─────────────────────────────────────────────────────────────

retry() {
  local attempts=$1; shift
  local delay=$1; shift
  local n=1
  while true; do
    "$@" && return 0
    if (( n >= attempts )); then
      error "Command failed after $attempts attempts: $*"
      return 1
    fi
    warn "Attempt $n/$attempts failed. Retrying in ${delay}s..."
    sleep "$delay"
    (( n++ ))
  done
}

# ── Run a command as the openclaw user ───────────────────────────────────────

as_openclaw() {
  sudo -u "$OPENCLAW_USER" -i bash -c "$*"
}

# ── Run a command as the invoking admin user (for Homebrew) ──────────────────
# Homebrew refuses to run as root, so we use SUDO_USER (the user who ran sudo)

as_admin() {
  if [[ -z "${SUDO_USER:-}" ]]; then
    fatal "SUDO_USER not set. Run this script with: sudo ./setup-openclaw.sh"
  fi
  sudo -u "$SUDO_USER" bash -c "$*"
}

# ═════════════════════════════════════════════════════════════════════════════
# Phase 0 — Preflight
# ═════════════════════════════════════════════════════════════════════════════

phase_preflight() {
  phase_done "preflight" && { info "Preflight already passed."; return 0; }
  header "Phase 0: Preflight checks"

  # Root check
  if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root."
    info "Requirement: An admin account that can use sudo."
    info "If your account is non-admin, ask an admin to run:"
    info "  sudo ./setup-openclaw.sh --user $(whoami)"
    exit 1
  fi

  # Architecture
  local arch
  arch=$(uname -m)
  if [[ "$arch" != "x86_64" ]]; then
    fatal "Expected Intel (x86_64) but found '$arch'. This script targets the 2014 Intel Mac mini."
  fi
  log "Architecture: $arch"

  # macOS version
  local macos_ver
  macos_ver=$(sw_vers -productVersion)
  local major
  major=$(echo "$macos_ver" | cut -d. -f1)
  if (( major < 12 )); then
    fatal "macOS $macos_ver detected. This script requires macOS 12 (Monterey) or later. Upgrade first."
  fi
  log "macOS version: $macos_ver"

  # Network
  if ! curl -sf --max-time 10 https://registry.npmjs.org/ > /dev/null 2>&1; then
    fatal "No network connectivity. Ensure the Mac mini is connected to the internet."
  fi
  log "Network connectivity: OK"

  # Disk space
  local avail_gb
  avail_gb=$(df -g / | awk 'NR==2 {print $4}')
  if (( avail_gb < MIN_DISK_GB )); then
    fatal "Only ${avail_gb}GB free on /. Need at least ${MIN_DISK_GB}GB for installation."
  fi
  log "Disk space: ${avail_gb}GB available"

  mark_done "preflight"
}

# ═════════════════════════════════════════════════════════════════════════════
# Phase 1 — Create dedicated macOS user
# ═════════════════════════════════════════════════════════════════════════════

phase_create_user() {
  phase_done "create_user" && { info "User '$OPENCLAW_USER' already set up."; return 0; }
  header "Phase 1: Configure user '$OPENCLAW_USER'"

  local user_existed=false
  if dscl . -read "/Users/$OPENCLAW_USER" &>/dev/null; then
    user_existed=true
    log "User '$OPENCLAW_USER' already exists. Using existing account."
  else
    local tmp_pass
    tmp_pass=$(openssl rand -base64 12)
    info "Creating standard (non-admin) user '$OPENCLAW_USER'..."
    sysadminctl -addUser "$OPENCLAW_USER" \
      -fullName "OpenClaw Agent" \
      -password "$tmp_pass" \
      -home "$OPENCLAW_HOME" 2>&1 | grep -v "^$" || true
    log "User created. Temporary password set (not needed for service operation)."
  fi

  # Ensure home directory exists and user can write to it
  if [[ ! -d "$OPENCLAW_HOME" ]]; then
    createhomedir -c -u "$OPENCLAW_USER" 2>/dev/null || mkdir -p "$OPENCLAW_HOME"
    chown "$OPENCLAW_USER":staff "$OPENCLAW_HOME"
  else
    # Home exists — ensure user owns it (non-recursive, safe for existing users)
    # This fixes cases where user was demoted from admin and ownership is broken
    local home_owner
    home_owner=$(stat -f '%Su' "$OPENCLAW_HOME")
    if [[ "$home_owner" != "$OPENCLAW_USER" ]]; then
      warn "Home directory owned by '$home_owner', fixing to '$OPENCLAW_USER'..."
      chown "$OPENCLAW_USER":staff "$OPENCLAW_HOME"
    fi
  fi

  # Verify NOT admin (security check)
  if dseditgroup -o checkmember -m "$OPENCLAW_USER" admin &>/dev/null; then
    warn "User '$OPENCLAW_USER' is in the admin group. Removing for security..."
    dseditgroup -o edit -d "$OPENCLAW_USER" -t user admin
  fi
  log "User '$OPENCLAW_USER' is a standard (non-admin) account."

  # Ensure .openclaw directory exists with correct ownership
  # NOTE: Only chown the .openclaw directory, NOT the entire home directory.
  # Recursive chown on home would fail on TCC-protected ~/Library paths.
  mkdir -p "$OPENCLAW_DIR"
  chown -R "$OPENCLAW_USER":staff "$OPENCLAW_DIR"

  mark_done "create_user"
}

# ═════════════════════════════════════════════════════════════════════════════
# Phase 2 — Install prerequisites
# ═════════════════════════════════════════════════════════════════════════════

phase_prerequisites() {
  phase_done "prerequisites" && { info "Prerequisites already installed."; return 0; }
  header "Phase 2: Install prerequisites"

  # ── Xcode Command Line Tools ──
  if xcode-select -p &>/dev/null; then
    log "Xcode CLT already installed."
  else
    info "Installing Xcode Command Line Tools..."
    info "A system dialog will appear. Click 'Install' then 'Agree'."
    xcode-select --install 2>/dev/null || true
    # Wait for installation to complete
    until xcode-select -p &>/dev/null; do
      sleep 5
    done
    log "Xcode CLT installed."
  fi

  # ── Homebrew (must run as non-root user) ──
  if command -v brew &>/dev/null; then
    log "Homebrew already installed. Updating..."
    as_admin "brew update" 2>/dev/null || true
  else
    info "Installing Homebrew (non-interactive)..."
    as_admin "NONINTERACTIVE=1 /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    log "Homebrew installed."
  fi
  # Ensure brew is on PATH for this session (Intel: /usr/local/bin)
  eval "$(/usr/local/bin/brew shellenv 2>/dev/null || true)"

  # ── git ──
  if command -v git &>/dev/null; then
    log "git already available: $(git --version)"
  else
    info "Installing git..."
    as_admin "brew install git"
    log "git installed."
  fi

  # ── nvm (installed for the openclaw user) ──
  local nvm_dir="${OPENCLAW_HOME}/.nvm"
  if [[ -d "$nvm_dir" ]]; then
    log "nvm already installed for $OPENCLAW_USER."
  else
    info "Installing nvm ${NVM_VERSION} for $OPENCLAW_USER..."
    as_openclaw "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh | bash"
    log "nvm installed."
  fi

  # ── Node.js 22 ──
  local node_ver
  node_ver=$(as_openclaw "source ~/.nvm/nvm.sh && node --version 2>/dev/null" || echo "none")
  if [[ "$node_ver" == v${NODE_MAJOR}.* ]]; then
    log "Node.js $node_ver already installed for $OPENCLAW_USER."
  else
    info "Installing Node.js ${NODE_MAJOR} via nvm..."
    as_openclaw "source ~/.nvm/nvm.sh && nvm install ${NODE_MAJOR} && nvm alias default ${NODE_MAJOR}"
    node_ver=$(as_openclaw "source ~/.nvm/nvm.sh && node --version")
    log "Node.js $node_ver installed."
  fi

  mark_done "prerequisites"
}

# ═════════════════════════════════════════════════════════════════════════════
# Phase 3 — Install Tailscale
# ═════════════════════════════════════════════════════════════════════════════

phase_tailscale() {
  phase_done "tailscale" && { info "Tailscale already configured."; return 0; }
  header "Phase 3: Install & configure Tailscale"

  if command -v tailscale &>/dev/null; then
    log "Tailscale already installed."
  else
    info "Installing Tailscale via Homebrew..."
    as_admin "brew install tailscale"
    log "Tailscale installed."
  fi

  # Start the daemon
  if ! pgrep -x tailscaled &>/dev/null; then
    info "Starting tailscaled..."
    as_admin "brew services start tailscale" 2>/dev/null || true
    sleep 3
  fi

  # Verify tailscaled is running before attempting auth
  local daemon_tries=0
  while ! tailscale status &>/dev/null 2>&1; do
    (( daemon_tries++ ))
    if (( daemon_tries > 10 )); then
      error "tailscaled daemon not responding. Checking status..."
      as_admin "brew services list" | grep tailscale || true
      fatal "Cannot connect to tailscaled. Try: brew services restart tailscale"
    fi
    info "Waiting for tailscaled to start..."
    sleep 2
  done

  # Check if already authenticated
  if tailscale status 2>&1 | grep -q "Tailscale is stopped"; then
    echo ""
    info "Tailscale needs authentication."
    printf "    Do you have a pre-generated Tailscale auth key?\n"
    printf "    Paste it now, or press Enter for browser login: "
    read -r ts_key
    echo ""

    if [[ -n "$ts_key" ]]; then
      tailscale up --auth-key "$ts_key" || fatal "Tailscale auth failed. Check your auth key."
    else
      info "Opening Tailscale login. A URL will appear — open it in a browser on any device."
      info "After authenticating in browser, the script will continue automatically."
      echo ""
      # Run in foreground, show output to user
      if ! tailscale up 2>&1; then
        error "Tailscale up failed. You can retry manually with: sudo tailscale up"
        fatal "Tailscale authentication failed."
      fi
    fi

    # Wait for connection
    local tries=0
    while ! tailscale status 2>&1 | grep -qE "^[0-9]"; do
      (( tries++ ))
      if (( tries > 60 )); then
        fatal "Tailscale did not connect after 5 minutes. Re-run the script to retry."
      fi
      sleep 5
    done
    log "Tailscale connected."
  else
    log "Tailscale already authenticated and running."
  fi

  mark_done "tailscale"
}

# ═════════════════════════════════════════════════════════════════════════════
# Phase 4 — Install Ollama
# ═════════════════════════════════════════════════════════════════════════════

phase_ollama() {
  phase_done "ollama" && { info "Ollama already set up."; return 0; }
  header "Phase 4: Install Ollama + Qwen 3 1.7B"

  if command -v ollama &>/dev/null; then
    log "Ollama already installed."
  else
    info "Installing Ollama via Homebrew..."
    as_admin "brew install ollama"
    log "Ollama installed."
  fi

  # Write Ollama environment config for 8GB Intel Mac
  local ollama_env_file="/usr/local/etc/ollama/environment"
  mkdir -p "$(dirname "$ollama_env_file")"
  cat > "$ollama_env_file" <<'ENVEOF'
OLLAMA_MAX_LOADED_MODELS=1
OLLAMA_NUM_PARALLEL=1
OLLAMA_FLASH_ATTENTION=1
OLLAMA_KV_CACHE_TYPE=q8_0
ENVEOF
  log "Ollama environment configured for 8GB Intel."

  # Start Ollama
  if ! curl -sf --max-time 5 "http://localhost:${OLLAMA_PORT}/api/tags" &>/dev/null; then
    info "Starting Ollama service..."
    as_admin "brew services start ollama" 2>/dev/null || true
    # Wait for API to be ready
    local tries=0
    while ! curl -sf --max-time 3 "http://localhost:${OLLAMA_PORT}/api/tags" &>/dev/null; do
      (( tries++ ))
      if (( tries > 30 )); then
        warn "Ollama did not start within 90s. Continuing — you can pull the model manually later."
        mark_done "ollama"
        return 0
      fi
      sleep 3
    done
  fi
  log "Ollama is running."

  # Pull the model
  local has_model
  has_model=$(curl -sf "http://localhost:${OLLAMA_PORT}/api/tags" | grep -c "qwen3:1.7b" || true)
  if (( has_model > 0 )); then
    log "Model qwen3:1.7b already pulled."
  else
    info "Pulling qwen3:1.7b (~1.2 GB). This may take a few minutes..."
    retry 2 10 ollama pull qwen3:1.7b
    log "Model qwen3:1.7b ready."
  fi

  mark_done "ollama"
}

# ═════════════════════════════════════════════════════════════════════════════
# Phase 5 — Install OpenClaw
# ═════════════════════════════════════════════════════════════════════════════

phase_install_openclaw() {
  phase_done "install_openclaw" && { info "OpenClaw already installed."; return 0; }
  header "Phase 5: Install OpenClaw"

  local oc_ver
  oc_ver=$(as_openclaw "source ~/.nvm/nvm.sh && openclaw --version 2>/dev/null" || echo "none")
  if [[ "$oc_ver" != "none" ]]; then
    log "OpenClaw $oc_ver already installed. Upgrading..."
    as_openclaw "source ~/.nvm/nvm.sh && npm update -g openclaw"
  else
    info "Installing OpenClaw via npm..."
    as_openclaw "source ~/.nvm/nvm.sh && npm install -g openclaw@latest"
  fi

  oc_ver=$(as_openclaw "source ~/.nvm/nvm.sh && openclaw --version")
  log "OpenClaw $oc_ver installed."

  mark_done "install_openclaw"
}

# ═════════════════════════════════════════════════════════════════════════════
# Phase 6 — Collect secrets
# ═════════════════════════════════════════════════════════════════════════════

phase_collect_secrets() {
  local env_file="${OPENCLAW_DIR}/.env"
  phase_done "collect_secrets" && { info "Secrets already collected. To re-enter, delete '$env_file' and remove 'collect_secrets' from $STATE_FILE."; return 0; }
  header "Phase 6: Collect API keys & Telegram bot token"

  echo ""
  info "You'll need three things. Instructions for each are shown below."
  echo ""

  # ── Groq API key ──
  printf '%b\n' "${BOLD}1) Groq API Key${NC}"
  printf "   Sign up free at https://console.groq.com\n"
  printf "   Go to API Keys > Create API Key > copy it.\n"
  printf "   Enter Groq API key: "
  read -rs groq_key
  echo ""
  [[ -z "$groq_key" ]] && fatal "Groq API key cannot be empty."

  # ── Gemini API key ──
  printf '%b\n' "${BOLD}2) Google Gemini API Key${NC}"
  printf "   Sign up free at https://aistudio.google.com/apikey\n"
  printf "   Click 'Create API key' > copy it.\n"
  printf "   Enter Gemini API key: "
  read -rs gemini_key
  echo ""
  [[ -z "$gemini_key" ]] && fatal "Gemini API key cannot be empty."

  # ── Telegram bot token ──
  printf '%b\n' "${BOLD}3) Telegram Bot Token${NC}"
  printf "   Open Telegram and message @BotFather.\n"
  printf "   Send /newbot, follow the prompts, copy the token.\n"
  printf "   Enter Telegram bot token: "
  read -rs tg_token
  echo ""
  [[ -z "$tg_token" ]] && fatal "Telegram bot token cannot be empty."

  # ── Generate gateway token ──
  local gw_token
  gw_token=$(openssl rand -hex 32)
  info "Generated gateway authentication token."

  # ── Write .env file ──
  cat > "$env_file" <<ENVEOF
# OpenClaw environment — created by setup-openclaw.sh
# Do not share this file. Permissions should be 0600.
OPENCLAW_GATEWAY_TOKEN=${gw_token}
GROQ_API_KEY=${groq_key}
GEMINI_API_KEY=${gemini_key}
TELEGRAM_BOT_TOKEN=${tg_token}
OPENCLAW_DISABLE_BONJOUR=1
ENVEOF

  chown "$OPENCLAW_USER":staff "$env_file"
  chmod 600 "$env_file"
  log "Secrets written to $env_file (mode 600)."

  mark_done "collect_secrets"
}

# ═════════════════════════════════════════════════════════════════════════════
# Phase 7 — Configure OpenClaw
# ═════════════════════════════════════════════════════════════════════════════

phase_configure_openclaw() {
  phase_done "configure_openclaw" && { info "OpenClaw already configured."; return 0; }
  header "Phase 7: Configure OpenClaw"

  # Run non-interactive onboard to create baseline config and install daemon
  info "Running OpenClaw onboard (non-interactive)..."
  as_openclaw "source ~/.nvm/nvm.sh && source ~/.openclaw/.env && openclaw onboard --non-interactive \
    --mode local \
    --gateway-port ${GATEWAY_PORT} \
    --gateway-bind loopback \
    --install-daemon" || warn "Onboard exited with warnings — continuing with manual config."

  # Write the hardened configuration, overriding onboard defaults
  local config_file="${OPENCLAW_DIR}/openclaw.json"
  info "Writing hardened openclaw.json..."
  cat > "$config_file" <<'CFGEOF'
{
  "gateway": {
    "mode": "local",
    "bind": "loopback",
    "port": 18789,
    "auth": {
      "mode": "token",
      "token": { "$env": "OPENCLAW_GATEWAY_TOKEN" }
    },
    "tailscale": { "mode": "serve" },
    "controlUi": { "dangerouslyDisableDeviceAuth": false }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "groq/llama-3.3-70b-versatile",
        "fallbacks": [
          "google/gemini-2.5-flash",
          "ollama/qwen3:1.7b"
        ]
      },
      "maxConcurrent": 2,
      "sandbox": { "mode": "non-main", "scope": "session" },
      "heartbeat": {
        "every": "30m",
        "lightContext": true,
        "isolatedSession": true
      }
    }
  },
  "models": {
    "providers": {
      "groq": {
        "baseUrl": "https://api.groq.com/openai/v1",
        "apiKey": { "$env": "GROQ_API_KEY" },
        "api": "openai-completions",
        "models": [{
          "id": "llama-3.3-70b-versatile",
          "name": "Llama 3.3 70B (Groq)",
          "reasoning": false,
          "input": ["text"],
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
          "contextWindow": 128000,
          "maxTokens": 8192
        }]
      },
      "google": {
        "apiKey": { "$env": "GEMINI_API_KEY" },
        "models": [{
          "id": "gemini-2.5-flash",
          "name": "Gemini 2.5 Flash",
          "reasoning": false,
          "input": ["text"],
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
          "contextWindow": 1000000,
          "maxTokens": 8192
        }]
      },
      "ollama": {
        "baseUrl": "http://127.0.0.1:11434/v1",
        "apiKey": "ollama-local",
        "api": "openai-completions",
        "models": [{
          "id": "qwen3:1.7b",
          "name": "Qwen3 1.7B Local",
          "reasoning": false,
          "input": ["text"],
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
          "contextWindow": 4096,
          "maxTokens": 2048
        }]
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
    "telegram": {
      "botToken": { "$env": "TELEGRAM_BOT_TOKEN" },
      "dmPolicy": "pairing",
      "groups": { "*": { "requireMention": true } }
    }
  }
}
CFGEOF

  chown "$OPENCLAW_USER":staff "$config_file"
  chmod 600 "$config_file"
  log "Hardened configuration written to $config_file"

  mark_done "configure_openclaw"
}

# ═════════════════════════════════════════════════════════════════════════════
# Phase 8 — Security hardening
# ═════════════════════════════════════════════════════════════════════════════

phase_harden() {
  phase_done "harden" && { info "Security hardening already applied."; return 0; }
  header "Phase 8: Security hardening"

  # File permissions
  info "Setting file permissions..."
  chmod 700 "$OPENCLAW_DIR"
  find "$OPENCLAW_DIR" -type f -exec chmod 600 {} +
  find "$OPENCLAW_DIR" -type d -exec chmod 700 {} +
  chown -R "$OPENCLAW_USER":staff "$OPENCLAW_DIR"
  log "Permissions: directories 700, files 600, owned by $OPENCLAW_USER."

  # Source env for openclaw commands
  info "Running OpenClaw security audit..."
  as_openclaw "source ~/.nvm/nvm.sh && source ~/.openclaw/.env && openclaw security audit --fix" \
    || warn "Security audit --fix reported issues. Review output above."

  mark_done "harden"
}

# ═════════════════════════════════════════════════════════════════════════════
# Phase 9 — Verification
# ═════════════════════════════════════════════════════════════════════════════

phase_verify() {
  header "Phase 9: Verification"

  local pass=0 fail=0

  check() {
    local label="$1"; shift
    if "$@" &>/dev/null; then
      printf "  ${GREEN}PASS${NC}  %s\n" "$label"
      (( pass++ ))
    else
      printf "  ${RED}FAIL${NC}  %s\n" "$label"
      (( fail++ ))
    fi
  }

  echo ""

  # 1. OpenClaw doctor
  check "openclaw doctor" \
    as_openclaw "source ~/.nvm/nvm.sh && source ~/.openclaw/.env && openclaw doctor"

  # 2. OpenClaw status
  check "openclaw status" \
    as_openclaw "source ~/.nvm/nvm.sh && source ~/.openclaw/.env && openclaw status"

  # 3. Security audit (just check exit code — --deep may warn without failing)
  check "openclaw security audit" \
    as_openclaw "source ~/.nvm/nvm.sh && source ~/.openclaw/.env && openclaw security audit --deep"

  # 4. Tailscale
  check "tailscale connected" tailscale status

  # 5. Ollama
  check "ollama running" curl -sf --max-time 5 "http://localhost:${OLLAMA_PORT}/api/tags"

  # 6. Ollama model present
  check "qwen3:1.7b model loaded" bash -c \
    "curl -sf http://localhost:${OLLAMA_PORT}/api/tags | grep -q qwen3"

  # 7. Config file permissions
  check "openclaw.json permissions (600)" bash -c \
    "[[ \$(stat -f '%Lp' '${OPENCLAW_DIR}/openclaw.json') == '600' ]]"

  # 8. .env file permissions
  check ".env permissions (600)" bash -c \
    "[[ \$(stat -f '%Lp' '${OPENCLAW_DIR}/.env') == '600' ]]"

  # 9. Directory permissions
  check ".openclaw/ permissions (700)" bash -c \
    "[[ \$(stat -f '%Lp' '${OPENCLAW_DIR}') == '700' ]]"

  # 10. User is not admin
  check "openclaw user is non-admin" bash -c \
    "! dseditgroup -o checkmember -m ${OPENCLAW_USER} admin"

  echo ""
  printf '  %bResults: %b%d passed%b, %b%d failed%b\n' "$BOLD" "$GREEN" "$pass" "$NC" "$RED" "$fail" "$NC"
  echo ""

  if (( fail > 0 )); then
    warn "Some checks failed. Review the output above and consult README.md troubleshooting."
  fi

  # Final instructions
  echo ""
  printf '%b\n\n' "${BOLD}═══ Setup complete ═══${NC}"
  info "What to do next:"
  echo "  1. Open Telegram and send a message to your bot."
  echo "     The first message will trigger a pairing request."
  echo "     Approve it from the OpenClaw dashboard or CLI."
  echo ""
  echo "  2. To open the dashboard:"
  echo "     sudo -u $OPENCLAW_USER -i bash -c 'source ~/.nvm/nvm.sh && source ~/.openclaw/.env && openclaw dashboard'"
  echo ""
  echo "  3. To check status anytime:"
  echo "     sudo -u $OPENCLAW_USER -i bash -c 'source ~/.nvm/nvm.sh && source ~/.openclaw/.env && openclaw status'"
  echo ""
  echo "  4. The gateway token for remote access is stored in:"
  echo "     ${OPENCLAW_DIR}/.env"
  echo ""
  info "See README.md for daily operation, troubleshooting, and uninstallation."
}

# ═════════════════════════════════════════════════════════════════════════════
# Main — run all phases in order
# ═════════════════════════════════════════════════════════════════════════════

main() {
  local preflight_only=false

  # Parse command-line arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user)
        if [[ -z "${2:-}" ]]; then
          fatal "--user requires a username argument"
        fi
        OPENCLAW_USER="$2"
        recalculate_paths
        shift 2
        ;;
      --preflight-only)
        preflight_only=true
        shift
        ;;
      -h|--help)
        echo "Usage: sudo ./setup-openclaw.sh [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --user USERNAME    Use existing user instead of creating 'openclaw'"
        echo "  --preflight-only   Run preflight checks only, don't install"
        echo "  -h, --help         Show this help message"
        exit 0
        ;;
      *)
        fatal "Unknown option: $1. Use --help for usage."
        ;;
    esac
  done

  echo ""
  printf '%b\n' "${BOLD}OpenClaw Setup for Intel Mac Mini${NC}"
  printf "Targeting macOS Monterey • Groq + Gemini + Ollama • Telegram\n"
  if [[ "$OPENCLAW_USER" != "openclaw" ]]; then
    info "Using existing user: $OPENCLAW_USER"
  fi
  echo ""

  # --preflight-only flag for dry testing
  if [[ "$preflight_only" == true ]]; then
    phase_preflight
    log "Preflight passed. Exiting without installing."
    exit 0
  fi

  phase_preflight
  phase_create_user
  phase_prerequisites
  phase_tailscale
  phase_ollama
  phase_install_openclaw
  phase_collect_secrets
  phase_configure_openclaw
  phase_harden
  phase_verify
}

main "$@"
