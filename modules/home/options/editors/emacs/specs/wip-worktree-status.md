# WIP worktree status — spec (draft)

`wip` should mean "branch not yet promoted to a PR". Today it also means
"PR merged", which is how a merged worktree loses its number and its
status.

## 1. Observed

A worktree whose PR has merged renders as a dim `wip` row with no `#N`
and no actionable URL. Reported 2026-09-23: *"worktrees/branches that
have been merged show as 'wip' and their pr number is lost"*.

## 2. Why

`decknix--hub-wip-placeholder-rows` returns worktrees "lacking a matching
open PR in `decknix--hub-wip`". Two very different things satisfy that:

- a branch that has never had a PR, and
- a branch whose PR merged or closed and therefore left the open feed.

`decknix--hub-render-wip-placeholder` then hardcodes the state-word,
reasoning:

> the `#N` + CI signal zone collapses to the dim state-word `wip` since
> none of those signals exist for a branch-without-a-PR

Sound for the first case, wrong for the second. The renderer also
deliberately attaches no `decknix-hub-url`, so the row cannot be opened
or actioned — a merged PR becomes unreachable from the sidebar.

Note the vocabulary already exists and is correct:
`decknix--hub-format-row-label` returns `merged`, `closed`, `drafting`,
`merge conflict`, `CI failing`, `CI running`, `changes requested`,
`approved`, `awaiting review`, `open`. It never runs on these rows,
because by then they are not PR rows.

So this is not a labelling bug. It is a **loss of association**: nothing
remembers that the branch had a PR once the PR stops being open.

## 3. What the row should say

```
branch, no PR ever              wip
PR open, draft                  drafting
PR open, awaiting review        awaiting review
PR merged                       merged        + #N, actionable
PR closed unmerged              closed        + #N, actionable
```

Colour already distinguishes these in `decknix--hub-format-row-label`'s
consumers; the gap is which word reaches them, and whether `#N` survives.

## 4. Candidate approaches

**A. Remember the last-known PR per branch.** Store `(repo, branch) ->
{number, state, url}` in the worktree registry when a PR is seen, and
have the placeholder renderer consult it. Survives the PR leaving the
feed, costs one small persisted map, and needs an invalidation rule for a
branch that is deleted and recreated.

**B. Query closed PRs for the branch.** Authoritative and stateless, but
adds a network call per placeholder row on a path that is meant to be
disk-free — the placeholder exists precisely so a worktree shows at t=0.

**C. Widen the WIP feed to include recently-merged PRs.** Changes what
the feed means for every consumer, and `decknix--hub-wip-terminal-visible-p`
already deliberately hides merged PRs once deployed. Risks re-introducing
the noise that toggle removes.

A is preferred: it keeps the render path local and matches how the
worktree registry already caches branch facts.

## 4.1 Sibling: PRs handed to someone else

`wip-ownership.md` records the other half of this theme. A PR you
authored and then ASSIGNED to someone else stays in your WIP list,
because nothing models the transfer of responsibility -- the same gap as
a merged PR staying visible as `wip`.

Both are "WIP shows work that has left you". They touch the same rows and
want designing together; that spec's step 5 folds these steps in.

## 5. Open questions

1. **When does a merged worktree stop being shown at all?** This overlaps
   `#165 step 2` (review worktree lifecycle / prune). A merged worktree is
   exactly what that step reaps, so the two should be designed together
   rather than one papering over the other.
2. **Deploy-gating.** `decknix--hub-wip-terminal-visible-p` keeps merged
   PRs visible until their code reaches production. A merged *placeholder*
   presumably wants the same rule, which argues for reusing that predicate
   rather than writing a second one.
3. **Branch reuse.** If a branch is deleted and a new PR opened from the
   same name, a stale cached association would mislabel it. Keying on
   `(repo, branch, created-at)` or invalidating on worktree removal would
   settle it.

## 6. Sequencing

1. Persist last-known PR per `(repo, branch)` when the WIP feed is parsed
2. Placeholder renderer consults it: state-word, `#N`, and a URL
3. Reuse `decknix--hub-wip-terminal-visible-p` so merged placeholders
   follow the same visibility rule as merged PR rows
4. Decide the prune interaction with `#165 step 2`

Steps 1–2 fix what is visible and carry no risk to the open-PR path.
Step 4 is a design decision, not a change.
