# Board inline interaction — spec (draft)

Answering a session's question from the review board, without switching
to it: `i` to see what it is asking, `a` to act.

## 1. Why

The board answers "which review needs me next". It then makes you leave
to do anything about it. With several sessions live, the loop is: read
the board, jump to a session, read its question, answer, come back,
re-orient. The board's whole value is avoiding that switch, and it
currently only defers it.

Two states are worth acting on from the board, and they are different
problems:

- **`waiting`** — blocked on a permission dialog. Structured: the agent
  offered a fixed set of options.
- **`asking`** — the turn ended on a question. Unstructured: free text.

## 2. What makes this possible

`agent-shell-permission-responder-function` is called with:

```
:tool-call  :title :kind :status :permission-request-id, optionally :diff
:options    each with :kind :option-id :label :option :char
:respond    a function taking an option-id
```

Return non-nil and the UI is skipped; return nil and the normal dialog
runs. **The hook is currently unset** (checked), so nothing is being
displaced.

That is the whole mechanism for `a` on a permission: record the
permission when it arrives, and call `:respond` later from elsewhere.

## 3. Design

### 3.1 Recording, not intercepting

The responder **records the pending permission against its buffer and
returns nil**, so the session still shows its own dialog exactly as
today. The board becomes a second way to answer the same question, not a
replacement for the first.

This matters for trust: a feature that silently swallowed permission
dialogs so they only appeared on a board would make every existing
session's behaviour depend on whether a board happened to be open.

### 3.2 `i` — inspect

Opens a side window showing, for the row at point:

- the pending permission's tool call: title, kind, and **the diff if one
  is present**
- otherwise the tail of the session's output — enough to see the question

Read-only. Closes with `q`. This is the cheap half and is useful alone:
"what is it asking?" is most of the question.

### 3.3 `a` — act

- **Pending permission** → present its `:options`, using each option's
  own `:char` accelerator and `:label`, then call `:respond` with the
  chosen `:option-id`.
- **`asking`** → read a line in the minibuffer and submit it to the
  session, via the existing bulk-send path.
- **Neither** → refuse, and say which state the row is actually in.

## 4. The constraint that shapes it

**`a` must not offer a decision the reader has not been shown.**

A permission dialog exists so a human sees what is about to happen. A
board key that answers one without displaying it is a consent button
with the consent removed — and it would be most dangerous on exactly the
tool calls that matter, since a destructive call and a file read look
identical as a row.

So: **`a` requires that `i` has been shown for that row**, or it shows it
itself first and asks again. Never a blind "allow" from a list of rows.

For the same reason, `a` is deliberately single-row. Every other verb on
this board acts on the marked set; this one must not. "Allow all
pending permissions" is a plausible-sounding feature and a bad one — it
is the batch case that cannot be reviewed, and the one place where the
marked-set convention would actively hurt.

## 5. Open questions

1. **Does answering from the board leave the session's own dialog
   stale?** The request is answered, but the buffer still shows an open
   prompt. Needs checking against agent-shell's rendering — a stale
   dialog that still looks actionable is its own trap.
2. **Where does the recorded permission live?** Buffer-local is
   natural, but the responder runs with the ACP client's context, not
   necessarily inside the shell buffer. Needs verifying before the
   recording is written.
3. **Does a permission survive a broker detach/reattach?** The request
   belongs to the bridge, which outlives Emacs. A permission raised
   while detached may still be pending on reattach, and the board should
   show it rather than the session appearing merely idle.
4. **Should `i` auto-follow point?** Magit-style live preview is
   pleasant and costs a render per motion. Prefer explicit `i` first;
   revisit once the window exists.
5. **`asking` has no structured options** — but the house style has
   agents end with numbered choices. Parsing those is tempting and
   fragile; free text is correct until it demonstrably annoys.

## 6. Sequencing

1. `i` — inspect only, read-only, no responder hook at all
2. The responder that records pending permissions (returns nil, changes
   nothing observable)
3. `a` for permissions, gated on §4
4. `a` for `asking`, free text

Step 1 is independently useful and carries no risk. Step 2 changes
nothing a user can see and is the piece to verify carefully (open
questions 1–3). Only step 3 can act, and only after §4 is satisfied.
