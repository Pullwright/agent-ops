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

Six findings are new, and each needs handling in the adapter:

- **A process-group kill does not reach Grok's commands.** Grok starts each
  shell-tool command in its own session, so the launcher's `kill -TERM
  -$pid` ends Grok and leaves its commands running, reparented to PID 1.
  Grok's own clean-up on `SIGTERM` cannot be relied on. Running Grok
  under a child subreaper contains every descendant without privilege; the
  node's container allows neither a PID namespace nor a cgroup of its own.
- **The exit status is not a verdict.** Every API failure observed exits 1,
  before or after the first completed turn, but a run whose tool call is
  cancelled exits 0 with `is_error: true`. The launcher's callers branch on
  its return code, so the adapter must fold `is_error` into it.
- **Every Grok failure is invisible to the refusal classifier.** Grok puts its
  error text in an `errors` array, with no `terminal_reason` and no
  `api_error_status`, so `stage_api_refusal` returns nothing for any of them —
  an expired key, a rate limit and exhausted credits all read as a bare "exited
  1". Grok emits no structured rate-limit event, and the existing `rate limit`
  phrase already matches xAI's 429 text, so until #2135 scopes a limit to its
  account, one Grok rate limit would stand the whole fleet down.
- **A 503 is retried silently for about 22 minutes.** Grok writes nothing to
  its stream or to stderr while it retries, only to its own log, so with its
  defaults the liveness watchdog ends such a stage first and leaves no
  envelope to classify. `[models] max_retries = 6` makes Grok give up in under
  five minutes, with an envelope that carries the status.
- **Without `--include-partial-messages`, one silence spans a whole message.**
  Grok writes an assistant message only once it and all its tool calls have
  finished. With the flag, it writes the `tool_use` before the command runs,
  as Claude Code does.
- **Trusting a folder trusts its hooks and MCP servers.** `GROK_FOLDER_TRUST=0`,
  which project instructions and the review skill need, also runs a
  checkout's own hooks and MCP servers at start-up. Two root-owned policy pins
  in `/etc/grok/requirements.toml` stop them and leave the instructions and
  the skill loaded.

The two Implementer-shaped runs of record both produced a correct fix with
passing tests and a well-formed verdict, in 81 seconds for US$0.183
(`grok-build-0.1`) and 36 seconds for US$0.155 (`grok-4.3`); neither followed
the prompt's procedure in full (§6). The whole evaluation spent US$1.94 of the
owner's prepaid xAI credit across 47 runs, and the follow-up runs that
answered the pull request's review about US$0.10 more across 29.

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
  — a rate limit, exhausted credits, a 401, an outage — came from a local
  HTTP stand-in for `api.x.ai`, reached through Grok's own
  `GROK_XAI_API_BASE_URL` override, which forwarded `GET /v1/models` and
  `GET /v1/api-key` to the real API and answered everything else with the
  status under test. A second stand-in also forwarded the first chat
  completion, so that the run completed one real turn before it failed. The
  credit-exhaustion body uses the wording xAI documents for that error; the
  others are representative, so the phrase matching in §8 should be
  rechecked against the first real occurrence of each.
- **Follow-up runs.** The pull request's review prompted a second set of runs
  the same day, in a fresh throwaway container from the image at revision
  `6c9e61b` (built 2026-10-06T05:35Z) with Grok 1.0.46 installed by §1's
  recipe. They cover failures after a completed turn, Grok's retry ceiling,
  stream timing, a containment primitive for the launcher, and which
  project-supplied hooks and MCP servers run. Their cost is an estimate,
  because most were killed or failed before Grok reported one.
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
`result` line. With `--include-partial-messages` it also writes the Messages
streaming events (`stream_event` lines) as the model generates, and the
`result` line is still the last. The `result` line of the 200 KB here-string
run, in full:

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
  envelope Grok wrote, success or failure. `modelUsage` never lists the
  session-title call Grok makes on another model (see "Session titles"
  below).
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
`CLAUDE.md`. #2136 can therefore stage the skill exactly as today. The same
trust also loads the clone's own hooks and MCP servers, which the
specification's "Project-supplied hooks and MCP servers" pins off.

### 8. Limits and refusals

| Case | How produced | Exit | `errors[0]` (truncated by Grok) | Retries | `LIMIT_PHRASE_REGEX` |
|---|---|---:|---|---|---|
| Invalid key | real API | 1 | `Not signed in. To authenticate without a browser, run: grok login --device-code …` | none | no |
| No key | real API | 1 | the same | none | no |
| Unknown model | real API | 1 | `Couldn't set model 'grok-nonexistent-9': Invalid params: "unknown model id". …` | none | no |
| Credits exhausted (429) | stand-in, xAI's documented wording | 1 | `Some resource has been exhausted: Your team has either used all available credits or reached its monthly spending limit. To continue making API requests, please purchase more credi...` | one, honouring `Retry-After: 1` | **no** |
| Rate limit (429) | stand-in | 1 | `Too many requests: Rate limit exceeded for requests per minute. Please slow down.` | one, after 2 s | yes |
| Unauthorised (401) on the first model call | stand-in | 1 | `Internal error: "Unauthorized (401) from …/v1/chat/completions: Unauthorized: Incorrect API key provided. …` | none | no |
| Outage (503) | stand-in | 1, after about 22 minutes | `Internal error: {"message": "API error (status 503 Service Unavailable): …", "http_status": 503}` | 15 attempts per request, then the turn three more times | no |
| Tool call refused | real API, default mode | 0 | `cancelled` | — | no |

**After a completed turn.** Through the second stand-in, each run first
completed one real turn (the model asked to run `echo one`, the command ran,
`num_turns: 1`), and its next model call then failed:

| Case | Exit | `errors[0]` | Retries | Cost reported |
|---|---:|---|---|---:|
| Unauthorised (401) | 1 | `Internal error: {"message": "Unauthorized (401) from …/v1/chat/completions: Unauthorized: Incorrect API key provided. …` | none | US$0.0113 |
| Rate limit (429) | 1 | `Too many requests: Rate limit exceeded for requests per minute. Please slow down.` | one | US$0.0090 |
| Credits exhausted (429) | 1 | `Some resource has been exhausted: Your team has either used all available credits …` | one | US$0.0059 |

An API failure exits 1 whether or not a turn has completed, and its text is
the same apart from the 401's JSON wrapper, which keeps `Unauthorized (401)`.
The only exit 0 with `is_error: true` seen in either set is the cancelled tool
call.

**An outage ends, eventually.** The first 503 run was stopped at 400 seconds
after 21 attempts with nothing written, which read as an indefinite retry. A
900-second run and Grok's own log (`$GROK_HOME/logs/unified.jsonl`) show the
structure instead. Each model request is attempted 15 times
(`shell.turn.inference_retry`, `"max_retries": 15`), with a back-off that
doubles from 2 seconds to a ceiling near 30, which takes about 333 seconds.
Grok then logs `shell.turn.inference_failed` with `"status_code": 503` and
retries the whole turn (`shell.turn.transient_retry_backoff`, three times).
Four rounds take about 22 minutes, and the stream and stderr stay empty
throughout. Lowering the ceiling shows how it ends:

| Setting | Attempts | Wall-clock | Exit | Envelope |
|---|---:|---:|---:|---|
| `[models] max_retries = 2` in `$GROK_HOME/config.toml` | 8 | 54 s | 1 | as below |
| `GROK_MAX_RETRIES=2` | 8 | 55 s | 1 | `Internal error: {"message": "API error (status 503 Service Unavailable): …", "http_status": 503}` |
| `GROK_MAX_RETRIES=6` | 24 | 282 s | 1 | the same |
| `GROK_MAX_RETRIES=2 GROK_TURN_TRANSIENT_RETRY=0` | 2 | 4 s | 1 | the same |

`[models] max_retries` is in Grok's configuration reference.
`GROK_MAX_RETRIES` and `GROK_TURN_TRANSIENT_RETRY` are environment variables
the binary reads but its documentation does not list.

- **No structured event.** No run emitted anything like Claude Code's
  `rate_limit_event`; the audit's reading of the documentation is confirmed.
- **The refusal classifier sees none of it.** Every failure envelope above has
  `is_error: true` but no `result`, `terminal_reason` or `api_error_status`,
  so `stage_api_refusal` printed nothing for any of the eleven envelopes it
  was run over. A failure before the first turn reports `num_turns: 0` and no
  cost; one after it keeps the completed turn's count and cost.
- **The texts are classifiable.** "Not signed in" and "Unauthorized (401)"
  are authentication failures; "Too many requests" and "Some resource has been
  exhausted" are limits. The 401 carries its status in parentheses and the 503
  as `http_status`; the 429s carry none.
- **One existing phrase already matches.** `Too many requests: Rate limit
  exceeded …` matches `rate limit` in `LIMIT_PHRASE_REGEX`, and
  `detect_and_log_limit_hit` searches a stage's `.out`, which holds this
  envelope. A Grok stage's 429 would therefore publish a fleet-wide
  `limit-hit` today (see the specification's Limits paragraph).
- **Grok checks an API key before any model call.** An invalid key fails in
  under a second with the same message as a missing one. Against the
  stand-in, Grok's requests began `GET /v1/models` and `GET /v1/api-key`,
  then `POST /v1/chat/completions` for every model turn. The `POST
  /v1/responses` that accompanies them is not a fallback but the session-title
  call (see "Session titles" below).

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

**Containing them.** Walking `/proc` for Grok's descendants and signalling
each group, as this record first proposed, races a command started between
the walk and the signal, and misses anything that has already left Grok's
tree. A containment primitive closes both gaps, but under the scheduler's own
settings (user `agent`, no added capabilities, Docker's default seccomp
profile) the two strong ones are unavailable:

```
$ unshare --user --map-root-user --pid --fork --kill-child --mount-proc true
unshare: unshare failed: Operation not permitted
$ mkdir /sys/fs/cgroup/stage-test
mkdir: cannot create directory '/sys/fs/cgroup/stage-test': Read-only file system
```

A child subreaper is available. `prctl(PR_SET_CHILD_SUBREAPER)` needs no
privilege, and `python3`, already one of the image's hard requirements, can
make the call. When a process below a subreaper loses its parent, it is
reparented to the subreaper rather than to PID 1, whatever session or process
group it has put itself in and wherever it has changed directory. The
subreaper can therefore kill whatever is left when the stage ends, repeating
until a pass finds nothing. A short `python3` prototype did this:

| Test | Under the launcher's group kill | Under the subreaper |
|---|---|---|
| A `setsid` child and a double-forked daemon that had changed directory to `/`, no Grok | both survived, reparented to PID 1 | both reparented to the subreaper and killed in one pass |
| Grok running `sleep 95` | the command survived in 3 of 3 runs | none survived in 4 runs: the sweep killed the command in 1, and in 3 Grok's own handling of the signal, which the subreaper also forwards to it, had already ended it |

In a fifth run with the sweep disabled, the command outlived Grok, waited
under the subreaper, and was reparented to PID 1 when the subreaper exited.
Grok's own handling therefore cannot be relied on, and the sweep is what
makes the containment hold.

**Exit status.** Every API failure observed exits 1, before the first model
turn or after a completed one (§8). A run whose tool call is cancelled exits 0
with `is_error: true` (§5). That cannot happen under `--permission-mode
bypassPermissions`, but nothing shows it is the only in-run failure that exits
0, so only the envelope is reliable.

**Stream timing.** Without `--include-partial-messages`, Grok writes an
`assistant` message only once the whole message, tool calls included, has
completed: during a 200-second command the stream held only the `init` line.
One silence therefore spans the model's generation and every command in the
message, whereas Claude Code writes the `tool_use` as soon as the model has
finished it and the `tool_result` as the tool finishes. The liveness
watchdog's thresholds come from recorded gaps (requirement 4f).
`lib/stage-budget.sh` keeps a cell per actor, repository and model, but pools
each actor's gaps across every model above it, so a new Grok cell would start
from Claude's history, and Grok's longer gaps would then move the pool
Claude's cells draw on. A Grok message that ran `npm ci` and the test suite
back to back could be killed as wedged while it was working. With the flag,
Grok's stream has Claude Code's shape (seconds from launch):

```
   1.3  system init
   1.4  stream_event content_block_start thinking      27 thinking deltas follow
   5.7  stream_event content_block_start tool_use
   5.8  stream_event content_block_stop                the tool_use is complete; `sleep 60` starts
  65.8  stream_event message_delta, message_stop, then the assistant line
  66.3  user (the tool_result)
  66.9  result success
```

The silence is the command's own 60 seconds. The flag adds lines but changes
nothing the pipeline's readers use, since the `result` line is still the last.

**Session titles.** Every session also sends a `POST /v1/responses` to
`grok-4.6`, whatever `-m` names, with a system prompt that begins "You are
tasked with generating the session title" and the user's prompt as its query,
truncated: a 65 KB prompt made a 9.2 KB request. Neither `[features]
title_refresh = false` nor `GROK_TITLE_REFRESH=0` stopped it, and no other
switch was found. Its cost is not in the envelope, because `modelUsage` named
only the run's own model in all six Implementer runs. That is a few thousand
input tokens per stage on a second model, outside the metering record. The
head of every stage prompt also reaches `grok-4.6`, though the provider is
the same, so no new party sees it.

## The adapter specification for #2134

What #2134's xAI adapter should implement on the API-key path, behind the seam
#2133 cuts, and what #2139 inherits for the subscription path.

**Image (D28, D14).** In the root-run block that installs Claude Code, before
`ENV HOME`, pinned like it:

```dockerfile
ARG GROK_BUILD_VERSION=1.0.46
RUN GROK_HOME=/tmp/grok-install npm install -g "@xai-official/grok@${GROK_BUILD_VERSION}" \
    && rm -rf /tmp/grok-install \
    && npm cache clean --force \
    && mkdir -p /etc/grok \
    && printf '%s\n' 'allow_managed_hooks_only = true' 'allowed_mcp_servers = []' \
         > /etc/grok/requirements.toml
```

That adds 211 MB, nothing under any home directory, and a root-owned policy
file that `agent` cannot edit (see "Project-supplied hooks and MCP servers"
below). Bump the version deliberately, as `CLAUDE_CODE_VERSION` is bumped.

**Environment** (the scheduler's `environment:` block, beside Claude Code's
optional-traffic switches): `GROK_DISABLE_AUTOUPDATER=1`,
`GROK_TELEMETRY_ENABLED=0`, `GROK_FOLDER_TRUST=0`, and `GROK_HOME` set
explicitly to a directory the container owns, with `XAI_API_KEY` passed
through as `ANTHROPIC_API_KEY` is. The API-key path needs nothing in
`GROK_HOME` to outlive the container; #2139 puts it on a `grok-config` volume,
mirroring `claude-config`, for the subscription's `auth.json`.

**Invocation**, from the clone, with the prompt on stdin:

```bash
grok -m "$model" --permission-mode bypassPermissions \
  --output-format streaming-messages-json --include-partial-messages \
  --prompt-file /dev/stdin ${resume_session_id:+-r "$resume_session_id"} <<<"$prompt"
```

Always pass `-m`: the default model differs by credential path. Pass
`--include-partial-messages` so that one silence spans one command, not a
whole message ("Stream timing" above). Do not pass `--trust` (see §7).

**Reading the run.** `stage_result_line` and `metering_fields` work unchanged,
and `provider` joins the metering record per #2133. The exit status is not a
verdict, and the adapter, not its callers, must make it one: twelve of the
thirteen call sites branch on what `run_claude_stage` returns (`if
run_claude_stage …; then`, `stage_salvage_result` among them), so a Grok run
that exits 0 with `is_error: true` would take every caller's success branch
and be parsed as a verdict. Return 1 when Grok exited 0 but the last line's
`is_error` is true, or when it exited 0 without writing a `result` line, and
Grok's own status otherwise; the caps' 124 is unchanged.

**Normalising failures.** Before the `.out` reaches `stage_api_refusal`,
rewrite a failure envelope (`is_error: true` with an `errors` array and no
`result`) into the fields the classifier reads, whatever `num_turns` says:

- `result`: the `errors` entries, joined;
- `api_error_status`: the status Grok prints in parentheses (`(401)`) or as
  `"http_status": 503`, or 429 for `Too many requests` and `Some resource has
  been exhausted`;
- `terminal_reason`: `"api_error"` for an authentication failure (`Not signed
  in`, `Unauthorized`, `(401)`), so that the classifier's existing
  authentication test names it; `"credit_exhausted"` for xAI's credit or
  spending-limit text; otherwise unset. `stage_api_refusal` returns any other
  reason verbatim and falls back to `api_error_<status>` only when the reason
  is empty or `completed`, so setting `"api_error"` for every failure would
  hide the status.

As jq, over the envelope:

```jq
def grok_status($t):
  first(
    ($t | match("\\(([1-5][0-9]{2})\\)|\"http_status\": *([1-5][0-9]{2})")
        | .captures[] | select(.string != null) | .string | tonumber),
    (if ($t | test("too many requests|some resource has been exhausted"; "i")) then 429 else empty end),
    null);
if (.is_error == true) and (.result == null) and ((.errors // []) | length > 0) then
  (.errors | map(tostring) | join("\n")) as $t
  | grok_status($t) as $s
  | .result = $t
  | if ($t | test("not signed in|unauthori[sz]ed|\\(401\\)"; "i")) then
      .terminal_reason = "api_error" | (if $s == null then . else .api_error_status = $s end)
    elif ($t | test("used all available credits|spending limit"; "i")) then
      .terminal_reason = "credit_exhausted" | .api_error_status = $s
    elif $s != null then .api_error_status = $s
    else . end
else . end
```

Run over the eleven captured failure envelopes and then through the shipped
`lib/stage-attempt.sh` (the last column adds the one arm proposed below):

| Envelope | `num_turns` | `stage_api_refusal` | `stage_api_refusal_class` | With the 429 arm |
|---|---:|---|---|---|
| Invalid key; no key | 0 | `authentication_failed` | `refused` | `refused` |
| Unauthorised (401), first call | 0 | `authentication_failed` | `refused` | `refused` |
| Unauthorised (401), after a turn | 1 | `authentication_failed` | `refused` | `refused` |
| Rate limit (429), first call and after a turn | 0, 1 | `api_error_429` | **`refused`** | `transient` |
| Credits exhausted (429), first call and after a turn | 0, 1 | `credit_exhausted` | `refused` | `refused` |
| Outage (503) | 0 | `api_error_503` | `transient` | `transient` |
| Unknown model; cancelled tool call | 0, 1 | none | none | none |

The same failure now gives the same detail before and after a completed turn,
so requirement 2.7 groups it once. Two cases need the classifier itself:

- **A rate limit is transient**, clearing within the minute it names, but
  `stage_api_refusal_class` grades every 4xx `refused`, so a run of them would
  be escalated as a deterministic fault, the misreading #1073 removed for
  outages. Add one arm after the 5xx test, `elif ($status == 429 and $r
  == "") then "transient"`; the `$r == ""` keeps `credit_exhausted`, the one
  non-transient 429 seen here, out of it. The arm applies to Claude Code's
  envelopes too, so whether they ever carry a 429 that is not transient
  should be checked when it is added.
- **Exhausted credit stays `refused`**, deliberately. Only a top-up, which is
  an owner act, or the month's rollover clears it, and until #2135 lets the
  xAI account stand down on its own, an escalation that reaches the owner is
  the right outcome.

**Limits (requirement 2.1).** There is no structured event, so
`limit_decide_structured` has nothing to read and detection is by phrase.
`detect_and_log_limit_hit` publishes what it finds as a fleet-wide
`fleet/limit.json`, and `limit_class_of` grades any text containing "monthly"
as the monthly class, whose fallback stand-down is
`LIMIT_LONG_COOLDOWN_HOURS` (24). The order therefore matters:

1. **Before #2135,** keep phrase detection off a Grok stage's output
   altogether. xAI's 429 text already matches `rate limit` (§8), so without
   that, one Grok rate limit would stand every node down, Claude stages
   included; adding the credit phrases would do the same for up to a day.
   Until then a Grok limit reaches the record through the refusal path
   above, as `api_error_429` (transient) or `credit_exhausted` (refused, so
   it reaches the owner).
2. **With #2135,** which records the account a limit belongs to, add `too
   many requests`, `resource has been exhausted`, `used all available
   credits` and `spending limit` for this provider, scoped to the xAI
   account. Requirement 2.1b's probe asks Claude today, so it needs an xAI
   form, because a top-up clears a credit exhaustion at once. Recheck the
   phrases against the first real occurrence of each.

**Outages.** Seed `[models] max_retries = 6` (see "Files" below). At Grok's
default of 15, a 503 is retried silently for about 22 minutes, longer than the
shipped 10-minute inactivity prior, so the watchdog kills the stage first and
leaves no envelope to classify. At 6, Grok gives up after about 282 seconds
with exit 1 and an envelope carrying `"http_status": 503`, which normalises to
`api_error_503`, class `transient`, which the crash-loop ladder records
without escalating (#1073). Keep the total below the stage's inactivity threshold, which the
derivation never sets below the shipped prior unless configuration does. As a
backstop for a stage the watchdog still kills while Grok is retrying, read
the `shell.turn.inference_retry` and `shell.turn.inference_failed` entries
that Grok's own process wrote to `$GROK_HOME/logs/unified.jsonl` (each entry
carries its `pid` and the HTTP status), and record the kill with that status,
so that a 5xx is still classed `transient`.

**Stage budgets (requirement 4f).** With `--include-partial-messages`, a
Grok gap is bounded by one command (the longest, when the model runs several
in parallel), as a Claude gap is. Grok's gaps should still not
feed the pool that Claude's cells draw on, and a new Grok cell should not
start from Claude's history. Key the pooled levels of
`stage_budget_table` by provider as well as actor, so that each provider
shrinks towards its own pool and then the shipped prior.

**Killing a stage.** Launch Grok under a child subreaper. This is a small
`python3` wrapper that calls `prctl(PR_SET_CHILD_SUBREAPER, 1)`, forks Grok
with the launcher's stdin, stdout and stderr, and forwards `SIGTERM`,
`SIGINT` and `SIGHUP` to it. Once Grok has exited, or two seconds after a
signal, it kills every process left below it, repeating until a pass finds
none, and exits with Grok's status. That fits inside the launcher's
five-second grace between `TERM` and `KILL`. The launcher, requirement 9c's
signal handler and the cycle's exit then need nothing provider-specific, and
the wrapper would also catch anything a Claude Code stage's commands detach.
A PID namespace or a cgroup per stage would be stronger, but the scheduler
cannot create either without capabilities it does not have.

**`doctor`.** Shape-check `XAI_API_KEY` for the `xai-` prefix (the one key
seen was 84 characters; do not fail on length), and probe it with `GET
https://api.x.ai/v1/api-key`, which answers 200 with `api_key_blocked`,
`api_key_disabled` and `team_blocked` for a usable key and 400 for an invalid
one. Do not use `grok models`, which exits 0 either way.

**Files.** On the API-key path nothing in `$GROK_HOME` needs to outlive the
container: a salvage resume (`-r`) happens within the cycle, in the same
container. Seed `$GROK_HOME/config.toml` when the container starts (as
`entrypoint.sh` seeds `claude-settings.json`) with `[storage]
cleanup_ttl_days` and `[models] max_retries = 6`. Prune `sessions/` and
`logs/unified.jsonl` in the node's own housekeeping, because the container
outlives many cycles and `prompt_history.jsonl` holds every prompt verbatim.
#2139 adds the `grok-config` volume for the subscription's `auth.json`, and
with it the first reason to persist anything.

**Project-supplied hooks and MCP servers.** `GROK_FOLDER_TRUST=0` is needed
for project instructions and the review skill (§7), and Grok's folder trust is
a single switch. It also loads the checkout's own hooks (`.grok/hooks/*.json`,
`.claude/settings.json`, `.cursor/hooks.json`), MCP servers
(`.grok/config.toml`, `.mcp.json`, `.cursor/mcp.json`) and plugins. Any stage
that checks out a pull-request head, which under D24 is untrusted content,
would run them at start-up, before any prompt framing applies and outside
any tool scoping. The narrowing therefore belongs in the adapter now, not
when a target repository first ships such a file. Two tighten-only policy
pins in the root-owned `/etc/grok/requirements.toml` (in "Image" above)
narrow it, and no other configuration layer can release them:
`allow_managed_hooks_only = true` skips every hook outside managed policy, and
an empty `allowed_mcp_servers` blocks every MCP server. By Grok's
documentation both cover a plugin's hooks and servers too, while a plugin's
skills and agents still load, as project skills do. With all four kinds
planted in a checkout and a trivial headless run under `GROK_FOLDER_TRUST=0`:

| Planted in the checkout | Without the pins | With them |
|---|---|---|
| `.grok/hooks/start.json` (`SessionStart`) | ran | did not run |
| `.claude/settings.json` hook (`SessionStart`) | ran | did not run |
| `.grok/config.toml` MCP server | started | blocked |
| `.mcp.json` MCP server | started | blocked |
| `AGENTS.md` and `.claude/skills/project-review` | loaded | loaded |

```
$ GROK_FOLDER_TRUST=0 grok inspect          # with /etc/grok/requirements.toml
  └ Project trusted: yes
  Project Instructions (1)
  └ Enforced by policy
    └ Hooks outside managed policy disabled (/etc/grok/requirements.toml)
  └ MCP servers locked down (empty/malformed allowedMcpServers or malformed deniedMcpServers)
  Skills (1)
  └ project-review  project [claude]
  MCP Servers (2)
  └ probe (stdio) [BLOCKED: locked down by policy (/etc/grok/requirements.toml)]  config
  └ probejson (stdio) [BLOCKED: locked down by policy (/etc/grok/requirements.toml)]  .mcp.json
```

The pipeline uses no hooks or MCP servers of its own, so nothing is lost.
Whether Claude Code's headless launch needs an equivalent is outside this
evaluation's scope and is with the owner.

**Egress (D24).** `api.x.ai` for the API-key path. #2139 adds `auth.x.ai`
(verified for the login) and, once confirmed, `cli-chat-proxy.grok.com`.

**Prompts.** The audit's §3 reword covers it; add that the "10-minute ceiling"
paragraph describes Claude Code's Bash tool, and that under Grok a command
outliving the model's own `block_until_ms` is backgrounded rather than killed.
With partial messages, a single command is a Grok stage's longest silence, so
the reword should ask the model to keep `block_until_ms` below the stage's
inactivity threshold.

## Gaps, and what would close them

| Gap | Why it is open | Proposed handling |
|---|---|---|
| A subscription run's envelope, chat host and pool-exhaustion message | No subscription was available | #2139, with the customer's negotiated credential |
| Real 429 and outage texts | Provoking them would spend credit or wait on an incident | The stand-in used xAI's documented credit wording; capture the first real occurrence of each and adjust the phrases and the normaliser |
| Whether `[toolset.bash] timeout_secs` bounds the model's `block_until_ms` | Asked to wait out a 200-second command, the model chose 300 seconds itself | Check before relying on the inactivity threshold; the prompts' reword should name a ceiling either way |
| Whether a project's LSP configuration can start a server under folder trust | Grok's documentation puts LSP under the same trust, and `features.lsp_tools` defaults to off; it was not tested | Plant one in the probe checkout before #2134 lands, and pin `features.lsp_tools` off if it starts |
| The session-title call's cost | It is not in `modelUsage`, and no switch stops it | Compare a stage's recorded cost with xAI's own usage for the key; accept a few thousand tokens a stage, or ask xAI for a switch |
| Prompt adherence at scale | Two runs of one small task | A first fleet trial on low-complexity items in a non-critical repository, with the Reviewer and Approver left on Claude, measured against the same items' Claude record |
| A Claude baseline on the same harness | Spared to save the owner's Claude budget | Optional; one run of each Claude tier on this harness would put the costs above in context |
| Cross-provider tier ordering (requirement 1c) | One task cannot rank models | Decide with the open question the roadmap already records, from the fleet trial |
