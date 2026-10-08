{{/* Resource Naming */}}

{{- define "openclaw.name" -}}
{{- printf "%s-openclaw" .Release.Name }}
{{- end }}

{{- define "openclaw.volume.name" -}}
{{- printf "%s-openclaw-vs" .Release.Name }}
{{- end }}

{{- define "openclaw.secret.seed.name" -}}
{{- printf "%s-openclaw-seed" .Release.Name }}
{{- end }}

{{- define "openclaw.identity.name" -}}
{{- printf "%s-openclaw-identity" .Release.Name }}
{{- end }}

{{- define "openclaw.policy.name" -}}
{{- printf "%s-openclaw-policy" .Release.Name }}
{{- end }}


{{/* Image: the -browser variant ships Chromium; one version string to bump */}}
{{- define "openclaw.image" -}}
{{- if .Values.browser.enabled -}}
{{- printf "%s:%s-browser" .Values.image.repository (toString .Values.image.tag) -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository (toString .Values.image.tag) -}}
{{- end -}}
{{- end }}


{{/* Model / provider */}}

{{/*
The env var the LLM key is injected as. OpenClaw reads ANTHROPIC_API_KEY and
OPENAI_API_KEY by itself; the custom provider references CUSTOM_LLM_API_KEY
from openclaw.json as a literal ${CUSTOM_LLM_API_KEY}, so no key is ever on disk.
*/}}
{{- define "openclaw.apiKeyEnv" -}}
{{- $p := .Values.model.provider -}}
{{- if eq $p "anthropic" -}}ANTHROPIC_API_KEY
{{- else if eq $p "openai" -}}OPENAI_API_KEY
{{- else -}}CUSTOM_LLM_API_KEY
{{- end -}}
{{- end }}

{{/* provider/model reference. The ref splits on the FIRST "/", so a custom model
     ID may itself contain "/" (OpenRouter's openai/gpt-4o) — measured. */}}
{{- define "openclaw.modelRef" -}}
{{- $p := .Values.model.provider -}}
{{- if eq $p "custom" -}}
{{- printf "custom-openai/%s" .Values.model.name -}}
{{- else -}}
{{- printf "%s/%s" $p .Values.model.name -}}
{{- end -}}
{{- end }}


{{/*
Values-owned config, as `openclaw config patch` fragments keyed by item. The boot
wrapper applies an item only when it differs from the last value it applied
(markers in /data/.openclaw/.cpln), so a helm upgrade takes effect while a setting
changed later in the Control UI survives restarts until the values change again.
An item set to null is "off in values": its `off` patch is applied only if the
template had turned it on. Channel tokens are env SecretRefs — no token is written
to disk. Each channel also sets plugins.entries.<id>.enabled: a channel whose plugin
entry is absent lists as "installed, not configured, disabled" and the Control UI
offers to download the plugin again (measured).
Rendered into the workload spec (not the seed secret) so a change restarts the replica.
*/}}
{{- define "openclaw.desired" -}}
{{- $custom := dict "baseUrl" .Values.model.baseUrl "apiKey" "${CUSTOM_LLM_API_KEY}" "api" "openai-completions" "models" (list (dict "id" .Values.model.name "name" .Values.model.name)) -}}
{{- $model := dict "agents" (dict "defaults" (dict "model" (dict "primary" (include "openclaw.modelRef" .)))) -}}
{{- if eq .Values.model.provider "custom" -}}
{{- $_ := set $model "models" (dict "providers" (dict "custom-openai" $custom)) -}}
{{- else -}}
{{- $_ := set $model "models" (dict "providers" (dict "custom-openai" nil)) -}}
{{- end -}}
{{- $on := .Values.httpApi.enabled -}}
{{- $http := dict "gateway" (dict "http" (dict "endpoints" (dict "chatCompletions" (dict "enabled" $on) "responses" (dict "enabled" $on)))) -}}
{{- $ref := dict "source" "env" "provider" "default" -}}
{{- $chans := dict
      "telegram" (dict "enabled" true "botToken" (merge (dict "id" "TELEGRAM_BOT_TOKEN") $ref))
      "slack" (dict "enabled" true "mode" "socket" "botToken" (merge (dict "id" "SLACK_BOT_TOKEN") $ref) "appToken" (merge (dict "id" "SLACK_APP_TOKEN") $ref))
      "discord" (dict "enabled" true "token" (merge (dict "id" "DISCORD_BOT_TOKEN") $ref))
      "whatsapp" (dict "enabled" true) -}}
{{- $items := dict "model" $model "httpApi" $http -}}
{{- $off := dict -}}
{{- range $id := list "telegram" "slack" "discord" "whatsapp" -}}
{{- $frag := dict "channels" (dict $id (get $chans $id)) "plugins" (dict "entries" (dict $id (dict "enabled" true))) -}}
{{- $_ := set $items (printf "channel-%s" $id) (ternary $frag nil (get $.Values.channels $id).enabled) -}}
{{- $_ := set $off (printf "channel-%s" $id) (dict "channels" (dict $id (dict "enabled" false)) "plugins" (dict "entries" (dict $id (dict "enabled" false)))) -}}
{{- end -}}
{{- /* Control Plane MCP. Per-requester OAuth sends each chat sender a sign-in link that
       completes on <gateway.publicOrigin>/oauth/mcp/callback, so it needs the public
       endpoint; a private install registers shared operator OAuth (`mcp login cpln`). */ -}}
{{- $oauth := ternary (dict "identity" "per-requester") nil .Values.publicAccess.enabled -}}
{{- $mcp := dict "mcp" (dict "servers" (dict "cpln" (dict "url" "https://mcp.cpln.io/mcp" "transport" "streamable-http" "auth" "oauth" "oauth" $oauth))) -}}
{{- $_ := set $items "mcp-cpln" (ternary $mcp nil .Values.cplnMcp.enabled) -}}
{{- $_ := set $off "mcp-cpln" (dict "mcp" (dict "servers" (dict "cpln" nil))) -}}
{{- toJson (dict "items" $items "off" $off) -}}
{{- end }}


{{/* First-boot openclaw.json (fixed gateway block). Copied only if absent. */}}
{{- define "openclaw.seed" -}}
{
  gateway: {
    mode: "local",
    bind: "lan",
    port: 18789,
    auth: { mode: "token" },
    // Env reference kept literal in the file; resolved from the workload env at start.
    publicOrigin: "${TEMPLATE_PUBLIC_ORIGIN}",
    // The platform sidecar's source address for edge and in-GVC traffic (measured).
    trustedProxies: ["127.0.0.6"],
  },
  agents: { defaults: { workspace: "~/.openclaw/workspace" } },
}
{{- end }}


{{/* Validation */}}

{{- define "openclaw.milli" -}}
{{- $v := toString . -}}
{{- if hasSuffix "m" $v -}}{{ trimSuffix "m" $v | float64 }}{{- else -}}{{ mulf (float64 $v) 1000 }}{{- end -}}
{{- end }}

{{- define "openclaw.validate" -}}
{{- if not .Values.secret.name -}}
{{- fail "openclaw: secret.name is required — create the prerequisite dictionary secret (keys gateway-token, llm-api-key) first; see README → Prerequisites" -}}
{{- end -}}
{{- $p := .Values.model.provider -}}
{{- if not (has $p (list "anthropic" "openai" "custom")) -}}
{{- fail (printf "openclaw: model.provider must be one of anthropic, openai, custom — got '%s'. Any other OpenAI-compatible endpoint uses 'custom' with model.baseUrl." $p) -}}
{{- end -}}
{{- if not .Values.model.name -}}
{{- fail "openclaw: model.name is required (e.g. claude-opus-5-5) — an unset model makes the gateway fall back to an OpenAI default that fails with any other key" -}}
{{- end -}}
{{- if and (ne $p "custom") (contains "/" .Values.model.name) -}}
{{- fail (printf "openclaw: model.name '%s' must not contain '/' with provider %s — give the bare model ID; the chart adds the '%s/' prefix itself" .Values.model.name $p $p) -}}
{{- end -}}
{{- if and (eq $p "custom") (not .Values.model.baseUrl) -}}
{{- fail "openclaw: model.baseUrl is required when model.provider is 'custom' (e.g. https://openrouter.ai/api/v1)" -}}
{{- end -}}
{{- if and (ne $p "custom") .Values.model.baseUrl -}}
{{- fail (printf "openclaw: model.baseUrl is only used with model.provider 'custom' — clear it, or set the provider to custom to route %s through an OpenAI-compatible endpoint" $p) -}}
{{- end -}}
{{- if and .Values.model.baseUrl (not (regexMatch "^https?://[^\\s]+$" .Values.model.baseUrl)) -}}
{{- fail (printf "openclaw: model.baseUrl must start with http:// or https:// — got '%s'" .Values.model.baseUrl) -}}
{{- end -}}
{{- if and .Values.publicAccess.origin (not .Values.publicAccess.enabled) -}}
{{- fail "openclaw: publicAccess.origin requires publicAccess.enabled: true — the custom domain reaches the workload through its public endpoint" -}}
{{- end -}}
{{- if and .Values.publicAccess.origin (not (regexMatch "^https://[^/?#]+$" .Values.publicAccess.origin)) -}}
{{- fail (printf "openclaw: publicAccess.origin must be an https origin with no path or trailing slash, e.g. https://assistant.example.com — got '%s'" .Values.publicAccess.origin) -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "openclaw: internalAccess.type must be none, same-gvc, same-org or workload-list — got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if and (eq .Values.internalAccess.type "workload-list") (empty .Values.internalAccess.workloads) -}}
{{- fail "openclaw: internalAccess.type 'workload-list' needs at least one entry in internalAccess.workloads (e.g. //gvc/GVC/workload/NAME)" -}}
{{- end -}}
{{- if lt (int .Values.volumeset.capacity) 10 -}}
{{- fail (printf "openclaw: volumeset.capacity must be at least 10 (GiB) — got %v" .Values.volumeset.capacity) -}}
{{- end -}}
{{- if and .Values.volumeset.autoscaling.enabled (lt (int .Values.volumeset.autoscaling.maxCapacity) (int .Values.volumeset.capacity)) -}}
{{- fail (printf "openclaw: volumeset.autoscaling.maxCapacity (%v) must be >= volumeset.capacity (%v)" .Values.volumeset.autoscaling.maxCapacity .Values.volumeset.capacity) -}}
{{- end -}}
{{- $max := include "openclaw.milli" .Values.resources.maxCpu | float64 -}}
{{- $min := include "openclaw.milli" .Values.resources.minCpu | float64 -}}
{{- if gt $max (mulf $min 4) -}}
{{- fail (printf "openclaw: resources.maxCpu (%v) must be at most 4x resources.minCpu (%v) — the platform rejects a wider ratio on a stateful workload" .Values.resources.maxCpu .Values.resources.minCpu) -}}
{{- end -}}
{{- if not .Values.backup.retention -}}
{{- fail "openclaw: backup.retention is required (e.g. 7d) — it also sets how long the final snapshot taken at uninstall is kept" -}}
{{- end -}}
{{- if and .Values.backup.enabled (not .Values.backup.schedule) -}}
{{- fail "openclaw: backup.schedule is required when backup.enabled is true (cron, UTC, e.g. \"0 3 * * *\")" -}}
{{- end -}}
{{- /* The platform rejects snapshot schedules more frequent than hourly, at apply time only (measured: an every-10-minutes schedule refused, "55 * * * *" accepted). A schedule runs at most hourly when its minute field is a single fixed minute. */ -}}
{{- if and .Values.backup.enabled .Values.backup.schedule (not (regexMatch "^[0-5]?[0-9] +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+$" (trim (toString .Values.backup.schedule)))) -}}
{{- fail (printf "openclaw: backup.schedule %q must be a 5-field cron with a single fixed minute (snapshots cannot run more often than hourly), e.g. \"0 3 * * *\"" (toString .Values.backup.schedule)) -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{- define "openclaw.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{/*
Boot wrapper (sh/dash). Guards the token, seeds openclaw.json only if absent,
applies changed values-owned config BEFORE the gateway starts (a channel enabled
after start stays "configured, stopped" until a restart — measured), then execs
the image's own entrypoint so doctor migrations and plugin installs run every boot.
Doctor installs the plugin of each configured channel at the gateway's version
(@openclaw/<id>@<gateway version>, measured), so the chart never installs plugins.
*/}}
{{- define "openclaw.wrapper" -}}
set -eu
D=/data/.openclaw
tok="${OPENCLAW_GATEWAY_TOKEN:-}"
if [ "${#tok}" -lt 24 ]; then
  echo "FATAL: key gateway-token in secret {{ .Values.secret.name }} must be at least 24 characters (generate one with: openssl rand -hex 32)" >&2
  exit 64
fi
mkdir -p "$D/.cpln"
# Test the FILE, never directory emptiness (an ext4 volume has lost+found).
if [ ! -f "$D/openclaw.json" ]; then
  cp /seed/openclaw.json "$D/openclaw.json"
  echo "openclaw: seeded $D/openclaw.json"
else
  echo "openclaw: openclaw.json present; not seeding"
fi
cat > /tmp/openclaw-desired.json <<'CPLN_DESIRED'
{{ include "openclaw.desired" . }}
CPLN_DESIRED
cat > /tmp/openclaw-reconcile.mjs <<'CPLN_RECONCILE'
import fs from "node:fs";
import { execFileSync } from "node:child_process";
const M = "/data/.openclaw/.cpln";
const { items, off } = JSON.parse(fs.readFileSync("/tmp/openclaw-desired.json", "utf8"));
const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const merge = (a, b) => { for (const [k, v] of Object.entries(b)) { if (isObj(v) && isObj(a[k])) merge(a[k], v); else a[k] = v; } return a; };
const patch = {}; const commit = [];
for (const [item, frag] of Object.entries(items)) {
  const f = `${M}/last-${item}`;
  const prev = fs.existsSync(f) ? fs.readFileSync(f, "utf8") : null;
  if (frag === null) {
    if (prev !== null && off[item]) {
      merge(patch, off[item]);
      commit.push([f, null]);
      console.log(`openclaw: reconcile ${item}: disabled in values; switching it off`);
    }
    continue;
  }
  const s = JSON.stringify(frag);
  if (s === prev) continue;
  merge(patch, frag); commit.push([f, s]);
  console.log(`openclaw: reconcile ${item}: values changed; applying`);
}
if (commit.length === 0) { console.log("openclaw: reconcile: values unchanged; keeping openclaw.json as is"); process.exit(0); }
fs.writeFileSync("/tmp/openclaw-patch.json", JSON.stringify(patch));
try {
  execFileSync("node", ["openclaw.mjs", "config", "patch", "--file", "/tmp/openclaw-patch.json"], { cwd: "/app", stdio: "inherit", timeout: 120000 });
} catch (e) {
  console.error(`ERROR: reconcile: config patch failed (${e.message}); openclaw.json unchanged, retried on next start`);
  process.exit(0);
}
for (const [f, s] of commit) { if (s === null) fs.rmSync(f, { force: true }); else fs.writeFileSync(f, s); }
CPLN_RECONCILE
node /tmp/openclaw-reconcile.mjs || echo "ERROR: reconcile exited non-zero; starting the gateway anyway" >&2
exec tini -s -- node /app/docker-entrypoint.mjs node openclaw.mjs gateway
{{- end }}
