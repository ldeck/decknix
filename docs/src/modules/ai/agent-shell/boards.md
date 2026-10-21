# Coordination Boards

A board coordinates one purpose (a hackathon, a pilot, a migration). It shows
the goal and its epics, stories, tasks and subtasks from an issue backend,
and under each item the live agent sessions working on it. Sessions that need
you are listed first.

Each board picks its own repositories, tags, workspace and Slack channel, so
you can run several at once. GitHub issues are the first backend; Jira and
taskwarrior are planned behind the same interface **(Planned)**.

## Quickstart: a hackathon board

1. Create a repository for the hackathon (or pick an existing one).
2. `M-x decknix-board-new` (or `C-c s H` before any board exists) and answer:
   - **Board name**: `hack-2026` (lower case; names the file and buffer)
   - **Title** and **Goal**: one line each
   - **GitHub repo**: `owner/name`, the issue home where items are created
     (recently pushed repos are offered)
   - **Repos in scope**: comma-separated, globs allowed (`owner/hack-*`),
     `/regexp/` for a regexp; Enter keeps just the issue home
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
 :repos ("owner/hack-*")           ; optional: repositories in scope
 :match either                     ; tags | repos | either | both
 :exclude-tags ("parked")          ; optional: never on the board
 :backend github
 :github (:repo "owner/name"
          :root 1                  ; the goal issue
          :label-prefix "type:"    ; type:epic, type:story, ...
          :label nil))             ; only issues with this label, if set
```

Fields:

- `:name`, `:title`, `:goal`: the file name, the heading and one line of intent.
- `:tags-all`, `:tags-any`, `:workspace`: the tag rule (below).
- `:repos`: the repository scope (below). Without it, the scope is the issue
  home, `:github :repo`.
- `:match`: how tags and repositories combine; `either` by default.
- `:exclude-tags`: a session carrying any of these is never on the board.
- `:slack-channel`: the channel `s` drafts for.
- `:github`: `:repo` is the issue home, where `c` creates items; `:root` the
  goal issue; `:label-prefix` the type labels; `:label` restricts every
  repository's items to issues carrying it.

Example definition: [a hackathon](./boards/hack-2026.eld).

## Repositories

`:repos` confines a board to a set of repositories. Each entry is one of:

| Entry | Matches |
|-------|---------|
| `"UpsideRealty/upside"` | exactly that repository |
| `"UpsideRealty/hack-*"` | a glob over `owner/name` (`*`, `?`, `[...]`) |
| `"*/followupboss-*"` | a glob with any owner (expanded within the board's named owners) |
| `(:regexp "nc-helix/.*-cli")` | a regexp, anchored to the whole `owner/name` |

Matching ignores case. Items are read from every repository in scope, the
issue home first, then exact entries, then pattern matches; at most
`decknix-board-github-max-repos` (20). Patterns are expanded with
`gh repo list OWNER` for each owner the board names (the issue home's and
the exact or glob entries'), cached for ten minutes. Each repository is
one issues query, the same one a single-repository board runs, rather than
one `gh search issues` across them: search has no repository wildcard
either, caps at 1000 results and limits the query's length, and the
per-repository query already carries sub-issue links and the PRs that close
each issue. A repository that fails to fetch is reported as **Partly
fetched** above the plan; the rest still shows.

Sub-issues may cross repositories: an issue in `hack-api` can be a child of
an epic in the issue home, and nests under it.

## Which sessions are on a board

Two rules, combined by `:match`:

- **Tags**: the session has every `:tags-all` tag, at least one `:tags-any`
  tag (if any are listed) and sits under `:workspace` (if set). A board with
  none of these matches no session by tags.
- **Repositories**: the session works in a repository in scope. That comes
  from cached facts only: the PRs it reviews or created, the worktrees its
  tool calls touched, and its workspace resolved through the hub's clone map
  and worktree registry (or, failing those, a `<repo>-worktrees/` directory
  name). A tag naming a repository in scope counts too (`followupboss` names
  `followupboss-integration`; tags shorter than four characters never do).

| `:match` | On the board when |
|----------|-------------------|
| `either` (default) | the tag rule, or a repository in `:repos` |
| `tags` | the tag rule only |
| `repos` | a repository in scope only |
| `both` | a repository in scope, and the tag rule if the board sets any tags |

Under `either`, a board without `:repos` uses the tag rule alone, so its
issue home does not quietly claim every session working there. An item tag
(below) always puts a session on the board, and `:exclude-tags` always takes
it off.

Pick `either` for a board that owns its repositories (a hackathon's
`hack-*`), and `both` for one that shares them (a pilot working in the
monolith): `either` there would claim every monolith session.

## Item tags

A session works on an item when it is tagged `REPO#N`, where `REPO` is the
repository name without the owner: `hack-boards#12` for issue 12 of
`owner/hack-boards`. That tag alone puts the session on the board. Inside
the board (a session that already has the board's tags) a bare `#12` works
too, for an issue-home item. An item from another repository in scope is
tagged with that repository's name (`hack-api#4`). `N` applies the right form
for you; add one by hand with `C-c s t a`.
Sessions on the board that match no item are listed under **Sessions on no
item**.

## Hierarchy

Items nest by GitHub sub-issues and are typed by label (`type:epic`) or, when
there is no type label, by GitHub's issue type. A child created with `c` is
labelled and added as a sub-issue of the item at point. When the server does
not support sub-issues, the board groups items by type instead.

## Open PRs

The board lists the open PRs in its scope from the hub's cached feeds (reviews
asked of you, and your own PRs), so it costs no network on render. A PR links
to an item when GitHub says it closes it, when its title or branch carries the
item's tag (`hack-api#4`), or, in the item's own repository, when its title
says `#4` or its branch starts `4-`, `issue-4-` or `gh-4-`. Linked PRs also
show on the item's row. PR bodies are not in the cache, so a reference only in
the body is not seen.

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

Rendering reads only caches. Items are fetched in `gh` subprocesses (one per
repository in scope, in parallel) every minute while the board is visible
(and on `g`); sessions repaint every ten
seconds from the snapshot the sidebar keeps. A hidden board, or one you are
typing over, does nothing.
