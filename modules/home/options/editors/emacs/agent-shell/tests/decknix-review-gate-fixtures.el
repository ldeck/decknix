;;; decknix-review-gate-fixtures.el --- Closing turns of real review sessions -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Closing messages copied from `/review-service-pr' transcripts, with
;; repositories, people and review ids replaced.  The shapes are the
;; point: they are what the gate and verdict readers have to recognise,
;; and two of them (the `yes / edit / cancel' gates) are the ones the
;; question predicate used to miss.
;;
;; Shared by the turn-signals and review-board tests, so it is loaded as
;; a test file of both packages.

;;; Code:

(defconst decknix-fixture-gate-yes-edit-cancel
  "- ✅ **Tests:** cover mixed case and spaces, accents, a missing suburb and an invalid ZIP.
- ⚠️ **Minor, not posting:** the test helper sets the same district for every country.
- ✅ **Architecture, security, backwards compatibility:** the change only fills in a branch that used to return null.

BOTS
----
- augmentcode raised one finding. It's already resolved.
- No Copilot review on the PR.

PLAN
----
- **Verdict:** APPROVE
- **Body:** `LGTM.`
- **Inline comments:** none
- **Bot reactions:** none
- **Slack:** skipped (not requested)

Ready to submit? (yes / edit / cancel)"
  "The gate exactly as `/review-service-pr' words it, in a bulleted plan.")

(defconst decknix-fixture-gate-indented-plan
  "- ⚠️ Verbosity (not raising it): `?.get().filterOutDeleted()` would match the rest of the file.

PLAN (dry-run passed)
---------------------
    Verdict:          REQUEST_CHANGES
    Body:             One blocking issue inline.
    Inline comments:  1
    Bot reactions:    none
    Slack:            skipped (not requested)

Ready to submit? (yes / edit / cancel)"
  "The same gate with the plan as an indented block, the `?' inside code.")

(defconst decknix-fixture-gate-choose-one
  "Assessment: architecture, tests, security and backwards compatibility don't apply to a docs-only change.

PROPOSED REVIEW
---------------
Verdict: **APPROVE**

Body:
```
LGTM + 2 inline nits
```

Inline comments:

**`AGENTS.md:100`**
```
nit: the target already has its orgs, so this only needs an address entry?
```

**`AGENTS.md:89`**
```
nit: could this bullet just say \"opt in via the linked doc\"?
```

Bot reactions: none. Slack: skipped (not requested).

The plan passed the dry-run with no problems.

CHOOSE ONE
----------
1. yes     (submit approval + 2 nits)  [recommended]
2. edit    (change a comment or the verdict)
3. cancel  (post nothing)

Reply with the number or the name."
  "A numbered gate following the workspace decision-block rule.")

(defconst decknix-fixture-gate-heading-verdict
  "PROPOSED VERDICT
----------------
**COMMENT**

REVIEW BODY
-----------
```
Two questions inline before I approve.
```

BOT REACTIONS
-------------
None. All bot threads are resolved and outdated.

CHOOSE ONE
----------
1. proceed — submit the COMMENT with two questions to GitHub  [recommended]
2. edit    — change the verdict/body before posting
3. cancel  — post nothing

    Reply with the number or the name."
  "A gate whose verdict sits under its own heading, block indented at the end.")

(defconst decknix-fixture-posted
  "I approved #123 with a bare `LGTM.`: https://github.com/acme/widgets/pull/123#pullrequestreview-1000000001

- **Bot reactions:** none, because the only bot thread was already resolved.
- **Bot delegations:** none.
- **Slack:** skipped, since it wasn't requested.

The scratch directory for this review has been deleted.

alice authored the PR, so they merge and ship it."
  "Phase 2 done: the review is on GitHub.")

(defconst decknix-fixture-posted-then-asks
  "Re-approved: https://github.com/acme/widgets/pull/9#pullrequestreview-1000000002

Both nits were addressed, content re-verified accurate.

CHOOSE ONE
----------
1. stop  — await the author  [recommended]
2. other — tell me what else you need

Reply with the number or the name."
  "Posted, then a courtesy question that is not a call on your time.")

(defconst decknix-fixture-statement
  "Fixed the bug, added two tests, and committed as abc1234."
  "A turn that reports and asks nothing.")

(defconst decknix-fixture-before-background-wait
  "I've posted `@dependabot rebase` on #390. A background job is waiting for the new head and its CI. When it finishes I'll re-check the diff, title and commit message against each other, then show the `/ship` gate."
  "A prompted turn that hands off to a background job and asks nothing.")

(defconst decknix-fixture-gate-after-background-wait
  "#390: DEPENDABOT HASN'T REBASED
-----------------------------

I posted `@dependabot rebase` at 04:14Z. 22 minutes later there's no new head (still `a997f69b`), no reaction and no reply. The PR is still 1 behind `main` (#391), `MERGEABLE`, and CI is green on the old head.

What limits the options:
- The `main` ruleset doesn't require branches to be up to date. It does require linear history, 1 approval, and `require_last_push_approval: true`.
- That rules out `gh pr update-branch`. It would make me the last pusher, and then my own approval wouldn't count.

CHOOSE ONE
----------
1. wait: give Dependabot another 30 min, then post `@dependabot recreate` if it still hasn't moved; ship gate after green CI  [recommended]
2. merge stale: go to the #390 ship gate now (static approve, then rebase-merge onto `main`)
3. stop: halt the group (#390 and #389 untouched)

Reply with the number or the name."
  "The gate the same session reached when the background job woke it.
No prompt started this turn, so no `turn-complete' arrived for it, and the
board kept the session In progress for nineteen hours.")

(defconst decknix-fixture-still-waiting-for-pick
  "That was the second leftover search finishing. Its output is only `Widget.kt` source, not the detekt findings, so the two `detektMain` issues on #519 are still unconfirmed. Nothing in the survey changes.

I'm still waiting for your pick: 1 (ship #518 only) is recommended, or 2, or 3."
  "A background task woke a session blocked on its gate; it restates the ask.")

(defconst decknix-fixture-background-report
  "That notification was a leftover log search finishing. It found nothing new, so the two `detektMain` issues on #519 are still unconfirmed."
  "A background task woke a blocked session, which reports and asks nothing.")

(provide 'decknix-review-gate-fixtures)
;;; decknix-review-gate-fixtures.el ends here
