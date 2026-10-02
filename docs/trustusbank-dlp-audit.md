# TrustUsBank: data protection and call-level audit in Berlin

Verified on 2026-10-02. Start at <http://localhost:8900/google>, or the hosted
copy running inside Berlin itself: `https://agw.agentic.eu0.internal/google`
(sign in: `solo` / `S010g00g13!`). The hosted service is the Google-only console
in `poc/2026-09-agentic-platform/console`, deployed by
`scripts/97-google-console.sh`; it covers the same /google pages (routing,
agents, website, approvals, DLP) and needs nothing on the presenter's laptop.

## Deploy and reproduce

All cluster manifests, deployment scripts, sample generation and audit probes
live in **google-sov**. Console pages and HTTP handlers live in the companion
`solo-demos/vision-demo-2026/demo-console` directory.

After `scripts/deploy-e2e.sh` installs the base platform and Gemma:

```bash
bash scripts/deploy-google-demo.sh
```

This adds semantic model routing, demo identity, model-route JWT verification
and budget enforcement, Presidio, data policies, and waypoint tracing. It reuses
the existing Gemini Secret; a fresh install needs `GEMINI_API_KEY` as described
by `87-vsr-routes.sh`. It does not add seeded cost records. Install the five
demo budgets with `89-cost.sh budget` separately.

Individual commands from `poc/2026-09-agentic-platform`:

```bash
# Mirror the pinned image, deploy and run live probes; needs a Berlin session.
bash scripts/96-dlp.sh

# Reconcile using an existing mirrored image and the isolated cluster credential.
export GCD_KUBECONFIG="$PWD/deploy/console.kubeconfig"
export KUBE_CONTEXT=berlin-console
bash scripts/96-dlp.sh apply
bash scripts/96-dlp.sh verify
python3 scripts/verify_dlp_edges.py
python3 scripts/94-audit-waypoints.py --apply

# Generate the fictional PDF (local dependency: reportlab).
python3 scripts/make_dlp_sample.py
# Output: deploy/trustusbank-case.pdf

# A real authenticated call and its AGW trace link; no seeded telemetry.
python3 scripts/93-audit-call.py
```

The verifier exits nonzero on failure. Its customer-data probe asks for Gemini
while spoofing a `general` classification header, then checks that Gemma answered
and that the *same trace's* masking record removed the supplied name, customer
ID, tax ID and IBAN. Other probes exercise rejection, a clean Gemini request,
and an in-cluster text upload.

`verify_dlp_edges.py` adds six negative controls: empty files, invalid base64,
malformed PDFs, unsupported types, spoofed residency headers on a name-only
prompt, and unsupported tool-result conversations. All six passed live.

`87-vsr-routes.sh` preserves installed DLP routing rules on re-runs. To remove
this layer intentionally, run `bash scripts/96-dlp.sh --remove`: it deletes DLP
resources and restores the plain model route. Shared gateway tracing remains.
Full namespace teardown also removes DLP and waypoint tracing resources.

## Components and behaviour

| Source under `poc/2026-09-agentic-platform` | Purpose |
|---|---|
| `yaml/dlp/01-pii.yaml` | Presidio webhook, PDF/text reader, Service and CPU Deployment |
| `yaml/dlp/02-data-class.yaml` | PreRouting CEL classification on the models ListenerSet |
| `yaml/dlp/03-data-policy.yaml` | Regex rejection and fail-closed request/response webhooks |
| `yaml/dlp/04-upload.yaml` | `/tub/summarize` route to the in-cluster reader |
| `yaml/dlp/05-routes.yaml` | Residency-aware model routes with gateway-set target headers |
| `yaml/vsr/extproc-policy.yaml` | Semantic router scoped to chat-completion requests |
| `yaml/telemetry/gateway-tracing.yaml` | Gateway traces with verified JWT audit attributes |
| `scripts/94-audit-waypoints.py` | Agent and MCP waypoint tracing |

The DLP image is the same digest as the Kernwerk EKS lab:

```text
mcr.microsoft.com/presidio-analyzer@sha256:286e3fa7f3a7426e775e8564fe1870f1ba8f999d3ab8bbb8cc46a44355d9d6e9
```

`96-dlp.sh` mirrors it as `$AR_PREFIX/presidio-analyzer:sha-286e3fa7` using a
temporary registry credential. [Presidio](https://github.com/data-privacy-stack/presidio)
is MIT-licensed and was formerly under `microsoft/presidio`. The mounted Python
adapter supplies the AGW webhook contract and TrustUsBank recognizers.
`pypdf==6.1.1` is installed by the init container, requiring package-download
egress on startup.

* Recognised bank markers (IBAN, customer numbers, tax IDs, email addresses) and
  restricted markings override a requested Gemini route and go to Gemma.
* AGW rejects the configured secret and prompt-injection patterns before inference.
* Presidio replaces detected personal data with placeholders. Automated detectors
  are not guaranteed to find all sensitive text. The bundled English NER can
  over-mask German nouns.
* If Presidio detects additional personal data on a Gemini-bound request that
  CEL missed, it returns **409 before inference**. The Data protection console
  retries on Gemma; both attempts have real traces. Other API clients must
  resubmit to Gemma themselves.
* Uploads are extracted in-cluster and explicitly request Gemma, including clean
  documents. The reader forwards caller JWT and trace context to the model call.
* Webhook failure is fail-closed. Tool-result conversations are rejected on this
  document DLP path rather than silently exempted. Existing kagent tool
  conversations use the separate `llm` route.

Uploads accept PDF, TXT, Markdown and CSV: up to 5 MiB, 30 PDF pages and 24,000
extracted characters. Encrypted, empty and image-only PDFs are rejected with an
explanation; the reader does not run OCR.

The DLP page requests whole responses so its response webhook can inspect the
answer. Streaming clients on the Routing page demonstrate request-side protection;
do not use them as evidence of whole-answer response masking.

## Presenter walkthrough: DLP and PDF summary

1. Open `/google`. **Architecture** starts collapsed. Expand it to show external
   laptops connecting to Berlin AGW, Presidio, Gemma/Gemini, kagent, MCP waypoints,
   and the dashed **Agentdesktop fleet: planned, not deployed**. AgentRegistry
   is omitted from this diagram.
2. Open **Data protection**. Select **Fraud case file**, select **force Gemini**,
   and send. Gemma answers. Expand the card to compare fictional source text
   with the placeholders sent to the model.
3. Select **Trick the model**. AGW returns 403 before inference; this is a
   guardrail decision, not a refusal generated by the model.
4. Upload `deploy/trustusbank-case.pdf`. The reader opens it inside Berlin and
   returns a Gemma summary with placeholders. Click **Inspect this call in AGW
   Tracing**. The upload and its inner model call share a trace.

The comparison cards deliberately retain source and masked text in demo logs.
Use the fictional samples. This is not an immutable compliance archive.

**Clear history** resets the “What the gateway did” panel and starts a fresh
demo run. The reset persists across page reloads and console restarts; old log
replay and answers from already-running calls do not repopulate it. New calls
appear normally. This is a presentation-history reset; cluster logs and AGW
audit traces remain available.

## Claude Desktop: same flow as the working EKS DLP lab

### Native Desktop context limit

The real Desktop client sends substantially more than the visible user prompt.
Its mortgage-review request contained **19,321 input tokens**, plus a 2,048-token
answer allowance. The previous vLLM setting was 8,192 total tokens, which caused
a context-limit rejection. The Messages conversion hop then hid it behind
`missing field error` because vLLM's error body lacked the OpenAI error envelope.

The GPU model default is now **24,576 tokens**, within the measured H100 cache
capacity. `61-model-context.py --apply` updates an existing deployment without
replacing other settings, then checks the model API itself for readiness.
The DLP policy normalises vLLM errors so Desktop receives the actual context-limit
message as HTTP 400. Documents and history must still fit the total context;
content is not silently truncated.

`verify_desktop_context.py` exercises a PDF with a synthetic 19k-token system
preamble and a deliberately oversized request. Verified: 19,605 input tokens
returned a Gemma summary; the oversized request returned a clear 400.

The Berlin deployment now ports Kernwerk's reader → Messages conversion →
guarded model-route pattern. Set the Desktop gateway base URL to:

```text
https://agw.agentic.eu0.internal/trustusbank
```

The path is:

```text
Claude Desktop on the laptop
  → Berlin AGW /trustusbank/v1/messages (Strict Keycloak JWT)
  → trustusbank-pii reader: PDF/text extraction inside Berlin
  → AGW /trustusbank-open/v1/messages: Messages → Chat Completions
  → /v1/chat/completions: TrustUsBank guardrails + Presidio → Gemma
  → response masking → Messages response / Desktop SSE
```

The reader fetches the whole answer before replaying SSE so response masking
completes before Desktop receives any answer text. `/v1/messages/count_tokens`
is handled separately and is not shown as an inference card.

### Switch this Mac

From the **google-sov repository root**, run as your normal laptop user:

```bash
python3 poc/2026-09-agentic-platform/scripts/claude_desktop_berlin.py on
```

This first tests the endpoint, then requests the Mac administrator password to
trust the Berlin CA and install Desktop's managed profile. It backs up the
previous Desktop profile and saved deployment mode, selects third-party
inference, and installs a refreshing Keycloak credential helper. Default demo
identity is Bob; the helper emits only a short-lived token, never an embedded
long-lived API key. Custom `TUB_USER`, `TUB_USER_PASSWORD`, `TUB_KEYCLOAK`,
`TUB_CA_FILE` and `GCD_KUBECONFIG` values supplied during installation are retained
in the local owner-only helper. Claude Code settings are not modified.

Fully quit and reopen Claude Desktop, start a **new chat**, and attach
`poc/2026-09-agentic-platform/deploy/trustusbank-case.pdf`. Ask for a summary.
Keep <http://localhost:8900/google/dlp> open alongside Desktop.

Under **What the gateway did**, a **Claude Desktop** card shows the filename,
extracted text, masked model input, replacement count, Gemma result/status,
timing, token usage and a link to the AGW trace. This works for external
requests: the page follows gateway/Presidio logs, rather than only its own
buttons. The console must be running; it replays the latest 30 minutes on start.

To restore the previous Desktop profile:

```bash
python3 poc/2026-09-agentic-platform/scripts/claude_desktop_berlin.py off
```

Quit/reopen Desktop again. The shared Berlin CA trust remains for other Berlin
applications. An active Agentdesktop-owned profile is left to its owner to
reconcile, rather than overwritten by this standalone setup command.

### Verification and Berlin adaptations

```bash
python3 poc/2026-09-agentic-platform/scripts/test_desktop_adapter.py
python3 poc/2026-09-agentic-platform/scripts/verify_desktop.py
```

Verified over HTTPS: invalid JWT → 401, token counting, a normal Messages call,
a PDF attachment with streamed Messages response, and injection → Anthropic
error with status 403. In the browser, the PDF produced a Claude Desktop card
showing four replacements, HTTP 200 and Gemma. This verifies the Desktop wire
protocol and log viewer; native app testing requires the local profile switch.

Sources are `yaml/dlp/06-desktop.yaml` and `yaml/dlp/desktop_adapter.py`.
Berlin's AGW build prefers OpenAI Responses for a generic OpenAI provider, so
the conversion backend explicitly advertises only Chat Completions. The
conversion hop uses loopback inside the same proxy (with the model authority),
avoiding Kubernetes self-Service/load-balancer hairpin timeouts. The serving
certificate now includes `agw.agentic.eu0.internal`.

All Desktop requests on this document-summary endpoint use Gemma. Unsupported
images/scans, URL attachments and tool-result conversations fail explicitly;
WebSearch/WebFetch are disabled in the profile as in the EKS lab. Inspect the
inner `models` span for inference details; the outer Desktop hop is a format
bridge, not a second model answering the user.

## Presenter walkthrough: who did what and when, in AGW

Open <http://kagent.agentic.eu0.internal/age/tracing/> and sign in using the
existing demo UI account (`admin-user`, or the configured account). Use a fresh
call or the console's trace deep-link. Allow a few seconds for OTel export.

### A model/DLP call

1. Run `python3 scripts/93-audit-call.py`, or use the DLP page. The script prints
   a real trace URL and the requested versus actual model.
2. Open the trace. In **Trace Tree**, select `POST /v1/chat/completions/*`.
3. Expand **Span Attributes**:
   * **audit**: `user=bob`, `agent=trustusbank-console`, `team=payments-ops`,
     and the signed subject. Values come from the gateway-verified JWT.
   * **gen_ai**: actual model and input/output token counts.
   * **agw → ai → guardrails**: regex allow/reject and webhook mask/allow.
     Request and response guardrails also appear as child spans.
   * **agw → ai → budgets**: live budget outcome; **usage → cost**: model cost.
4. **Start**, **Duration**, HTTP status, gateway, route and endpoint establish
   when it happened and where it went. A denied trace has a guardrail error
   rather than a model response.

Verified example: `e4a8e68c9bca249f63cdbee585c17bc6`, Bob's console call, Gemini
requested, Gemma answered, request masking, 73 input / 30 output tokens. Records
are available only for the telemetry store's retention period.

**Installed UI limitation:** the AGE table's **User ID** column displays N/A.
Use **Span Attributes → audit** and verified cost dimensions. An empty table
column does not mean identity is absent from the trace.

### An agent and its tool call

`94-audit-waypoints.py --apply` enables tracing on current enterprise agent and
MCP waypoints (15 verified). Re-run it after adding an agent.

1. In **Bank agents**, ask the payments agent:
   `What is the balance of account DE89370400440532013000?`
2. In AGW **Tracing**, find the recent `tools/call` for
   `bank-payments-http_get_account_balance` and open that trace.
3. The tree contains the kagent invocation, its Gemma calls,
   `execute_tool get_account_balance`, and the MCP `tools/call`.
4. Select `tools/call`. Inspect `gen_ai.tool.name`, `jwt.sub`, `src.identity`,
   route `mcp/bank-payments-mesh`, status and timestamp. The subject is the
   payments agent's ServiceAccount, bound to its SPIFFE mesh identity.

Verified example: `cafb96bf4c77b27a786e1355058dc395`, a 7.3-second payments
invocation with both model calls and `get_account_balance`; MCP took 2 ms.
Human and workload identities are distinct: `audit.user` is **not delegated**
on MCP hops carrying only workload tokens. The trace correlates the workflow;
the tool hop proves the calling workload, not a separately verified Bob token.
