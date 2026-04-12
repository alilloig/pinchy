# Running OpenClaw on an 8GB Intel Mac Mini: the honest guide

Local LLM inference on an Intel i5 Mac Mini with 8GB DDR3 is technically possible but practically unsuitable for OpenClaw's agent workloads. OpenClaw's system prompt alone consumes ~17K tokens, its recommended minimum context window is 64K, and its community consensus holds that reliable tool-calling requires 32B+ parameter models. None of these requirements can be met locally on this hardware. The good news: OpenClaw's Gateway daemon needs only 2–4GB RAM and runs perfectly on this Mac Mini — the solution is to pair it with free cloud APIs that provide the heavy inference, optionally supplemented by a tiny local model for simple tasks.

This guide covers what actually works, what doesn't, and how to configure a practical zero-cost setup on exactly this hardware.

## Your Mac Mini's real limits for local inference

The Intel i5-4278U (Haswell, dual-core with hyperthreading) paired with DDR3-1600 delivers roughly 15–18 GB/s effective memory bandwidth. Since LLM inference is almost entirely memory-bandwidth-bound, this caps token generation speeds regardless of model quality. After macOS claims ~2–3GB, roughly 5–5.5GB remains for the model, KV cache, and compute buffers.

Here's what that budget actually buys:

| Configuration | Model Size | KV Cache (2K ctx) | Buffers | Total RAM | Speed (est.) | Verdict |
|---|---|---|---|---|---|---|
| Qwen 3 1.7B Q4_K_M | ~1.2 GB | ~120 MB | ~0.4 GB | ~1.7 GB | 8–12 tok/s | ✅ Comfortable |
| Qwen 2.5 3B Q4_K_M | ~2.0 GB | ~230 MB | ~0.4 GB | ~2.6 GB | 3–6 tok/s | ✅ Usable |
| Qwen 3 4B Q4_K_M | ~2.5 GB | ~300 MB | ~0.4 GB | ~3.2 GB | 3–5 tok/s | ✅ Usable |
| Mistral 7B Q3_K_S (GQA) | ~3.4 GB | ~500 MB | ~0.5 GB | ~4.4 GB | 2–3 tok/s | ⚠️ Tight |
| Any 7B Q4_K_M | ~4.5 GB | ~1.0 GB | ~0.5 GB | ~6.0 GB | 1.5–3 tok/s | ❌ Swap risk |

Context window is the critical bottleneck. OpenClaw's system prompt (~17K tokens) plus conversation history plus tool definitions means you need at minimum 24–32K context for basic agent loops. At 32K context with a 3B GQA model, the KV cache alone balloons to ~3.7GB — the model no longer fits. Even at 4K context, the system prompt gets truncated, breaking tool definitions and causing hallucinated function calls. A 3B model on this hardware maxes out at roughly 4–8K usable context, far below OpenClaw's requirements.

OpenClaw's own community is blunt: "7-8B models hallucinate tool calls and produce format errors. Not recommended. The reliable threshold is 32B+."

## The models that handle tool-calling best at small scale

Despite the hardware mismatch with OpenClaw, these models represent the state of the art for tool-calling under 5B parameters. Independent benchmarking (MikeVeerman's 20-run tool-calling benchmark) produced some surprising results:

| Model | Ollama Tag | Benchmark Score | Tool Format | Notes |
|---|---|---|---|---|
| Qwen 3 1.7B | `qwen3:1.7b` | 0.960 | Hermes-style JSON | Benchmark champion; aced all hard prompts |
| Qwen 3 4B | `qwen3:4b` | 0.920 | Hermes-style JSON | Best overall sub-5B; rivals Qwen2.5-72B on some tasks |
| Qwen 2.5 3B | `qwen2.5:3b` | ~0.880 | Hermes-style JSON | Most battle-tested; community consensus pick |
| LFM 2.5 1.2B | `lfm2.5-thinking:1.2b` | 0.880 | Custom | State-space hybrid; remarkably capable |
| Ministral 3 3B | `ministral-3:3b` | ~0.800 | Mistral-style | Vision + tools; Apache 2.0 |
| Phi-4-mini 3.8B | `phi4-mini` | ~0.680 | `functools[...]` custom | Needs Modelfile template fixes in Ollama |
| Llama 3.2 3B | `llama3.2:3b` | ~0.750 | JSON objects | Decent single-tool calls; struggles with chains |

Qwen 3 1.7B's benchmark dominance is striking — it's the only model that nailed all "hard prompts" requiring multi-parameter extraction and restraint (not calling tools when inappropriate). At just 1.2GB in Q4_K_M, it leaves ample room on 8GB RAM. However, these benchmarks test simple single-turn tool calls, not OpenClaw's complex multi-turn agent loops with 17K+ token system prompts.

Regarding the user's specific model questions: "Qwen3.5:3b" does not exist — Qwen 3.5 Small comes in 0.8B, 2B, 4B, and 9B sizes, and its Ollama tool-calling integration is currently broken (wrong parser mapped). Gemma 4 E4B is real (4B effective parameters, Apache 2.0, multimodal) but has streaming-related tool-calling bugs in Ollama as of April 2026. Avoid both until patches land.

## The practical setup: free cloud APIs as your engine

Since OpenClaw's Gateway is a lightweight Node.js daemon (~2–4GB RAM), your Mac Mini is an excellent always-on host — just point it at free cloud inference. Here's what's available at zero cost:

**Groq** is the strongest option for OpenClaw. Its Llama 3.3 70B runs at 300–500 tokens/second on custom LPU hardware with full OpenAI-compatible function calling, 1,000 requests per day, and a privacy policy that does not use prompts for training. The speed alone transforms OpenClaw from sluggish to instant.

**Google Gemini 2.5 Flash** offers 250 requests/day with native function calling, 1M-token context, and parallel tool calls — ideal for complex multi-step agent reasoning. The caveat: free tier data may be used to improve Google products, so avoid sending raw email bodies through it.

**Cerebras** provides a generous 14,400 requests/day on Llama 3.1 8B with blazing inference speed, though its 8,192-token context limit constrains complex conversations. Best for quick, focused tool calls.

Combined, these three free tiers give you roughly 15,000+ requests per day — more than sufficient for personal productivity automation running 24/7. No credit card required for any of them.

| Provider | Best Model (Free) | RPD | Context | Tool Calling | Privacy |
|---|---|---|---|---|---|
| Groq | Llama 3.3 70B | 1,000 | 128K | ✅ Excellent | Does not train on prompts |
| Gemini | 2.5 Flash | 250 | 1M | ✅ Excellent | Free tier data may be used |
| Cerebras | Llama 3.3 70B | 14,400 | 8K | ✅ Good | Standard policy |
| OpenRouter | DeepSeek V3 (`:free`) | 50–1,000 | Varies | ✅ Good | Varies by provider |
| Mistral | Mistral Large | 2,880/day | 128K | ✅ Good | 2 RPM limit |

## OpenClaw configuration: cloud-primary with local fallback

Here's the recommended `openclaw.json` configuration for your Mac Mini. This uses Groq as the primary model with Gemini Flash as fallback, and optionally a local Qwen model for offline/privacy-sensitive tasks:

```json5
{
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
      "subagents": { "maxConcurrent": 4 }
    }
  },
  "models": {
    "providers": {
      "groq": {
        "baseUrl": "https://api.groq.com/openai/v1",
        "apiKey": "YOUR_GROQ_API_KEY",
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
    "profile": "full",
    "allow": ["group:fs", "browser", "web_search", "web_fetch", "message", "cron"]
  }
}
```

Key Ollama setup commands (if you want the local fallback running):

```bash
# Install Ollama from ollama.com
# Then pull the recommended models:

# Best tool-calling for the RAM budget:
ollama pull qwen3:1.7b          # 1.2GB — benchmark champion, fits easily
ollama pull qwen2.5:3b          # 2.0GB — most reliable, battle-tested

# Set environment for 8GB Intel Mac:
export OLLAMA_MAX_LOADED_MODELS=1
export OLLAMA_NUM_PARALLEL=1
export OLLAMA_FLASH_ATTENTION=1
export OLLAMA_KV_CACHE_TYPE=q8_0

# Test with verbose output:
ollama run qwen3:1.7b --verbose

# Verify tool calling works:
curl http://localhost:11434/api/chat -d '{
  "model": "qwen3:1.7b",
  "messages": [{"role":"user","content":"Set a reminder for 3pm tomorrow"}],
  "tools": [{"type":"function","function":{"name":"create_reminder","description":"Create a reminder","parameters":{"type":"object","properties":{"time":{"type":"string"},"message":{"type":"string"}},"required":["time","message"]}}}],
  "options": {"num_ctx": 4096, "num_thread": 2, "temperature": 0.1}
}'
```

## OpenClaw skills for your productivity stack

OpenClaw's skill ecosystem (13,700+ community skills on ClawHub) covers every aspect of the user's described workflow. Install via `clawhub install <name>`:

- **Email:** `gog` (full Google Workspace — Gmail, Calendar, Tasks, Drive) or `himalaya` (any IMAP/SMTP provider). Users report 85% time savings on email triage.
- **Calendar:** `calendar` (cross-provider), `macos-calendar` (Apple Calendar via AppleScript), `advanced-calendar` (NLP + multi-channel notifications via WhatsApp/Telegram/Discord).
- **Reminders:** `apple-reminders` or `macos-reminders` (native macOS), `remind-me` (custom cron-based), `birthday-reminder`.
- **Web interaction:** Built-in `browser` tool provides full Chromium automation (CDP-based — navigate, click, fill forms, screenshot). `web_search` and `web_fetch` are also built-in. The `openclaw-free-web-search` skill adds self-hosted SearXNG with zero API keys.

For the Intel Mac Mini, browser automation is the heaviest skill — the Chromium instance needs ~500MB–1GB. If running a local model simultaneously, close the browser between tasks or increase swap.

## The hybrid strategy that actually works

The optimal architecture for this hardware separates concerns by sensitivity and complexity:

**Route to the local model** (Qwen 3 1.7B via Ollama) for tasks touching personal data: parsing email content, extracting calendar details from messages, creating reminders from private conversations. This keeps sensitive data on-device. The 1.7B model handles simple single-tool calls reliably at 8–12 tok/s — fast enough for background automation.

**Route to Groq/Gemini** (free cloud APIs) for everything requiring reasoning: multi-step task planning, complex scheduling conflict resolution, web research synthesis, email composition requiring nuanced tone. The 70B model on Groq handles these in under a second.

OpenClaw's fallback chain (`primary` → `fallbacks` array) handles this automatically — when the local model fails a tool call or times out, it escalates to the cloud provider. Set temperature to 0.0–0.1 for agent tasks (higher values increase tool-call hallucinations). Use `"stream": false` if tool calls silently fail during streaming.

For a purely cloud setup (simplest, most reliable), skip Ollama entirely and configure Groq as primary with Gemini as fallback. Your Mac Mini runs only the OpenClaw Gateway — well within its 8GB RAM budget with headroom for browser automation and other skills.

## Conclusion

The honest recommendation: don't fight the hardware. An Intel i5 Mac Mini with 8GB DDR3 is a capable OpenClaw host but an impractical local inference machine for agent workloads. OpenClaw's 17K-token system prompt, 64K context requirement, and need for reliable multi-turn tool-calling place it firmly beyond what any sub-7B model can deliver at 4K context on 5GB of available RAM.

The winning move is to embrace the Mac Mini's strength — low-power, always-on, reliable — as a Gateway host, and offload inference to free cloud APIs. Groq's 70B model at 300+ tok/s with 1,000 free requests/day handles OpenClaw's agent loops better than any local model on any consumer hardware. Combined with Gemini Flash and Cerebras, you get 15,000+ free daily requests — enough for 24/7 personal automation without spending a dollar.

If local inference matters for privacy, Qwen 3 1.7B is the surprising champion — benchmark-leading tool-calling accuracy at just 1.2GB. Use it as the offline fallback for sensitive data processing, and let the cloud handle the complex reasoning. This hybrid approach gives you the best of both worlds: privacy where it matters, intelligence where it counts, and a setup that doesn't fight physics.
