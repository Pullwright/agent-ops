## Integration

- **End-of-cycle hook** — `agent-cycle.sh`'s cleanup runs the Publisher as
  `timeout -k 10 120 … >/dev/null 2>&1 || true`: failure-isolated and time-bounded,
  so it can never change the cycle's outcome, exit code, or timing. It is the
  only change to `agent-cycle.sh`. (Never edit `agent-cycle.sh` while a cycle
  is running — editing a running bash script shifts byte offsets and corrupts
  the live process. Use `agent-cycle.sh --disable '<why>'` before editing and
  `--enable` after: that is what the switch of requirement 2.3 is for, and it
  also stops the *next* cycle tick from starting mid-edit, which waiting for
  the lock to clear does not. `--status` reports both the switch and whether a
  cycle is still running, because disabling stops the next cycle, not the one
  already in flight.)

  The Publisher's working set is its scratch directory (`lib/scratch.sh`,
  `docs/spec/implementation/requirements` requirement 2.5):
  `agent-ops.publish-dashboard.<pid>.XXXXXX` under `$TMPDIR`, which `TMPDIR`
  points inside for the publish's lifetime, so every file the Publisher or a
  library it calls spools — the union files of `lib/item-lifecycle.sh` and
  `lib/node-time-state.sh`, `lib/gh-shim.sh`'s per-call directories,
  `lib/toggle.sh`'s memos, `sort`'s spill files — lies inside it. The `EXIT`
  trap, armed before the directory exists, removes it — renamed to a
  tombstone first, with the signals ignored, so that a command forked in the
  instant a `timeout`'s first signal lands, which never receives its second,
  group-wide one, has nowhere to recreate an entry — together with the
  three files a publish stages outside it for an atomic rename — the
  `.data.XXXXXX.js` and `.stamp.XXXXXX.js` beside `data.js` and `stamp.js`,
  and `.dashboard-payload.tmp` — and a publish that cannot make its
  directory exits 1 saying so. The `timeout` above ends an overrunning
  publish with `TERM`, and with `KILL` ten seconds later should its exit
  take longer than that; bash handles the `TERM` by running the `EXIT` trap,
  and `TERM` is not trapped, because a trapped signal is handled only once
  the foreground command returns, which would hold the hook past its bound
  for as long as a `timeout 15` GitHub call takes. A fast tick whose
  assemble fails runs its full rebuild as a child process, not in place of
  itself: the child inherits the launcher's lock through the open
  descriptor and makes its working set inside this one, and the parent's
  trap removes both when the child returns. What a `KILL` leaves is removed
  at the start of the next launcher window and the next cycle (requirement
  2.5). An empty payload is refused by name as well as by `jq -e .`, which
  exits 0 on empty input under jq 1.6. `test/publish-dashboard.test.sh`
  passes: nothing but the working set, and the tombstone its release
  renames it to, ever appears at the top of `$TMPDIR` during a publish, in a
  census read every few milliseconds for the publish's whole run; a publish started under `timeout` and sent `TERM`
  after a file exists inside its working set ends early and — once the same
  sweep that reclaims what a `KILL` leaves runs, closing a signal-delivery
  window the trap's own arming cannot — leaves nothing under `$TMPDIR`; and a
  fast tick whose payload cache is not JSON rebuilds in full, exits 0 with a
  non-empty payload the page can parse, and leaves nothing under `$TMPDIR`
  either.
- **Heartbeat** — an optional `*/5 * * * *` crontab entry keeps in-flight
  state, the lock, and GitHub current between cycles. cron can't fire
  more than once a minute, so the entry runs `publish-dashboard-launcher.sh`
  rather than the Publisher directly: the launcher self-loops for ~295s
  (leaving a ~5s gap so consecutive cron runs don't overlap), republishing
  local state — lock, running cycle, cost, log — on every tick. A tick lands
  on a 5-second boundary, but the loop **measures what each tick costs and
  idles `LAUNCHER_DUTY_DIVISOR` (9) times that before the next one starts**, so
  the Publisher can take at most about a tenth of the window whatever a publish
  grows to cost. Pacing off a measurement rather than a constant is what keeps
  that true as the state grows: the loop previously slept to the next 5-second
  boundary and no further, on an assumption — stated in its own header and
  budgeted at five seconds — that nothing enforced and nothing measured. When a
  publish reached 20–22s the window ran rebuilds back to back, ~11 per window
  and roughly 78% of a core, producing a byte-identical page each time on an
  idle node, and the only way to find that was `top` on the host (#799). A
  cheap tick still lands on the next boundary, so an idle node's page is no
  less live than it was; an expensive one now pays for itself, and logs its
  cost and its backoff so the next such regression shows up in `dashboard.log`
  rather than only in `top`. A full GitHub-hitting publish runs only when the last fetch has
  aged past `LAUNCHER_GITHUB_MAX_AGE` (285s, so that the gap between fetches
  including the fetch's own ~20s comes to about five minutes); the cheaper
  `--no-github --fast` publish runs in between and carries the last fetch
  forward, so the page stays near-live without hammering the GitHub API. That
  GitHub tick is also the **full** build (see **The tiered publish**): the
  history roll-ups a fast tick carries forward are therefore never more than one
  fetch old, and the launcher needs no second cadence to decide when to rebuild
  them. The gate is the
  **age of `<state_dir>/.dashboard-github.json`**, which the Publisher stamps
  on every fetch it attempts — succeeded or failed — and which the launcher
  stamps itself if a publish dies before getting that far. Age, rather than a
  position in the window, is what makes the cadence self-healing: a missed
  cron window, a publish that overran its tick budget and a GitHub outage all
  reduce to "the next tick is the one that fetches", and none of them can turn
  into a retry storm. (It was a wall-clock test, `EPOCHSECONDS % 300 < 5`,
  until it was found never to fire: ticks always land on a multiple of 5, so
  the test meant `% 300 == 0`, and a window opened by a `*/5` entry starts on
  a 300s boundary and runs from offset +5 to +285. The GitHub panels refreshed
  only when cron's sub-second jitter happened to put the first tick on the
  boundary — half-hourly or worse, and invisibly, because a carried-forward
  fetch renders exactly like a fresh one. Hence both the age gate and the
  freshness reporting under **The Site**.) `flock` guards against a slow
  publish stacking up under the next tick. No tick starts inside the window's
  final ten seconds **or within the last measured cost of a tick of its own
  kind** — GitHub or local, whichever this tick is about to be, read from
  `<state_dir>/.dashboard-tick-cost` — so an oversized publish is not started
  just before the window closes and handed to the next cron fire as a lock
  collision. The reserve is the larger of the two, not their sum: ten seconds
  is its floor, so a tick costing less than that reserves exactly the tail it
  always did. It is tracked **per kind and persisted across windows** because
  the two kinds differ by more than a factor of two (42–47s against 17–20s on
  both laptop nodes) and because cron starts a fresh launcher every window,
  while the reserve is needed on a window's *first* tick — an in-process
  measurement would reset exactly when it is wanted. Reserving against
  whichever tick merely ran last was correct only while every tick was
  expensive: once the no-op path began firing the previous tick was almost
  always a sub-second skip, the reserve collapsed to the bare ten seconds, and
  a 45s GitHub tick starting in the last half-minute overran the window.
  supercronic runs no overlapping instance of a job, so it then dropped the
  entire next window — `not starting: job is still running` — and the page went
  ten minutes without an update (#807). A window always runs its **first**
  tick regardless, so a publish that outgrew its window degrades to one
  overrun per window rather than to a page that silently stops updating; a
  deferred tick logs `deferred: a <kind> tick needs Ns, window has Ns left`,
  because a fetch that does not happen is otherwise indistinguishable from a
  quiet system. `.dashboard-tick-cost` is launcher bookkeeping: it is excluded
  from the fingerprint under **The no-op tick** and from replication, so
  writing it cannot invalidate the skip it exists beside.
  The backoff computed from a tick's own cost (`last_cost_ms * duty_divisor`)
  is itself **clamped to what the window has left** (`endat - tick_margin`,
  floored at zero) before it is either slept against or logged (agent-ops#1305):
  a node livelocked by a parent memory cgroup's throttling (see `scripts/
  cgroup-parent-setup.sh` and `docs/spec/implementation/requirements` requirement
  2n-i) measured a 4,511,835 ms tick, which the unclamped arithmetic turned into
  a `pacing:` line reading "next tick in 40606s" (11.3 hours) — harmless there
  only because the loop's own end-of-window check breaks out before sleeping
  that long, and a coincidence of that incident's numbers rather than a
  property the backoff itself ever had to respect. The `pacing:` line always
  reports the clamped figure, never the raw product, so the log cannot claim a
  backoff longer than the window it is inside of.
  A healthy window ends `exit 0` — its exit status is explicit, not
  whatever the final tick's lock bookkeeping happened to return
  (`LAUNCHER_WINDOW` shortens the window, `LAUNCHER_PUBLISH_CMD` swaps in a
  stub Publisher, and `LAUNCHER_DUTY_DIVISOR` sets the pacing ratio, for the
  test suite only — cron runs every default). Each window also opens by
  repairing `dashboard.log` and, alongside it, `state_dir`'s three other
  never-rotated logs — `log.jsonl`, `review-log.jsonl` and
  `revert-rate.jsonl` (agent-ops#794, `fleet_repair_log`, `lib/fleet.sh`): a
  container killed mid-append leaves the file's size recorded with the last
  writes' data blocks missing, and they read back as NULs. The lost lines are
  lost, but one NUL makes the whole file binary, and grep then stops printing
  matches for every intact line around it — GNU grep says "binary file
  matches", ugrep says nothing at all and exits 1. The repair clears them and
  appends a record of what went, so the loss stays on the record
  instead of being closed over silently — a plain-text line for
  `dashboard.log`, and, since a plain-text line appended to a JSONL file is
  exactly what every `fromjson? // empty` reader silently drops, a JSON line
  (`{"ts", "node", "event": "log-repaired", "dropped_nul_bytes",
  "dropped_lines", "recovered_records"}`) for the other three. For a JSONL
  target the bytes alone are not enough: the run takes the newline
  separators inside it too, so deleting just the NULs splices the head of one
  record onto the whole of a later one and `jq -s` still refuses the file
  over the join. So the run becomes the line break it destroyed, and every
  line of the result goes through the one recovery `fleet_logs` also uses
  (`FLEET_RECOVER_JQ`, `lib/fleet.sh`): a line that parses whole as an object
  is kept as it is; any other is split at each `{"ts":"`, and, walking from
  the left, the shortest run of pieces that parses as an object is kept each
  time — so a truncated stump goes, the intact record the run ran into is
  recovered, and a record that lost only its newline is kept together with
  the one it ran into. `dropped_lines` counts the damaged lines taken out,
  `recovered_records` the records put back in their place, and `jq -s`
  reads the whole file afterwards. The same splice arises with no NUL byte at
  all, from a write a full disk cut short: the head of a record without its
  newline, completed by the next append's whole record. A JSONL target with
  no NUL byte is checked for that shape too, more cheaply: one `awk` pass
  under the C locale picks the candidate lines (one that does not open an
  object, does not end in `}`, or holds `{"ts":"` anywhere past its start),
  and only those reach the recovery, with `dropped_nul_bytes: 0` on the
  record. A line that parses whole is never touched. On either path an
  unterminated last line is left out of the repair, since it may be an
  append still being written: it is copied back byte for byte, still without
  a newline, after the `log-repaired` record, so the next append completes
  it, and nothing else in the file waits on it. Every step of the repair is
  guarded, so a step that fails leaves the file as it was and never ends a
  caller running under `set -e`. Either repair replaces the file by rename
  only if its size is unchanged since the repair read it: a writer's append
  that landed meanwhile would be on the file the rename discards, so the
  window gives up and the next one retries. `log.jsonl` is skipped while the
  implementation cycle holds `lock.json` — by `acquire_lock`'s own test, a
  pid `kill -0` finds in a lock that names this container or none — because
  a running cycle copies its own new events into its union snapshot by line
  number (`tail -n "+$(( log_lines_before + 1 ))"`), and a repair that took K
  lines out and added one would move every later line up by K-1; nothing
  reads the other files by offset, so they are repaired in every window. The
  cycles' and the review's own union snapshots need no repair: `fleet_logs`
  takes a peer's NUL-holed or spliced line apart before its sort
  (implementation spec requirement 2.5), so a peer that has not repaired its
  own log yet, or history replicated before it did, costs a reader nothing
  more than the stumps it held.

