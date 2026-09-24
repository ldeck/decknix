# Agent prompt visibility — spec (draft)

The ` Me ` badge and `❯` prompt are reported missing on resumed sessions.
Three times now the buffer has been correct and the *window* wrong. This
records the three mechanisms so the fourth report is not misdiagnosed a
fourth time.

## 1. What is NOT wrong

Measured after the 2026-09-24 switch, across 13 live sessions:

```
12 of 13   live-prompt = t, Me overlay at point-max
 1 of 13   no prompt — mid-turn, which is correct
```

So: the prompt exists, the overlay exists, chat-mode has labelled it, and
`decknix--agent-resume-ensure-live-prompt` is doing its job. Reading
overlay state to diagnose this has twice produced "everything is fine"
while the user could plainly see it was not. **Overlay state is not the
evidence. Window state is.**

## 2. The three mechanisms, in the order they were found

**A. The prompt was genuinely buried.** `session/load` replays the
transcript below the early prompt. Fixed by
`decknix--agent-resume-ensure-live-prompt`, originally gated to the
`load` path only, later extended to `resume` too — because on `resume`
*we* render via `decknix--agent-session-prepopulate`, which buries the
prompt exactly the same way.

**B. The window was not scrolled to it.** `decknix--agent-resume-focus-prompt`
set point and stopped, reasoning that "redisplay moves a window to follow
its point". True for the selected window inside the command loop; false
for a resume landing from a timer into an unselected window. Measured on
727cd28d: `window-end` 116790 against `point-max` 116828. Fixed in
649f810 by recentering each window showing the buffer.

**C. The window did not exist yet.** THE OPEN ONE. Measured 2026-09-24:

```
frames                     3
tabs                       2
agent buffers displayed    2  of 13
```

Eleven sessions had no live window at resume time — they live in saved
TAB window-configurations. A tab stores each window's `window-start`;
restoring the tab restores a scroll position captured before the prompt
was emitted. So B's fix has nothing to act on, and the stale
`window-start` is reinstated underneath the correct buffer.

This is why it looks arbitrary: the tab you were in got scrolled, the
others did not.

## 3. Why the resume-time seam cannot fix C

Every existing repair runs during resume. C is not about resume — it is
about DISPLAY, which happens later and repeatedly: selecting a tab,
splitting a window, `C-c A w` building a workspace layout, restoring a
layout group. Each of those shows an agent buffer in a window that did
not exist when the prompt was written.

The fix has to hang off display, not off resume.

## 4. Design

A `window-configuration-change-hook` (and/or `tab-bar-tab-post-select-functions`)
that, for each window showing an agent-shell buffer:

- does nothing unless the buffer's point is already at a LIVE prompt
  (`agent-shell--live-input-prompt-p`), so a user scrolled back to read
  history is never yanked to the bottom;
- does nothing if `window-end` already reaches `point-max`, so the common
  case costs one comparison;
- otherwise recenters to the bottom.

Both guards matter. Scrolling unconditionally on every configuration
change would fight anyone reading scrollback, and
`window-configuration-change-hook` fires often enough that an unguarded
implementation is a performance problem in its own right — see the
heartbeat work, where 53ms redisplays at 3/sec were the cause of macOS
beachballs.

## 5. Open questions

1. **Which hook?** `window-configuration-change-hook` is the broad net
   and fires a lot. `tab-bar-tab-post-select-functions` covers the
   measured case precisely but misses splits and layout-group restores.
   Starting broad with tight guards is probably right, but it wants
   measuring against the hitch profiler rather than assuming.
2. **Should a layout group restore pin the prompt?**
   `decknix-layout-group-switch` calls `window-state-put`, which restores
   saved `window-start` values — the same staleness as a tab. Arguably the
   same fix covers it; arguably a layout is a deliberate snapshot and
   should be restored verbatim.
3. **Does `point` survive a tab round-trip?** If a tab restores point as
   well as `window-start`, the "point is at a live prompt" guard may be
   false on restore, and the fix would no-op. Needs checking before
   building — it decides whether the guard is on point or on the buffer's
   own `point-max`.

## 6. Sequencing

1. Confirm open question 3 — what a tab restore does to point
2. Pure predicate: given (point, prompt, window-end, point-max), should
   this window be scrolled?
3. Hook it up with the guards from §4
4. Re-measure with the hitch profiler; the heartbeat work showed how
   cheap a per-redisplay cost has to be

Step 2 is testable without a live session, which matters: every previous
attempt here was verified by reading state that turned out to be the
wrong state.
