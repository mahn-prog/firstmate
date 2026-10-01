# Worker park live lab transcript (disposable lab home, private tmux socket fm-lab, real Claude Code 2.1.286 scout worker)

## Park log for the real worker (state/worker-park.log)
2026-09-30T23:53:53Z park-scout parked: done (fm-gate-refuse: gate agent lifecycle permitted only against lab home $LAB stopped park-scout harness=claude backend=tmux endpoint=primary:fm-park-scout worktree=/private/var/folders/c4/jspvwmfj2qldk2_82kcpb_r80000gn/T/fm-lab.dE2n2g/pool/.tre)
2026-10-01T00:02:51Z park-scout unpark-refused: error: refusing fleet lifecycle from inside a no-mistakes gate worktree (/Users/matteo/.no-mistakes/repos/d312268a53af.git)
2026-10-01T00:04:53Z park-scout unparked: a firstmate instruction is waiting in its inbox
2026-10-01T00:12:05Z park-scout parked: paused (fm-gate-refuse: gate agent lifecycle permitted only against lab home $LAB stopped park-scout harness=claude backend=tmux endpoint=primary:fm-park-scout worktree=/private/var/folders/c4/jspvwmfj2qldk2_82kcpb_r80000gn/T/fm-lab.dE2n2g/pool/.tre)
2026-10-01T00:14:22Z park-scout unparked: the time its declared wait named has passed
2026-10-01T00:16:05Z park-scout parked: done (fm-gate-refuse: gate agent lifecycle permitted only against lab home $LAB stopped park-scout harness=claude backend=tmux endpoint=primary:fm-park-scout worktree=/private/var/folders/c4/jspvwmfj2qldk2_82kcpb_r80000gn/T/fm-lab.dE2n2g/pool/.tre)

## Watcher comparison: same parked pane, marker removed vs present
CONTROL (marker removed): no wake in 45s (killed)
signal: $LAB/state/park-scout.status
PARKED (marker present): no wake in 45s (killed)
CONTROL-2 (marker removed): woke after 26s
stale: primary:fm-park-scout
PARKED-2 (marker present): no wake in 60s (killed)

## Typed command to a parked worker
error: park-scout's worker is parked (its agent is stopped), so a typed command would reach a shell; send ordinary text, which relaunches it, and retry the command after it is back
send rc=1

## Steer to a parked worker (fm-send)
fm-send: park-scout's worker was parked; the steer is durably recorded at $LAB/state/park-scout.inbox/001.msg and the worker is being relaunched to read it
send rc=0

## Refused unpark: logged once, no retry in backoff, watcher escalation
--- scan inside the 1800s refusal backoff:
scan rc=0
001.msg
handled
1
--- watcher with the refused unpark:
after 24s:
stale: primary:fm-park-scout (unread firstmate instruction: $LAB/state/park-scout.inbox/001.msg is unhandled and the worker's agent has exited or its endpoint is missing, so the doorbell was not typed; recover the worker)
RC=0

## Scan backstop unpark of the real worker
spawn_gen=s1790812206.58759.32034
scan rc=0
--records:
worker-park.log
spawn_gen=s1790813087.60320.20380
2026-10-01T00:04:53Z park-scout unparked: a firstmate instruction is waiting in its inbox
RC=0

## Busy worker is never parked
inbox unread:        1
--crew-state while busy:
state: working · source: pane · harness busy (claude-hook)
--records:
worker-park.log
--watch:
--log tail:
2026-10-01T00:02:51Z park-scout unpark-refused: error: refusing fleet lifecycle from inside a no-mistakes gate worktree (/Users/matteo/.no-mistakes/repos/d312268a53af.git)
2026-10-01T00:04:53Z park-scout unparked: a firstmate instruction is waiting in its inbox
--direct idle-only exit while busy:
fm-gate-refuse: gate agent lifecycle permitted only against lab home $LAB
error: task park-scout reads 'busy claude-hook', not idle; exit --idle-only refuses rather than interrupt or stop a worker that may be working. Nothing was sent
control rc=1
RC=0
inbox unread:        0
state: working · source: pane · harness busy (claude-hook)
state: working · source: pane · harness busy (claude-hook)
--records:
worker-park.log
RC=0

## Declared paused-until wait: parked, then relaunched when the time passed
state: paused · source: status-log · waiting on a lab timer until 2026-10-01T00:14Z
--marker:
schema=fm-worker-park.v1
spawn_gen=s1790813087.60320.20380
parked_at=1790813502
state=paused
until=1790813640
pr=
crew=state: paused · source: status-log · waiting on a lab timer until 2026-10-01T00:14Z
--scan before until:
park-scout.worker-park
park-scout.worker-park-checked
worker-park.log
2026-10-01T00:12:05Z park-scout parked: paused (fm-gate-refuse: gate agent lifec
RC=0
00:14:06
--records:
worker-park.log
2026-10-01T00:14:22Z park-scout unparked: the time its declared wait named has passed
RC=0

## Teardown of a parked worker
--records before teardown:
park-scout.worker-park
worker-park.log
2026-10-01T00:16:05Z park-scout parked: done (fm-gate-refuse
--teardown:
fm-gate-refuse: gate agent lifecycle permitted only against lab home $LAB
fm-captain-hold: origin park-scout has no completed captain-call inventory
REFUSED: scout task park-scout has not passed the captain-call completion gate.
Inventory its report and any visual review through bin/fm-captain-hold.sh before teardown.
teardown rc=1
--records after teardown:
park-scout.busy-state.tmp.38501
park-scout.control-relaunch
park-scout.control-relaunch.brief-prior
park-scout.control-relaunch.meta-prior
park-scout.control-relaunch.note
park-scout.git-hooks
park-scout.inbox
park-scout.meta
park-scout.status
park-scout.turn-ended
park-scout.worker-park
worker-park.log
RC=0
complete: park-scout captain-call inventory reviewed
--teardown:
teardown: force-killing leaked worktree process(es) for park-scout: 62645

worktree /private/var/folders/c4/jspvwmfj2qldk2_82kcpb_r80000gn/T/fm-lab.dE2n2g/pool/.treehouse/demo-7bd323/1/demo is not managed by treehouse
error: treehouse return failed for worktree /private/var/folders/c4/jspvwmfj2qldk2_82kcpb_r80000gn/T/fm-lab.dE2n2g/pool/.treehouse/demo-7bd323/1/demo; teardown aborted
teardown rc=1
--park records after teardown:
park-scout.worker-park
(none listed above = all retired)
$LAB/state/park-scout.meta
RC=0
--valid marker before teardown:
schema=fm-worker-park.v1
spawn_gen=s1790813655.71903.26158
parked_at=1790813755
state: done · source: status-log · README.md has 1 line; report complete, no pending inbox steers · worker parked since 2026-10-01T00:15Z (agent stopped while idle; relaunched on a steer, PR or validation activity, or its declared wait time)
--teardown:
fm-gate-refuse: gate agent lifecycle permitted only against lab home $LAB

🌳 Worktree returned to pool.
teardown park-scout complete (window primary:fm-park-scout, worktree /var/folders/c4/jspvwmfj2qldk2_82kcpb_r80000gn/T/fm-lab.dE2n2g/pool/.treehouse/demo-7bd323/1/demo)
Backlog: park-scout just finished (this home keeps no markdown backlog at /private/var/folders/c4/jspvwmfj2qldk2_82kcpb_r80000gn/T/fm-lab.dE2n2g/data/backlog.md). Update /private/var/folders/c4/jspvwmfj2qldk2_82kcpb_r80000gn/T/fm-lab.dE2n2g/data/backlog.md - move park-scout to Done, keep Done to the 10 most recent, then re-scan Queued and dispatch only work whose blockers are gone and date is due.
teardown rc=0
--park records after teardown:
park-scout.busy-state.tmp.38501
(end of list)
RC=0

## Live GitHub PR triggers (real GraphQL reads; relaunch recorded by a control recorder because probe tasks have no agent)
--- read 1 baselines (red changes conflict newest-human-activity):
pr-red     1 0 0 0
pr-bot     1 0 0 0
pr-human   1 0 0 0
pr-merged  0 0 0 0
--- read 2, nothing changed:
pr-bot.worker-park
pr-human.worker-park
pr-merged.worker-park
pr-red.worker-park
(no control calls above = all stayed parked)
RC=0
--- pr-human read-1 baseline: 0 0 0 2026-09-23T21:32:26Z (pr=https://github.com/cli/cli/pull/14259)
--- pr-human read-2 (no change), control calls:        0
--- now age the baselines as if the earlier read predates the change:
pr-red     baseline 0 0 0 0
pr-bot     baseline 1 0 0 2026-09-29T00:00:00Z
pr-human   baseline 0 0 0 2020-01-01T00:00:00Z
pr-merged  baseline 0 0 0 0
--- control calls (relaunches):
pr-human relaunch --note Firstmate parked this worker (stopped its agent while the task waited in state 'done') at 1970-01-01T00:00Z and relaunched it because: its PR https://github.com/cli/cli/pull/1
pr-red relaunch --note Firstmate parked this worker (stopped its agent while the task waited in state 'done') at 1970-01-01T00:00Z and relaunched it because: its PR https://github.com/mahn-prog/firstm
--- park log:
2026-10-01T00:21:05Z pr-human unparked: its PR https://github.com/cli/cli/pull/14259 has new reviews or comments
2026-10-01T00:21:09Z pr-red unparked: its PR https://github.com/mahn-prog/firstmate/pull/5 has a failed check
--- still parked:
pr-bot.worker-park
pr-merged.worker-park
RC=0
