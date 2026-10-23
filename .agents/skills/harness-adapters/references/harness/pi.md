# Pi and Pi-signed

The combined contract is genuine: Pi and the signed wrapper expose the same verified CLI and TUI behavior.
Verified on 2026-10-22 with Pi 1.1.0 and the pi-claude-bridge 0.9.3 extension unless a fact gives another version.
Pi-signed was not installed for that run, so its own identity facts below keep their older versions.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | The Firstmate-owned extension's `agent_start` marks busy and `agent_settled`, confirmed by `ctx.isIdle()`, marks idle; this covers retries, compaction, tool loops, and queued continuations. |
| Exit command | `/quit`. |
| Resume | `--session <path-or-id>` resumes that exact session, and creates it at that path when the file is gone. `../../../bin/fm-spawn.sh` passes it on a relaunch so a Herdr pane's already-bound status authority keeps applying (`../../../bin/fm-control-lib.sh`'s `fm_control_relaunch_resume_flag`; `../../../docs/herdr-backend.md` "Agent status authority and relaunch"). There is still no `resume` control verb. |
| Interrupt | Single Escape. |
| Skill invocation | No separate verified form beyond normal command behavior; use natural language when the exact command is uncertain. |
| Model flag | `--model <model>`; under a home's worker account pin the model must be `<provider>/<id>` and Firstmate also passes `--provider <provider>` (`../../../docs/configuration.md` "Worker account pin"). |
| Claude models | Name `claude-bridge/<id>`, for example `claude-bridge/claude-sonnet-5-5`; see "Claude through the bridge" below. |
| Effort flag | `--thinking <low\|medium\|high\|xhigh\|max>`; Pi 1.1.0 also accepts `off` and `minimal`, which no Firstmate effort level maps to. |
| Model discovery | Run the selected executable as `<executable> --list-models [search]`; Pi's installed `docs/models.md` owns how built-in, extension-registered, and custom provider/model entries reach that list. |

Native Codex sessions may request `ultra` through the native extension flag described by `../../../bin/fm-spawn.sh`; it is separate from Pi's thinking levels.
Pi has no permission system, so workers are always autonomous.
Pi 1.1.0 defaults to the fullscreen TUI (`pi --help`: `--tui-mode <mode>  TUI mode: fullscreen (default) or regular`).
Fullscreen can bury steering messages by rewriting scrollback, so `../../../bin/fm-spawn.sh` passes `--tui-mode regular` whenever the selected executable's `--help` advertises the flag; a verified 1.1.0 worker pane renders the regular inline TUI.
`../../../bin/fm-spawn.sh --help` owns the executable-pinning and version-safe launch mechanics.

Pi-signed is the signed wrapper identity, last verified on version 0.84.4.
Firstmate records `pi-signed` without normalization and refuses rather than falling back to `pi` when that wrapper is unavailable.
Where the signed launcher is installed, the process tree has an exact `pi-signed` wrapper parent with the Pi application as its child, tmux reports the foreground command as the exact `pi-launcher` name for either selected executable, and the plain `pi` command execs that launcher too.
A plain Pi 1.1.0 install without the signed launcher runs `pi` as a Node script: tmux reports `node` while the foreground process `comm` is `pi`, and the shared liveness classifier reads that pane `alive`.
While a claude-bridge turn runs, the bridge's Claude Code agent binary is a second foreground process beside `pi`.
The router's Detection section owns how launch markers and ancestry select between the identities.

Keep the instructions as one positional argument.
Multiple positional arguments become separate queued messages; the spawn template already preserves the one-argument shape.

A project trust dialog (`Trust project folder?`) appears only when the start directory or an ancestor carries a trust-requiring project resource, such as `.pi/` settings or extensions or a project `.agents/skills` directory, and no decision covers it.
Pi applies the first match of `--approve`/`--no-approve`, a `project_trust` extension, the closest saved decision for the directory or any ancestor in the agent directory's `trust.json` (`~/.pi/agent/trust.json`, or the pinned root's under a worker account pin), then the `defaultProjectTrust` setting, which defaults to asking.
A saved decision for a pool root therefore covers every slot beneath it, and such a spawn shows no dialog.
The dialog lists `Trust` first, then `Trust parent folder (<parent>)`, `Trust (this session only)`, `Do not trust`, and `Do not trust (this session only)`.
Accept it with Enter, which selects `Trust` and saves that exact directory, and verify the instructions begin processing.
Firstmate never passes `--approve`.

Pi 1.1.0 also adds `--session-id`, `--fork`, `--offline`, `--no-mcp`, and the `pi auth` subcommand; none is part of a Firstmate launch, and `../../../bin/fm-worker-account-lib.sh` owns the use of `pi auth check`.

## Claude through the bridge

The pi-claude-bridge extension registers the `claude-bridge` provider, which serves Claude models through Claude Code's own agent runtime and login.
Pi's built-in `anthropic` provider lists the same Claude ids and bills them as direct Anthropic extra usage.
Pi resolves a `<provider>/<id>` model under that exact provider, but resolves a bare id or a fuzzy alias such as `opus` under its sole authenticated provider for that id or its default provider, so on a host signed in to Anthropic a bare `claude-sonnet-5-5` runs direct Anthropic, never the bridge.
Dispatch must therefore name `claude-bridge/<id>`, and `../../../bin/fm-spawn.sh` refuses a canonical Pi or Pi-signed launch whose `--model` is a bare Claude-family id.
`anthropic/<id>` remains a deliberate direct choice.
A launch with no `--model` uses Pi's own `defaultProvider` and `defaultModel` settings, so it is a bridge launch only when those settings name the bridge.

## Worker turn-end extension

`../../../bin/fm-spawn.sh` keeps the worker turn-end extension in `state/`, outside the worktree, because project-local extension files worsen the trust gate and pollute the project.
The extension listens for Pi's `turn_end` event, not `agent_end`, so supervision is notified after each completed turn rather than only when the whole run exits.
Native-harness progress uses the separate generation-bound marker owned by `../../../bin/fm-busy-event.sh`; it never fabricates Pi turn completion.
Pi sets `PI_CODING_AGENT=true` for its children as its harness-detection marker.

## Primary integration

The primary turn-end behavior was verified on 2026-07-09 with Pi 0.80.5.
`.pi/extensions/fm-primary-turnend-guard.ts` listens for logical-run `agent_settled`, not per-tool-loop `turn_end`, and uses `pi.sendUserMessage(..., { deliverAs: "followUp" })` to force one guarded follow-up when `../../../bin/fm-turnend-guard.sh` returns 2.
Without `deliverAs: "followUp"`, Pi rejects the send while the agent is still processing.
On native Windows, the extension runs its session-start, both PreToolUse, turn-end, and operational-input Bash helpers through `bash`; macOS and Linux invoke those helpers directly.

The primary watcher protocol also requires `.pi/extensions/fm-primary-pi-watch.ts`.
The Pi engine auto-discovers both tracked project-local extensions once the project is trusted.
The model arms through the `fm_watch_arm_pi` tool, never through a foreground shell arm.
Native-harness adapters can discover the same guarded FirstMate tools and operational message allowlist through the public Pi event-bus contract in `.pi/extensions/lib/fm-native-contract.ts`; no Pi built-in tools cross that contract.
The tool result and clean-exit fallback are owned by `../../../docs/supervision-protocols/pi.md`.
`../../../bin/fm-session-start.sh` reports when the live Pi-family session has not loaded both extensions and points at the selected executable after project trust as the fix, with `-e` as a trust-free fallback.

When a secondmate is launched on Pi or Pi-signed, `../../../bin/fm-spawn.sh --secondmate` launches the selected executable with both `-e .pi/extensions/fm-primary-turnend-guard.ts` and `-e .pi/extensions/fm-primary-pi-watch.ts`.
Both files already exist in the secondmate home's git worktree.
The PreToolUse-equivalent watcher-arm seatbelt returns `{block: true}` from the `tool_call` event.
