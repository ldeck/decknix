# Coordination Boards

A board coordinates one purpose (a hackathon, a pilot, a migration). It shows
the goal and its epics, stories, tasks and subtasks from an issue backend,
and under each item the live agent sessions working on it. Sessions that need
you are listed first.

Each board picks its own repository, tags, workspace and Slack channel, so you
can run several at once. GitHub issues are the first backend; Jira and
taskwarrior are planned behind the same interface **(Planned)**.

## Quickstart: a hackathon board

1. Create a repository for the hackathon (or pick an existing one).
2. `M-x decknix-board-new` (or `C-c s H` before any board exists) and answer:
   - **Board name**: `hack-2026` (lower case; names the file and buffer)
   - **Title** and **Goal**: one line each
   - **GitHub repo**: `owner/name` (recently pushed repos are offered)
   - **Session tags**: tags every board session carries, e.g. `hackathon`
   - **Workspace**: optionally, only sessions under this directory
   - **Slack channel ID**: optional, e.g. `C0123ABCD` (channel details, bottom)
   - **Goal issue**: `create one now` makes a `type:goal` issue (asks first)
3. On the board, put point on the goal and press `c` to add epics; on an epic,
   `c` adds stories, and so on down to subtasks. Each create asks before
   writing to GitHub.
4. On any item, `N` starts an agent session tagged for it, in the board's
   workspace, with a brief: the item, its parent chain, the goal, the Slack
   channel and where the board snapshot lives.
5. `C-c s H` reopens the board any time.

## Definitions

Boards are plain data in `~/.config/decknix/boards/NAME.eld` (`e` on a board
opens it; `g` re-reads it). No secrets belong here.

```elisp
(:name "hack-2026"
 :title "Hackathon 2026"
 :goal "Ship coordination boards"
 :workspace "~/Code/hack"          ; optional
 :tags-all ("hackathon")           ; sessions carry every one of these
 :tags-any nil                     ; and at least one of these, if set
 :slack-channel "C0123ABCD"        ; optional
 :backend github
 :github (:repo "owner/name"
          :root 1                  ; the goal issue
          :label-prefix "type:"    ; type:epic, type:story, ...
          :label nil))             ; only issues with this label, if set
```

A session is on the board when it has every `:tags-all` tag, at least one
`:tags-any` tag (if any are listed) and sits under `:workspace` (if set). A
board with none of these claims sessions only by item tag.

## Item tags

A session works on an item when it is tagged `REPO#N`, where `REPO` is the
repository name without the owner: `hack-boards#12` for issue 12 of
`owner/hack-boards`. That tag alone puts the session on the board. Inside
the board (a session that already has the board's tags) a bare `#12` works
too. `N` applies the full form for you; add one by hand with `C-c s t a`.
Sessions on the board that match no item are listed under **Sessions on no
item**.

## Hierarchy

Items nest by GitHub sub-issues and are typed by label (`type:epic`) or, when
there is no type label, by GitHub's issue type. A child created with `c` is
labelled and added as a sub-issue of the item at point. When the server does
not support sub-issues, the board groups items by type instead.

## Keys

| Key | Action |
|-----|--------|
| `n` / `p` | Next / previous item or session |
| `TAB` | Fold or unfold the item at point |
| `RET` | Go to the session on this row, or the item's only session; otherwise open the item. `C-u RET` always opens it |
| `o` | Open the item in the browser |
| `N` | New agent session for the item, tagged and briefed (`C-u N` picks the provider) |
| `j` | Go to the item's session (asks when several) |
| `b` | Send one message to the item's sessions; `C-u b` to every board session |
| `c` | Create a child item (type, title, body), after confirming |
| `s` | Draft a Slack update for the item or board, then `C-c C-c` to send (asks first) |
| `g` | Re-read the definition and fetch now |
| `e` | Edit the definition |
| `?` | Every key |

## For agents: the snapshot

Every fetch writes `~/.local/state/decknix/boards/NAME.md`: the goal, the
item tree with open/done checkboxes, assignees and which sessions are on each
item. Session briefs point at it, so an agent can see the whole plan.

## Slack

`s` drafts an update (counts, sessions waiting on people, items in progress)
in a buffer you edit. `C-c C-c` asks before posting. Posting uses
`decknix-board-slack-post-command` when set, else a `slack-post-message.py`
found on `exec-path` or in a workspace tools directory. Without one, the
board copies the update to the kill ring and opens the channel in Slack for
you to paste.

## Refresh and cost

Rendering reads only caches. Items are fetched in a `gh` subprocess every
minute while the board is visible (and on `g`); sessions repaint every ten
seconds from the snapshot the sidebar keeps. A hidden board, or one you are
typing over, does nothing.
