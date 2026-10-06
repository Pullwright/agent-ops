# Grok Build headless evaluation — 2026-10-06

This is the evaluation issue #2132 asks for (part of #2128): Grok Build run
headlessly against the substrate contract that
[`docs/PROVIDER-SEAM-AUDIT.md`](../PROVIDER-SEAM-AUDIT.md) (#2130) wrote down,
so that #2134's adapter is specified from what the CLI does rather than from
what its documentation says. Each of the issue's ten questions is answered
below with the command that was run and what it printed, and the record ends
with the adapter specification #2134 should implement, and the parts #2139
inherits.

It is a planning record, not an as-built specification: no pipeline code,
configuration or prompt changed, and every run used a disposable container, a
scratch repository and a stand-in `gh`, never a configured target.

## Summary

Grok Build fits the substrate contract more closely than the audit's reading
of the documentation suggested, and three of the gaps the audit named are not
gaps:

- **The envelope is readable unchanged.** With `--output-format
  streaming-messages-json`, the pipeline's own `stage_result_line` and
  `metering_fields` read Grok's terminal `result` line without modification,
  and `is_error` — which the audit listed as missing — is present on every
  envelope, success or failure.
- **The prompt can still go in on stdin.** `-p` takes an argument, but
  `--prompt-file /dev/stdin` with the launcher's existing here-string delivers
  a 200 KB prompt intact, so requirement 4c's reasoning carries over and no
  temporary file is needed.
- **Installation can be pinned.** The npm package `@xai-official/grok` installs
  and runs in the node image, pinned by version and integrity-checked by the
  registry, at a cost of 211 MB.

Four findings are new, and each needs handling in the adapter:

- **A process-group kill does not reach Grok's commands.** Grok starts each
  shell-tool command in its own session, so the launcher's `kill -TERM
  -$pid` ends Grok and leaves its commands running, reparented to PID 1.
  Signalling Grok itself does not clean them up either.
- **The exit status does not mean what Claude Code's does.** A failure inside
  a run exits 0 with `is_error: true`; only a failure before the first model
  turn exits 1.
- **Every Grok failure is invisible to the refusal classifier.** Grok puts its
  error text in an `errors` array, with no `terminal_reason` and no
  `api_error_status`, so `stage_api_refusal` returns nothing for any of them —
  an expired key, a rate limit and exhausted credits all read as a bare "exited
  1". Grok emits no structured rate-limit event, and xAI's credit-exhaustion
  message does not match `LIMIT_PHRASE_REGEX`.
- **A 503 is retried indefinitely and silently.** Grok writes nothing at all,
  not even its `init` line, while it retries, so only the liveness watchdog
  would end such a stage.

The two Implementer-shaped runs of record both produced a correct fix with
passing tests and a well-formed verdict, in 81 seconds for US$0.18
(`grok-build-0.1`) and 36 seconds for US$0.15 (`grok-4.3`); neither followed
the prompt's procedure in full (§6). The whole evaluation spent US$1.94 of the
owner's prepaid xAI credit across 47 runs.

## How the evaluation was run

- **Grok Build 1.0.46** (`grok 1.0.46 (2765805b9442)`), the npm `latest`
  dist-tag on 2026-10-06 (`alpha` was 1.0.49).
- **The node image** `ghcr.io/pullwright/agent-ops:latest` at revision
  `38fe910d0e4ea9ad7e58a9b632d7afc02ec53d82` (built 2026-10-05T22:07Z), run as
  a throwaway container on the maintainer's workstation (`ockham`, WSL 2), with
  Grok installed into it as root and every run made as the image's `agent`
  user. Node in the image is v26.10.0.
- **Credentials.** The owner's xAI API key, created for this evaluation with
  prepaid credit only and held in a mode-600 file on the workstation. It was
  passed to each `docker exec` through the environment, never on a command
  line, and every captured output was filtered for anything key-shaped. A
  search of everything Grok wrote found the key in no file (§9). No SuperGrok
  or X Premium+ subscription was available, so the subscription path's
  questions are left to #2139.
- **The fence (§10)** was a second throwaway container on a private
  `--internal` network whose only route out was a squid started from the same
  image with `deploy/docker/egress-proxy-start.sh`, exactly as a node's
  `egress-proxy` service starts it, with `EGRESS_EXTRA_ALLOW` adding the xAI
  domains under test. Both networks needed the host's 1300-byte MTU, as
  `compose.yaml` documents; at Docker's default of 1500 every TLS handshake
  through the proxy hung.
- **Failure shapes (§8)** that cannot be provoked without spending or waiting
  — a rate limit, exhausted credits, a mid-run 401, an outage — came from a
  local HTTP stand-in for `api.x.ai`, reached through Grok's own
  `GROK_XAI_API_BASE_URL` override, which forwarded `GET /v1/models` and
  `GET /v1/api-key` to the real API and answered everything else with the
  status under test. The credit-exhaustion body uses the wording xAI
  documents for that error; the others are representative, so the phrase
  matching in §8 should be rechecked against the first real occurrence of
  each.
- **The Implementer runs (§6)** used the shipped `prompts/implementer.md`,
  completed byte for byte as `lib/coordinator-phase.sh` completes it (the work
  order as fenced JSON, then `## Cycle` and `## Node`), against a fresh clone
  of a small scratch repository (`scratch/eval-target`: a shell `slugify` with
  a real bug, a test script and an `AGENTS.md`). Its `origin` was a local bare
  repository with `agent/7` already pushed at `main`'s head, as the Script
  pushes the claim branch before launch, and `gh` was a stateful stand-in
  installed at the path the pipeline's own `gh` shim occupies
  (`/usr/local/bin/gh`), which recorded every call and answered as `gh` would
  for one repository with no pull request until one was created.

## The ten questions

### 1. Install and pin

The npm package installs in the node image and runs as `agent`:

```
$ npm view @xai-official/grok dist-tags
{ "latest": "1.0.46", "alpha": "1.0.49" }
$ npm install -g "@xai-official/grok@1.0.46"      # as root, 1m18s
$ grok --version                                   # as agent
grok 1.0.46 (2765805b9442)
```

The package is Apache-2.0, requires Node 20 or later, and pulls one
per-platform optional dependency (`@xai-official/grok-linux-x64`, 49 MB
compressed). Its `postinstall` decompresses that into
`bin/grok-native` (171 MB), which is what the `grok` command resolves to
(`readlink -f "$(command -v grok)"` →
`/usr/lib/node_modules/@xai-official/grok/bin/grok-native`).

The same `postinstall` also copies the 171 MB binary into `$GROK_HOME/bin`
(default `~/.grok/bin`) and writes `$GROK_HOME/config.toml`. Run as root with
`HOME` set to the agent's home — as a `docker exec -u root` is — this left a
root-owned `/home/agent/.grok` that `agent` could not write, which would break
every later credential and session write. The copy is never used at run time,
so the image recipe points `GROK_HOME` at a temporary directory and deletes it
in the same layer. Verified in a fresh container from the same image:

```
$ GROK_HOME=/tmp/grok-install npm install -g "@xai-official/grok@1.0.46" \
    && rm -rf /tmp/grok-install && npm cache clean --force
install rc=0
node_modules grew by 211 MB
ls: cannot access '/root/.grok': No such file or directory
ls: cannot access '/home/agent/.grok': No such file or directory
grok 1.0.46 (2765805b9442)                         # as agent
```

xAI's installer script (`https://x.ai/cli/install.sh`) was read, not run. It
downloads a binary from `https://x.ai/cli` (falling back to a Google Cloud
Storage bucket) with no checksum verification, installs it under
`~/.grok/bin` — which on a node would be inside the credentials volume, so an
image upgrade would not replace it — and edits the user's shell start-up files.
It is unsuitable for the image; npm is the pin, as it is for Claude Code
(D14's size figure is the 211 MB above).

**Updates and telemetry.** Grok 1.0.46 has no `--no-auto-update` flag; the
binary names `GROK_DISABLE_AUTOUPDATER` and `GROK_TELEMETRY_ENABLED` (among
`GROK_TELEMETRY_*` and `GROK_FEEDBACK_ENABLED`). Behind the fence, with both
left at their defaults, a model listing and a headless run contacted
`api.x.ai` and nothing else, including over the following 20 seconds (§10).
For an npm install, `grok update --check` asks npm (`npm view`, against
`registry.npmjs.org`); an update could not apply in any case, since `agent`
cannot write the root-owned global npm tree. The adapter should still set
`GROK_DISABLE_AUTOUPDATER=1` and `GROK_TELEMETRY_ENABLED=0`, for the reason
`compose.yaml` turns Claude Code's optional traffic off at the source.

### 2. Prompt delivery

`-p`/`--single` takes the prompt as an argument and does not read stdin; with
no argument and no TTY, Grok tries to start its interactive interface:

```
$ echo "$P" | grok -m grok-build-0.1 -p
error: a value is required for '--single <PROMPT>' but none was supplied
$ echo "$P" | grok -m grok-build-0.1 --output-format plain
Error: No such device or address (os error 6)
```

`--prompt-file /dev/stdin` reads stdin, from a here-string (the launcher's own
form) and from a pipe alike. A 203,697-byte prompt — 2,300 lines of filler
ending in an instruction to reply with a secret word — arrived whole both ways:

```
$ grok -m grok-build-0.1 --permission-mode bypassPermissions \
    --output-format streaming-messages-json --prompt-file /dev/stdin <<<"$P"
… "result":"ZEBRA-4471" …                          # rc=0, 5 s
$ cat big.txt | grok … --prompt-file /dev/stdin
… "result":"ZEBRA-4471" …                          # rc=0
```

Requirement 4c's stdin delivery therefore carries over unchanged; the audit's
proposed temporary file is unnecessary.

### 3. The envelope

`streaming-messages-json` writes one `system`/`init` line, then whole
`assistant` and `user` messages in the Messages-API shape, then one terminal
`result` line. The `result` line of the 200 KB here-string run, in full:

```json
{"type":"result","subtype":"success","is_error":false,"duration_ms":3891,"duration_api_ms":3747,"num_turns":1,"result":"ZEBRA-4471","stop_reason":"end_turn","total_cost_usd":0.0286398,"usage":{"input_tokens":26459,"output_tokens":6,"cache_read_input_tokens":7744,"cache_creation_input_tokens":0,"server_tool_use":{"web_search_requests":0}},"modelUsage":{"grok-build-0.1":{"inputTokens":26459,"outputTokens":6,"cacheReadInputTokens":7744,"cacheCreationInputTokens":0,"webSearchRequests":0,"costUSD":0.0286398,"contextWindow":256000}},"session_id":"01a10f94-4733-79c3-adb2-d779e059b229","uuid":"06dd315a-d424-4af0-9288-f481563fd522"}
```

The pipeline's own readers, sourced from this repository and run over the
captured streams, read it unchanged:

```
$ stage_result_line big-here.stream.jsonl > big-here.out        # rc=0, 632 bytes
$ metering_fields grok-build-0.1 big-here.out '{"n":1}'
{"model":"grok-build-0.1","cost_usd":0.0286398,"duration_ms":3891,"num_turns":1,"is_error":false,"tokens":{"input":26459,"output":6,"cache_creation":0,"cache_read":7744},"gaps":{"n":1}}
```

- `is_error`, `total_cost_usd`, `modelUsage` (with a per-model `costUSD`),
  `num_turns`, `duration_ms` and `session_id` are all present on every
  envelope Grok wrote, success or failure.
- `inputTokens` excludes cache reads, as Claude's does: the same prompt sent
  twice read 26,459 + 7,744 and 33,121 + 1,088 tokens, the same total within
  six.
- `cost_is_partial` and `usage_is_incomplete` were absent from every API-key
  envelope, so no cost was ever withheld on this path.
- An error envelope carries no `result` field; its text is in an `errors`
  array instead (§8).
- The `init` line carries `session_id`, `apiKeySource` (`"user"` for an API
  key), `model`, `cwd`, `permissionMode`, `tools`, `slash_commands`,
  `mcp_servers` and `skills`.

A subscription run's envelope could not be recorded without a subscription;
that half of the question moves to #2139.

### 4. Resume

`-r <session_id>`, with the id from the stream, continues the same session and
keeps its id, as `--resume` does for requirement 9e's salvage. It also works
from a different working directory, with a note on stderr:

```
$ grok … <<<"Remember the number 7319 for later. Reply with exactly OK …"
r1 session=01a10f94-c1fb-71a3-a672-d087c79e817b result=OK
$ grok … -r 01a10f94-c1fb-71a3-a672-d087c79e817b <<<"What number did I ask you to remember? …"
r2 init session=01a10f94-c1fb-…  result-session=01a10f94-c1fb-…  result=7319 turns=1
$ cd ~/other && grok … -r 01a10f94-c1fb-…  <<<"Repeat the number once more …"
Session 01a10f94-c1fb-71a3-a672-d087c79e817b found locally (originally in /home/agent/eval)
{"subtype":"success","is_error":false,"result":"7319","session_id":"01a10f94-c1fb-71a3-a672-d087c79e817b"}
```

### 5. Permissions

Each mode was asked to run `echo ran > probe-<mode>.txt` with no TTY
(`docker exec -i`, no `-t`):

| Flags | `init` reports | Ran it | Outcome |
|---|---|---|---|
| none | `default` | no | `error_during_execution`, `is_error: true`, `stop_reason: "cancelled"`, `errors: ["cancelled"]`; exit 0, 4 s |
| `--permission-mode bypassPermissions` | `bypassPermissions` | yes | `success` |
| `--yolo` | `bypassPermissions` | yes | `success` |
| `--always-approve` | `bypassPermissions` | yes | `success` |
| `--permission-mode dontAsk` | `dontAsk` | no | as the default mode, 2 s |

Nothing prompts or hangs without a TTY: a mode that would ask instead cancels
the tool call at once ("User cancelled the execution for tool
`run_terminal_command`") and the run ends. `--permission-mode
bypassPermissions` is the equivalent of `--dangerously-skip-permissions`;
`--yolo` is an alias for it that 1.0.46's `--help` does not list, so the
explicit form is the one to use. Grok's own documentation notes that `deny`
rules, hooks and some shell `ask` rules still apply in this mode.

### 6. Tools and prompts

Grok exposes 26 tools: `run_terminal_command`, `read_file`, `search_replace`,
`write`, `list_dir`, `grep`, `kill_command_or_subagent`, `todo_write`,
`get_command_or_subagent_output`, `spawn_subagent`, `scheduler_create`,
`scheduler_delete`, `scheduler_list`, `monitor`, `search_tool`, `use_tool`,
`workflow`, `enter_plan_mode`, `exit_plan_mode`, `ask_user_question`,
`send_feedback`, `web_search`, `image_gen`, `image_edit`, `image_to_video` and
`reference_to_video`.

**Long-running commands.** `run_terminal_command` takes `command`,
`description` and a `block_until_ms` the model chooses for itself. Asked to
wait out `sleep 200`, `grok-build-0.1` set `block_until_ms: 300000` and
waited (`"exit_code":0,"timed_out":false`, 211 s). Asked to set
`block_until_ms` to 3000 and then end its turn, it did, and the call returned
`{"type":"BackgroundTaskStarted",…}`. Headless Grok then waited for the
command to finish before exiting (58 s, and the command's output file was
written), but the model never saw the output. The Implementer and Reviewer
prompts' "10-minute ceiling" paragraph describes Claude Code's Bash tool and
is wrong for Grok, whose commands are backgrounded rather than killed; the
neutral reword the audit's §3 proposes should cover it.

**The Implementer prompt as it stands.** Neither model remarked on the prompt
naming "the Bash tool" or `claude -p`; both used `run_terminal_command`
throughout. Six runs were made, in three pairs, because the first two pairs
exposed faults in the harness rather than in Grok: the first did not push the
claim branch before launch, and the second's `gh` stand-in reported a pull
request that did not exist, whose title and body no edit could change, and
both models spent most of their turns fighting it. The third pair, with both
faults fixed, are the runs of record:

| Run | Model | Wall-clock | Turns | Input | Output | Cache read | Cost |
|---|---|---:|---:|---:|---:|---:|---:|
| a | `grok-build-0.1` | 114 s | 25 | 36,133 | 2,461 | 793,344 | US$0.222 |
| a | `grok-4.3` | 34 s | 19 | 33,038 | 1,173 | 567,872 | US$0.160 |
| b | `grok-build-0.1` | 147 s | 32 | 39,967 | 5,028 | 1,085,440 | US$0.293 |
| b | `grok-4.3` | 73 s | 37 | 66,657 | 2,074 | 1,134,400 | US$0.323 |
| **c** | **`grok-build-0.1`** | **81 s** | **21** | **27,309** | **2,072** | **654,592** | **US$0.183** |
| **c** | **`grok-4.3`** | **36 s** | **18** | **32,775** | **1,201** | **537,152** | **US$0.155** |

The prompt was 77,352 bytes. Both runs of record:

- read `AGENTS.md` first and worked on the existing `agent/7`;
- fixed the bug correctly, with tests covering every case the issue names, and
  ran the suite before committing (`all tests passed` on the pushed branch);
- committed with a Conventional Commits message, pushed, and opened a **draft**
  pull request whose body carries `<!-- agent-ops:closes-issue item=7 -->` and
  a `## Changelog` section;
- labelled the pull request with a `complexity:` grade, and ended with exactly
  one well-formed `complete` verdict.

Neither followed the procedure in full:

- **Neither posted the issue claim comment** that step 2 requires for an
  `issues` item ("Comment on the issue linking the draft PR").
  `grok-build-0.1` posted it, with the exact header and marker, in both of its
  earlier runs.
- **`grok-4.3` implemented, committed and pushed before opening the draft
  pull request**, which step 2 says to open before writing the fix;
  `grok-build-0.1` opened it first.
- **`grok-4.3` left off the work order's `pr_label`** (`autonomous-agent`).
- **Each body fails one of this repository's required gates**, run here over
  the bodies as CI runs them. `grok-build-0.1`'s carries the marker but says
  only "Addresses issue #7", so `scripts/check-closing-keyword.sh` fails it
  ("PR body names issue #7 … but has no closing keyword"); `grok-4.3`'s says
  "Fixes #7" but lists its changelog bullet with no Keep a Changelog category
  heading, so `scripts/check-changelog-section.sh` fails it ("the first line
  under `## Changelog` must be a `### <Category>` heading or the line
  `None.`").

The required checks would turn both pull requests red, and the missing label
would be visible to the Reviewer; nothing would catch a missing claim comment. One small scratch task is not a basis for a
capability or tier judgement (requirement 1c), and no Claude run of the same
harness was made to compare against, to spare the owner's Claude budget.
What these runs establish is that the shipped prompt runs to completion on
both models without change, and that prompt adherence needs measuring on real
items before a non-Claude provider is trusted with unattended work.

### 7. Skills

With the review skill staged at `.claude/skills/project-review/` as
`review-cycle.sh` stages it, Grok lists nothing until the folder is trusted.
Its documentation is explicit: "Folder trust gates … startup loading of project
instructions and skills. Headless startup with these sources requires
`--trust` or a prior grant."

```
$ grok inspect                         # untrusted
  └ Project trusted: no
  Project Instructions (0)
  Skills (0)
$ GROK_FOLDER_TRUST=0 grok inspect
  └ Project trusted: yes
  Project Instructions (2)
  └ /home/agent/trust2/CLAUDE.md (project, ~2 tokens)
  └ /home/agent/trust2/AGENTS.md (project, ~169 tokens)
  Skills (1)
  └ project-review  project [claude]
```

Trusted, the `init` line lists `"skills":["project-review"]` (and
`project-review` among the slash commands), and asked to load the skill, the
model read `.claude/skills/project-review/SKILL.md` and quoted its first
heading correctly. There is no dedicated skill tool; a skill is loaded by
reading its file. `--trust` works too, but it records each trusted directory
in `$GROK_HOME/trusted_folders.toml`, and a node clones into a new directory
every cycle, so that file would grow without bound. `GROK_FOLDER_TRUST=0`
trusts every folder without writing anything, and it is also what makes Grok
auto-load the clone's `AGENTS.md` and `CLAUDE.md`, as `claude -p` auto-loads
`CLAUDE.md`. #2136 can therefore stage the skill exactly as today.

### 8. Limits and refusals

| Case | How produced | Exit | `errors[0]` (truncated by Grok) | Retries | `LIMIT_PHRASE_REGEX` |
|---|---|---:|---|---|---|
| Invalid key | real API | 1 | `Not signed in. To authenticate without a browser, run: grok login --device-code …` | none | no |
| No key | real API | 1 | the same | none | no |
| Unknown model | real API | 1 | `Couldn't set model 'grok-nonexistent-9': Invalid params: "unknown model id". …` | none | no |
| Credits exhausted (429) | stand-in, xAI's documented wording | 1 | `Some resource has been exhausted: Your team has either used all available credits or reached its monthly spending limit. To continue making API requests, please purchase more credi...` | one, honouring `Retry-After: 1` | **no** |
| Rate limit (429) | stand-in | 1 | `Too many requests: Rate limit exceeded for requests per minute. Please slow down.` | one, after 2 s | yes |
| Unauthorised mid-run (401) | stand-in | 1 | `Internal error: "Unauthorized (401) from …/v1/chat/completions: Unauthorized: Incorrect API key provided. …` | none | no |
| Outage (503) | stand-in | killed at 400 s | none: no output at all | 21 and counting, back-off growing past 30 s | — |
| Tool call refused | real API, default mode | 0 | `cancelled` | — | no |

- **No structured event.** No run emitted anything like Claude Code's
  `rate_limit_event`; the audit's reading of the documentation is confirmed.
- **The refusal classifier sees none of it.** Every failure envelope above has
  `is_error: true`, `num_turns: 0` (bar the cancelled tool call) and a
  zero `total_cost_usd`, but no `result`, `terminal_reason` or
  `api_error_status`, so `stage_api_refusal` printed nothing for any of the
  seven envelopes it was run over.
- **The texts are classifiable.** "Not signed in" and "Unauthorized (401)"
  are authentication failures; "Too many requests" and "Some resource has been
  exhausted" are limits; the 401 carries its status in parentheses, the 429s
  do not.
- **Grok checks an API key before any model call.** An invalid key fails in
  under a second with the same message as a missing one. Against the
  stand-in, Grok's requests began `GET /v1/models` and `GET /v1/api-key`, then
  tried `POST /v1/responses` and, when that was refused, `POST
  /v1/chat/completions`.

An exhausted subscription pool could not be provoked without a subscription,
and is #2139's to record.

### 9. Credentials and files

**The key is never written.** Grok reads `XAI_API_KEY` from the environment;
a search of `$GROK_HOME` and every working directory for the key's exact value
found it in no file after 47 runs. With an API key, `grok models` prints "You
are using XAI_API_KEY." and its model list comes from `https://api.x.ai/v1/models`
(the default model is `grok-4.20-0309-non-reasoning`, not the `grok-4.7` the
documentation names, so the adapter must always pass `-m`). `grok models` is
not a credential probe: with an invalid key it prints the same line and exits
0. xAI's own `GET https://api.x.ai/v1/api-key`, which Grok calls itself, is
one: it answered 200 with the key's `api_key_blocked`, `api_key_disabled`,
`team_blocked` and `acls` for the real key, and 400 for an invalid one.

**What `$GROK_HOME` holds after a day's work** (`grok du`: 6.3 MB after 47
runs):

| Path | What | Must persist? |
|---|---|---|
| `auth.json` | the subscription session (not created on the API-key path) | yes, for #2139 |
| `sessions/<url-encoded cwd>/<session id>/` | one directory per session, under one directory per working directory | only for a resume within the cycle |
| `sessions/<cwd>/prompt_history.jsonl` | **every prompt, verbatim** (415 KB after two 200 KB prompts) | no — prune with the sessions |
| `sessions/session_search.sqlite` | a search index over all sessions (844 KB) | no |
| `logs/unified.jsonl` | a structured log, about 12 KB per run, no rotation found | no |
| `memtrace/`, `models_cache.json`, `agent_id`, `config.toml`, `docs/`, `README.md` | small caches, an install id, Grok's own documentation | no |
| `trusted_folders.toml` | one entry per folder trusted with `--trust` | avoided by `GROK_FOLDER_TRUST=0` |

Every fresh clone is a new working directory, so the session tree gains a
directory per stage run. `storage.cleanup_ttl_days` in `config.toml` ("Days a
session may stay idle before its folder is deleted") is Grok's own pruning;
unset, it never prunes. Because `prompt_history.jsonl` keeps every prompt — work
orders, issue bodies and review content included — the session tree is
sensitive in the same way Claude's `projects/` directory is.

**Device-code login from a container.** `grok login --device-auth` (also
spelled `--device-code`, which is what Grok's own error message suggests)
works from a non-TTY `docker exec`: it prints a verification URL on
`accounts.x.ai` for the subscriber's own browser and a code, then polls:

```
$ grok login --device-auth </dev/null
To sign in, open this URL in your browser:
  https://accounts.x.ai/oauth2/device?user_code=XXXX
  (Could not open browser automatically — open the URL above manually.)
Confirm this code in your browser:
  XXXX-XXXX
Waiting for authorization...
```

It was stopped there: completing it needs a subscription, and whether it
completes, where `auth.json` lands and how it refreshes are #2139's.

### 10. Egress

Measured behind the fence, from the proxy's own access log:

| What ran | Allowlist additions | Proxy log |
|---|---|---|
| `grok models` and one headless run, telemetry and updater at their defaults, fresh `$GROK_HOME` | `api.x.ai` | `4 TCP_TUNNEL/200 api.x.ai:443` and nothing else |
| `grok login --device-auth` | `api.x.ai` | `1 TCP_DENIED/403 auth.x.ai:443`; the login failed at once with `tunnel error: unsuccessful`, exit 1 |
| `grok login --device-auth` | `api.x.ai auth.x.ai` | `1 TCP_TUNNEL/200 auth.x.ai:443`; the code was printed and polling began |
| `grok update --check --json` | `api.x.ai auth.x.ai` | `1 TCP_TUNNEL/200 registry.npmjs.org:443` (already on the baked list) |

- **API-key path:** `api.x.ai` only. Grok honours `HTTPS_PROXY`.
- **Device-code login:** `auth.x.ai` from the node; `accounts.x.ai` is opened by
  the subscriber's own browser, not the node.
- **Subscription model calls:** not measured. The model catalogue names
  `https://cli-chat-proxy.grok.com/v1` as each model's `base_url` and
  `https://api.x.ai/v1` as its `api_base_url`; the API-key path used the
  latter. #2139 should confirm the former with a subscription behind the
  fence.

## Beyond the ten questions

**Process cleanup.** The launcher kills a stage by process group (`set -m`,
then `kill -TERM -$pid`). Grok runs every `run_terminal_command` in a new
session — the command's process-group and session ids are its own, not
Grok's — so the group kill misses it:

```
  PID  PPID  PGID   SID COMMAND
 3123  3116  3123  3116 grok -m grok-build-0.1 --yolo --output-format …
 3215  3123  3215  3215 /usr/bin/bash -O extglob -c snap=$(command cat <&3); …
 3219  3215  3215  3215 sleep 95
$ kill -TERM -- -3123
 3219     1  3215  3215 S    sleep 95          # still running, reparented to PID 1
```

`SIGTERM` or `SIGINT` sent to Grok alone fared no better: Grok exited within
two seconds, wrote no `result` line, and left the command running. A stage
killed at its backstop or by the watchdog would therefore leave its last
command — a test suite, a build — running on the node.

**Exit status.** A run that fails before its first model turn (authentication,
an unknown model, a rate limit on the first call) exits 1; a run that fails
inside a turn (a cancelled tool call) exits 0 with `is_error: true`. Only the
envelope is reliable.

**Stream timing.** Grok writes an `assistant` message only once the whole
message, tool calls included, has completed; during a 200-second command the
stream held only the `init` line. Claude Code writes the `tool_use` before
running the tool. The silence the liveness watchdog measures is the same
either way, but the last line of a wedged Grok stage's stream does not show
what it is running.

## The adapter specification for #2134

What #2134's xAI adapter should implement on the API-key path, behind the seam
#2133 cuts, and what #2139 inherits for the subscription path.

**Image (D28, D14).** In the root-run block that installs Claude Code, before
`ENV HOME`, pinned like it:

```dockerfile
ARG GROK_BUILD_VERSION=1.0.46
RUN GROK_HOME=/tmp/grok-install npm install -g "@xai-official/grok@${GROK_BUILD_VERSION}" \
    && rm -rf /tmp/grok-install \
    && npm cache clean --force
```

That adds 211 MB, and nothing under any home directory. Bump deliberately, as
`CLAUDE_CODE_VERSION` is bumped.

**Environment** (the scheduler's `environment:` block, beside Claude Code's
optional-traffic switches): `GROK_DISABLE_AUTOUPDATER=1`,
`GROK_TELEMETRY_ENABLED=0`, `GROK_FOLDER_TRUST=0`, and `GROK_HOME` set
explicitly to a directory on a volume (a `grok-config` volume, mirroring
`claude-config`), with `XAI_API_KEY` passed through as `ANTHROPIC_API_KEY` is.

**Invocation**, from the clone, with the prompt on stdin:

```bash
grok -m "$model" --permission-mode bypassPermissions \
  --output-format streaming-messages-json \
  --prompt-file /dev/stdin ${resume_session_id:+-r "$resume_session_id"} <<<"$prompt"
```

Always pass `-m`: the default model differs by credential path. Do not pass
`--trust` (see §7).

**Reading the run.** `stage_result_line` and `metering_fields` work unchanged,
and `provider` joins the metering record per #2133. The exit status is not a
verdict: judge success from the envelope's `is_error`, and treat a missing
`result` line as a killed or crashed run, as today.

**Normalising failures.** Before the `.out` reaches `stage_api_refusal`,
rewrite a failure envelope (`is_error: true` with an `errors` array and no
`result`) into the shape the classifier already understands:

- `result` = the `errors` entries joined;
- `terminal_reason` = `"api_error"` when `num_turns` is 0;
- `api_error_status` = the status Grok prints in parentheses (`(401)`), or 429
  for `Too many requests` and `Some resource has been exhausted`.

With that, `Not signed in` and `Unauthorized (401)` classify as
`authentication_failed` through the existing test, and the 429s as
`api_error_429`, with no change to `lib/stage-attempt.sh`.

**Limits (requirement 2.1).** There is no structured event, so
`limit_decide_structured` has nothing to read and detection is by phrase.
Add, for this provider, `too many requests`, `resource has been exhausted`,
`used all available credits` and `spending limit` to the phrases
`LIMIT_PHRASE_REGEX` already holds, and record the account the limit belongs
to per #2135. Recheck the phrases against the first real occurrence of each.

**Killing a stage.** Before signalling Grok, walk its descendants (`/proc/*/stat`
parent ids from Grok's pid), collect their process-group ids, and signal each
group as well as Grok's own; snapshot the tree first, because Grok's children
reparent to PID 1 the moment it dies. As a backstop, sweep any process whose
working directory is under the cycle's clone directory when the cycle ends.
Requirement 9c's signal handler needs the same treatment.

**`doctor`.** Shape-check `XAI_API_KEY` for the `xai-` prefix (the one key
seen was 84 characters; do not fail on length), and probe it with `GET
https://api.x.ai/v1/api-key`, which answers 200 with `api_key_blocked`,
`api_key_disabled` and `team_blocked` for a usable key and 400 for an invalid
one. Do not use `grok models`, which exits 0 either way.

**Files.** Persist `$GROK_HOME` for `auth.json` (#2139) and for a resume
within the cycle. Set `[storage] cleanup_ttl_days` in a seeded
`$GROK_HOME/config.toml` (as `entrypoint.sh` seeds `claude-settings.json`), and
prune `sessions/` and `logs/unified.jsonl` in the node's own housekeeping, since
`prompt_history.jsonl` holds every prompt verbatim.

**Egress (D24).** `api.x.ai` for the API-key path. #2139 adds `auth.x.ai`
(verified for the login) and, once confirmed, `cli-chat-proxy.grok.com`.

**Prompts.** The audit's §3 reword covers it; add that the "10-minute ceiling"
paragraph describes Claude Code's Bash tool, and that under Grok a command
outliving the model's own `block_until_ms` is backgrounded rather than killed.

## Gaps, and what would close them

| Gap | Why it is open | Proposed handling |
|---|---|---|
| A subscription run's envelope, chat host and pool-exhaustion message | No subscription was available | #2139, with the customer's negotiated credential |
| Real 429 and outage texts | Provoking them would spend credit or wait on an incident | The stand-in used xAI's documented credit wording; capture the first real occurrence of each and adjust the phrases |
| Prompt adherence at scale | Two runs of one small task | A first fleet trial on low-complexity items in a non-critical repository, with the Reviewer and Approver left on Claude, measured against the same items' Claude record |
| A Claude baseline on the same harness | Spared to save the owner's Claude budget | Optional; one run of each Claude tier on this harness would put the costs above in context |
| Cross-provider tier ordering (requirement 1c) | One task cannot rank models | Decide with the open question the roadmap already records, from the fleet trial |
| Whether `--trust`, hooks and project MCP servers from a target repository should be trusted | `GROK_FOLDER_TRUST=0` trusts them all, as Claude Code does today | Keep parity, and narrow with `GROK_CLAUDE_HOOKS_ENABLED`/`GROK_CLAUDE_MCPS_ENABLED` if a target repository ever ships either |
