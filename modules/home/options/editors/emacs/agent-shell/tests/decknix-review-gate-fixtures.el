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

(provide 'decknix-review-gate-fixtures)
;;; decknix-review-gate-fixtures.el ends here
