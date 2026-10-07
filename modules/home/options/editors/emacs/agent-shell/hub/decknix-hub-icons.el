;;; decknix-hub-icons.el --- Hub PR review/activity icons + age formatter -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, hub, github, format, icons

;;; Commentary:
;;
;; Pure formatters + propertize-only icon helpers extracted from the
;; agent-shell heredoc.  Five symbols across two clusters that share
;; the `decknix--hub-icon' emoji-shim from `decknix-hub-ci' for
;; consistent line-height across mixed glyph rendering:
;;
;; -- age formatter --
;;
;;   `decknix--hub-format-age'         (ISO -> compact "Nd" / "Nh" /
;;                                      "Nm" / "now" / "?")
;;
;; -- icon decoders --
;;
;;   `decknix--hub-review-icon'        (item -> review state glyph
;;                                      for PRs I am reviewing)
;;   `decknix--hub-wip-review-icon'    (pr -> review-decision glyph
;;                                      for PRs I authored)
;;   `decknix--hub-activity-icons'     (pr -> 🤖 / 💬 / ↩ stack
;;                                      based on bot/needs-reply/
;;                                      replies-to-me flags)
;;   `decknix--hub-wip-reply-icon'     (defalias-style shim
;;                                      preserving the legacy name)
;;
;; All five take alists and return strings (possibly with text
;; properties); no I/O, no global state.  `format-age' reads
;; `(current-time)' for the delta — tests stub it via `cl-letf'.

;;; Code:

(require 'iso8601)
(require 'decknix-hub-ci)
(require 'decknix-hub-mention-bot)

(defvar decknix--hub-age-parse-cache (make-hash-table :test 'equal :size 256)
  "Memoize ISO-time string -> epoch float (or nil for unparseable).
`iso8601-parse'+`encode-time' is ~8 ms, and the sidebar formats the SAME
timestamps for dozens of rows on every paint.  The parsed epoch of a fixed
ISO string never changes, so caching it collapses those repeats; the age math
still uses the live clock, so ages stay fresh.")

(defun decknix--hub-format-age (iso-time)
  "Format an ISO timestamp as a compact age string (e.g. 3d, 5h, 12m).
The parse is memoized (see `decknix--hub-age-parse-cache'); only the cheap
subtraction from the current time runs per call."
  (if (and iso-time (stringp iso-time))
      (let* ((cached (gethash iso-time decknix--hub-age-parse-cache 'miss))
             (then (if (eq cached 'miss)
                       (let ((v (condition-case nil
                                    (float-time (encode-time (iso8601-parse iso-time)))
                                  (error nil))))
                         (puthash iso-time v decknix--hub-age-parse-cache)
                         v)
                     cached))
             ;; `(current-time)' (not bare `(float-time)') so a stubbed clock
             ;; is honoured in tests; identical to real-now in production.
             (secs (when then (- (float-time (current-time)) then))))
        (cond
         ((null secs) "?")
         ((>= secs 86400) (format "%dd" (truncate (/ secs 86400))))
         ((>= secs 3600) (format "%dh" (truncate (/ secs 3600))))
         ((>= secs 60) (format "%dm" (truncate (/ secs 60))))
         (t "now")))
    "?"))

(defun decknix--hub-review-icon (item)
  "Return a review state icon for ITEM, or empty string if none.
Shows whether the current user has already responded to this PR.
  ◐ = commented (cyan), ● = approved (green), ◐ = changes requested (red)."
  (let ((state (alist-get 'my_review item)))
    (pcase state
      ("APPROVED"          (decknix--hub-icon "●" 'success))
      ("CHANGES_REQUESTED" (decknix--hub-icon "◐" 'error))
      ("COMMENTED"         (decknix--hub-icon "◐" '(:foreground "cyan" :weight bold)))
      ("DISMISSED"         (decknix--hub-icon "−" 'shadow))
      ("PENDING"           (decknix--hub-icon "…" 'warning))
      (_ ""))))

(defun decknix--hub-wip-review-icon (pr)
  "Return a review decision icon for a WIP PR, or empty string.
Shows the overall review status of the user's own PR:
  ● = approved (green), ◐ = changes requested (red),
  ◐ = review required (green), (none) = no review policy."
  (let ((decision (alist-get 'review_decision pr)))
    (pcase decision
      ("APPROVED"          (decknix--hub-icon "●" 'success))
      ("CHANGES_REQUESTED" (decknix--hub-icon "◐" 'error))
      ("REVIEW_REQUIRED"   (decknix--hub-icon "◐" 'success))
      (_ ""))))

(defconst decknix-lifecycle-shapes
  '((worktree-new . "◌")   ; nothing built yet -- dotted, says "no state"
    (worktree     . "○")   ; a worktree, coloured by its build
    (draft        . "★")   ; a draft PR
    (draft-pr     . "◐")   ; a draft PR (circle family)
    (open         . "●")   ; an open PR
    (closed       . "■")   ; merged or closed
    (conflict     . "⊗"))  ; cannot merge
  "One shape family across worktrees and PRs.

SHAPE says what a thing is and how far along: hollow for a worktree, half
for a draft, full for an open PR, square for closed, crossed for a
conflict.  COLOUR says how its build is: green it can land, yellow
building, red it cannot, grey nothing reported.

Two channels for two independent facts.  They were one channel before,
which is why `approved and still building\=' had no representation -- the
colour was already spent saying whose move it was -- and why `●\=' meant
both an approved PR and an active worktree, the same glyph for unrelated
things.

`⊗\=' for conflict rather than `⊘\=': that is taken by the review-status
badge for a PR that has left the review queue.")

(defun decknix-lifecycle-shape (kind)
  "Return the glyph for lifecycle KIND."
  (or (alist-get kind decknix-lifecycle-shapes) "·"))

(defconst decknix-build-faces
  '((pass . success) (running . warning) (fail . error) (none . shadow))
  "Face per build outcome, shared by every shape.

Grey is `nothing reported\=', which is rare and genuinely unknown rather
than fine -- measured at 2 PRs of 42.  A worktree has no CI at all, so
grey is its resting state until something records a local build.")

(defun decknix-build-face (outcome)
  "Return the face for build OUTCOME."
  (or (alist-get outcome decknix-build-faces) 'shadow))

(defun decknix--hub-pr-approved-p (item)
  "Return non-nil when somebody has approved ITEM.

Reads `approvers\=' as well as `review_decision\='.  GitHub leaves
`review_decision\=' EMPTY while any requested reviewer is still
outstanding, so an approved PR with a second reviewer pending reported
no decision at all -- followupboss-integration#252 had
approvers (jonathan-lo), review_decision empty, and rendered as though
nothing were known about it."
  (let ((approvers (alist-get 'approvers item)))
    (or (and approvers (listp approvers) (> (length approvers) 0))
        (equal (alist-get 'review_decision item) "APPROVED")
        (equal (alist-get 'my_review item) "APPROVED"))))

(defun decknix--hub-pr-unresolved (item)
  "Return the number of unresolved HUMAN conversations on ITEM.

Human rather than total: GitHub blocks a rebase-merge on an unresolved
conversation, and a bot thread is not the one standing in the way."
  (or (alist-get 'human_unresolved item)
      (alist-get 'unresolved_threads item)
      0))

(defun decknix--hub-pr-blocked-by-threads-p (item)
  "Return non-nil when ITEM is approved but cannot merge for a conversation.

The state that had no representation at all: approved, CI green, and
still unmergeable until a thread is resolved.  It is the owner\='s move,
which is what makes it worth a glyph of its own."
  (and (decknix--hub-pr-approved-p item)
       (> (decknix--hub-pr-unresolved item) 0)))

(defun decknix--hub-discussion-icon (item)
  "Return a marker for how much conversation ITEM carries, or empty.

Counts RESOLVED threads -- the unresolved ones have their own marker and
are a different fact.  Shown because discussion volume distinguishes
otherwise identical rows: eleven followupboss PRs rendered the same, and
one had no conversation at all while another had ten resolved threads.

Dim, because settled discussion is context rather than a call to act."
  (let* ((total (or (alist-get 'total_threads item) 0))
         (unres (decknix--hub-pr-unresolved item))
         (settled (max 0 (- total unres))))
    (if (> settled 0)
        (decknix--hub-icon (format "‥%d" (min settled 9)) 'shadow)
      "")))

(defun decknix--hub-awaiting-my-reply-p (item)
  "Return non-nil when the last word on ITEM was somebody else\='s.

`needs_reply\=' from the feed: the latest comment or review came from
someone other than me.  On my own PR that is my move, and it was
invisible -- ten of eleven followupboss PRs carried it and not one showed
anything."
  (eq (alist-get 'needs_reply item) t))

(defun decknix--hub-reply-icon (item)
  "Return a marker when ITEM is waiting on a reply from me, or empty."
  (if (decknix--hub-awaiting-my-reply-p item)
      (decknix--hub-icon "↩" 'warning)
    ""))

(defun decknix--hub-unresolved-icon (item)
  "Return a marker for ITEM\='s unresolved conversations, or an empty string.

Shown because it is the thing that actually blocks the merge, and it was
invisible: followupboss-integration#252 had one unresolved human thread
holding up a rebase-merge, with nothing in the row to say so."
  (let ((n (decknix--hub-pr-unresolved item)))
    (if (> n 0)
        (decknix--hub-icon (format "◆%d" (min n 9)) 'warning)
      "")))

(defun decknix--hub-primary-status-icon (item kind &optional tc-status)
  "Return a primary status icon for ITEM of KIND.
KIND is one of `wip', `review', `placeholder', or `done'.
OPTIONAL TC-STATUS is a TeamCity build alist.
Follows the shape-family system: ○ ★ ◐ ● ▣ ■.  Author provenance
\(bot vs human) is a separate column -- see `decknix--hub-author-icon'.
Incorporates CI and mergeable status into the primary signal to
reduce sidebar duplication."
  (let* ((state (alist-get 'state item))
         (draft (eq (alist-get 'draft item) t))
         (ci (alist-get 'ci item))
         (mergeable (alist-get 'mergeable item))
         (conflicting (equal mergeable "CONFLICTING"))
         (classified (decknix--hub-ci-classify ci))
         (tc-fail (member (alist-get 'status tc-status) '("FAILURE" "ERROR")))
         (tc-running (string= (alist-get 'state tc-status) "running"))
         (decision (cond ((eq kind 'wip) (alist-get 'review_decision item))
                         ((eq kind 'review) (alist-get 'my_review item))
                         (t nil))))
    (cond
     ;; Author provenance (bot vs human) is rendered in its own column by
     ;; `decknix--hub-author-icon' now, so the primary glyph is pure state
     ;; even for bot-opened PRs (which previously collapsed to π and hid
     ;; their CI / draft / merge state).
     ((eq kind 'placeholder)
      (decknix--hub-icon "○" 'shadow))
     ((string= state "MERGED")
      (decknix--hub-icon (decknix-lifecycle-shape 'closed) 'success))
     ((string= state "CLOSED")
      (decknix--hub-icon (decknix-lifecycle-shape 'closed) 'shadow))
     (conflicting
      ;; Crossed, not filled: it says CANNOT MERGE rather than borrowing a
      ;; shape from the review ladder.  `⊘' is taken by the review-status
      ;; badge for a PR that has left the queue.
      (decknix--hub-icon (decknix-lifecycle-shape 'conflict) 'error))
     (draft
      ;; HALF a circle: a draft is half way to an open PR, one stage past a
      ;; worktree.  Its colour means what every other colour here means --
      ;; how the build is going.
      (let ((face (pcase classified
                    ("fail"      'error)
                    ("soft_fail" '(:foreground "orange" :weight bold))
                    ("running"   'warning)
                    ("pass"      'success)
                    (_           'shadow))))
        (decknix--hub-icon (decknix-lifecycle-shape 'draft-pr) face)))
     (t
      ;; Two independent facts, two independent channels.
      ;;
      ;;   SHAPE  how far through review:  ◐ awaiting  ⊖ changes asked
      ;;                                   ● approved
      ;;   COLOUR how the build is:        green pass  yellow running
      ;;                                   red fail    grey no CI
      ;;
      ;; Colour previously meant WHOSE MOVE, which conflated a failing
      ;; build with an urgent review and left no way to say
      ;; "approved and still building".  Under this split that is simply a
      ;; yellow full circle: the shape says approved, the colour says
      ;; building.
      ;;
      ;; Whose court it is in is already carried by the SECTION -- Reviews
      ;; holds what was sent to me, WIP what is mine -- so the glyph
      ;; repeating it bought nothing and cost the build status.  What the
      ;; user owes beyond that rides on its own markers: `↩' a reply, `◆N'
      ;; an unresolved thread.
      (let* ((approved (decknix--hub-pr-approved-p item))
             (changes (equal decision "CHANGES_REQUESTED"))
             ;; FULL circle: an open PR.  The shape channel says what KIND
             ;; of thing this is -- worktree, draft, open, closed -- so
             ;; approval cannot also live there, and colour is spent on the
             ;; build.  It rides on WEIGHT instead: a bold full circle is
             ;; approved.  Changes-requested keeps its own shape, being a
             ;; blocker rather than a degree of progress.
             (shape (cond (changes "⊖")
                          (t (decknix-lifecycle-shape 'open))))
             (face (cond
                    ((or tc-fail (equal classified "fail")) 'error)
                    ((equal classified "soft_fail")
                     '(:foreground "orange" :weight bold))
                    ((or tc-running (equal classified "running")) 'warning)
                    ((equal classified "pass") 'success)
                    ;; No checks reported at all -- rare (2 PRs of 42
                    ;; measured), and genuinely unknown rather than fine.
                    (t 'shadow))))
        (decknix--hub-icon shape (decknix--hub-weight-for face approved)))))))

(defun decknix--hub-weight-for (face approved)
  "Return FACE, emboldened when APPROVED.

Weight carries approval because the other two channels are taken: shape
says what KIND of thing a row is, colour how its build is going.  A bold
full circle is an approved PR whose build is whatever the colour says --
including yellow, which is the `approved and still building\=' case that
had no representation when one channel carried both facts."
  (if (not approved)
      face
    (if (symbolp face)
        (list :inherit face :weight 'bold)
      (append face '(:weight bold)))))

(defun decknix--hub-author-icon (item)
  "Return the author-provenance glyph for a Requests row ITEM.

  π         bot-opened PR, only bot commits.
  Ω (bold)  bot-opened PR a human has since committed to.
  Ω         human-authored PR.

Reads the hub-provided `author_kind' (\"bot\" | \"bot_human\" |
\"human\").  When it is absent (payload predates the field) it degrades
via the author login's bot pattern -- a bot login yields π, anything
else Ω -- since without commit data a human contributor to a bot PR
cannot be detected."
  (pcase (alist-get 'author_kind item)
    ("bot"       (decknix--hub-icon "π" '(:foreground "#af5f87")))
    ("bot_human" (decknix--hub-icon "Ω" '(:foreground "#af5f87" :weight bold)))
    ("human"     (decknix--hub-icon "Ω" 'shadow))
    (_ (if (decknix--hub-bot-author-p (alist-get 'author item))
           (decknix--hub-icon "π" '(:foreground "#af5f87"))
         (decknix--hub-icon "Ω" 'shadow)))))

(defvar decknix--hub-symbol-style)

(defun decknix--hub-activity-icons (pr)
  "Return concatenated attention icons for PR.

Indicates two families of signals (Human and Bot).
Human family (left slot):
- ↩ / i[bold] (replies-to-me) when a human posted after one of my comments.
- 💬 / i[dim]  (needs-reply) when the latest activity is a human and not me.
- ⏳ / .[dim]  (i-replied-last) when my own comment is the latest and I am
              waiting on a response; lowest priority in the human slot.
Bot family (right slot):
- 👽 / β[bold] (bot-replies-to-me) when a bot replied after my comment.
- 🤖 / β[dim]  (bot-pending) when the latest activity is a bot.

On an ATTRIBUTED feed (one carrying `human_unresolved' /
`bot_unresolved' / `human_said_something') the rules are:

    i  italic   human_unresolved > 0 OR human_said_something
    beta        bot_unresolved > 0
    .  dim      i_replied_last AND a thread still open
    (none)      approvals, bodiless reviews, resolved threads

`needs_reply' plays no part there.  In the feed it means \"the last post
was not mine\", which a bodiless APPROVED review and a \"LGTM\" in the
conversation tab both satisfy -- so it fired the italic `i' when nothing
needed an answer.  Reported as \"italic i does not necessarily mean there
is a comment that needs to be responded to\".

Approval no longer suppresses everything on an attributed feed: an open
human thread on an approved PR is precisely a comment worth considering,
and the blanket suppression hid it.  The fields decide instead.

On a LEGACY feed -- which is what the daemon writes until it restarts --
the old rules below apply unchanged, so nothing regresses in the gap.

Activity icons are suppressed for APPROVED PRs (legacy path only).

Thread-aware suppression applies to BOT CHATTER ONLY: 🤖 (bot-pending) is
suppressed when `total_threads' is greater than zero and
`unresolved_threads' is zero, because a bot trailing \"no suggestions\"
across resolved threads leaves nothing actionable.

The human icons survive resolution.  It used to suppress ALL icons,
which
hid real comments -- reported on nc-helix/platform-cli #41 and #44, both
carrying `needs_reply' t with every inline thread resolved and no sidebar
indication at all. Threads are normally resolved by the author or by a
bot rather than by me, so \"resolved\" says nothing about whether I have
read the reply in them.

Returns a string of length 2 (padded with spaces) if any activity is present,
else an empty string.  Honours `decknix--hub-symbol-style' (\"ascii\" uses
italic characters and weight)."
  (let* ((needs-reply       (eq (alist-get 'needs_reply pr) t))
         (bot-pending       (eq (alist-get 'bot_pending pr) t))
         (replies-to-me     (eq (alist-get 'replies_to_me pr) t))
         (bot-replies-to-me (eq (alist-get 'bot_replies_to_me pr) t))
         (i-replied-last    (eq (alist-get 'i_replied_last pr) t))
         ;; Use both possible decision fields
         (decision          (or (alist-get 'review_decision pr)
                                (alist-get 'my_review pr)))
         (approved          (equal decision "APPROVED"))
         ;; Thread-aware suppression: suppress human ↩/💬 when all inline
         ;; threads are resolved.  Only applies when total_threads > 0
         ;; so PRs with only PR-level comments fall back to stream logic.
         (total-threads     (alist-get 'total_threads pr))
         (unresolved        (alist-get 'unresolved_threads pr))
         ;; Attributed thread counts and the body-aware human signal.  Absent
         ;; from a feed written by an older hub binary, which is the normal
         ;; state until the daemon restarts -- so their absence selects the
         ;; legacy rules rather than silently reading nil as zero.
         (unresolved-total  (alist-get 'unresolved_total pr))
         (human-unresolved  (alist-get 'human_unresolved pr))
         (bot-unresolved    (alist-get 'bot_unresolved pr))
         (human-said        (eq (alist-get 'human_said_something pr) t))
         (attributed        (and (integerp human-unresolved)
                                 (integerp bot-unresolved)))
         (emoji-layout      (and (boundp 'decknix--hub-symbol-style)
                                 (eq decknix--hub-symbol-style 'emoji))))
    (if (and approved (not attributed))
        ""
      ;; An icon means OUTSTANDING work, attributed to who left it.
      ;;
      ;;   italic i  a HUMAN comment not yet addressed
      ;;   beta      an UNRESOLVED bot comment
      ;;   dim .     I replied and left the thread open, awaiting them
      ;;
      ;; `needs_reply' cannot carry the human slot alone: in the feed it
      ;; means "the last post was not mine", not "a human posted".
      ;; Measured on platform-cli #45-#48, all four had `needs_reply' t
      ;; with `bot_replies_to_me' t and zero unresolved threads -- four
      ;; rows shouting about bots that had already finished.  So a
      ;; bot-attributable row never drives the human slot.
      (let* ((open-threads
          ;; Any thread still open, whoever spoke last. `unresolved_threads'
          ;; means "awaiting MY reply" and reads 0 once I have replied, so a
          ;; thread I answered but never resolved was invisible: PR 203 had two
          ;; of them and showed nothing.
          (if (integerp unresolved-total)
              (> unresolved-total 0)
            (and unresolved (> unresolved 0))))
             (addressed
              (if attributed
                  ;; Attributed feed: no human thread open and no human has
                  ;; said anything since my last say.  Nothing to READ --
                  ;; which is not the same as nothing to show.  A thread I
                  ;; answered and left open scores `human_unresolved' 0
                  ;; (I spoke last), so this would swallow the dim
                  ;; "waiting on them" marker; that case is excluded and
                  ;; falls through to its own branch below.
                  (and (zerop human-unresolved)
                       (not human-said)
                       (not open-threads))
                ;; Threads exist and every one is resolved.
                (or (and total-threads (> total-threads 0)
                         unresolved (= unresolved 0))
                    ;; I posted last and left nothing open behind me.
                    (and i-replied-last (not open-threads)))))
             (bot-attributable
              (if attributed
                  (> bot-unresolved 0)
                (or bot-replies-to-me bot-pending)))
             ;; The human slot's trigger.  On an attributed feed this is the
             ;; whole point of the change: `needs_reply' means "the last post
             ;; was not mine" -- it counts a bodiless APPROVED review and a
             ;; "LGTM" in the conversation tab as things to read, which is why
             ;; the glyph fired when nothing needed an answer.
             (human-outstanding
              (if attributed
                  (or (> human-unresolved 0) human-said)
                (and needs-reply (not bot-attributable))))
             (h (cond
                 (addressed "")
                 ;; A person answering ME outranks everything: it is
                 ;; outstanding until I answer back.
                 ;; A person answering ME outranks everything.  On an
                 ;; attributed feed it must still BE outstanding -- once their
                 ;; thread is resolved and nothing has been said since, there
                 ;; is nothing to read.  On a legacy feed `replies_to_me'
                 ;; stands alone, exactly as before, so nothing regresses
                 ;; while the daemon is still writing the old shape.
                 ((and replies-to-me (or (not attributed) human-outstanding))
                  (if emoji-layout
                      (decknix--hub-icon "\u21a9" '(:foreground "#87d7af" :weight bold))
                    (propertize "i" 'face '(:foreground "#5fc8d4" :weight bold :slant italic))))
                 ;; A human left something unaddressed.
                 (human-outstanding
                  (if emoji-layout
                      (decknix--hub-icon "\U0001F4AC" '(:foreground "#d7af5f"))
                    (propertize "i" 'face '(:foreground "#5fc8d4" :weight normal :slant italic))))
                 ;; I replied and deliberately left the thread OPEN, so the
                 ;; ball is with them.  Distinct from addressed: leaving a
                 ;; thread unresolved is how you say "still waiting", and
                 ;; collapsing it into silence loses that.  Dim, and last in
                 ;; the ladder -- it is information, not a call to act.
                 ((and open-threads
                       (or i-replied-last
                           ;; Every open thread has me as its last commenter,
                           ;; so nothing awaits my reply but they still need
                           ;; resolving.
                           (and attributed
                                (zerop human-unresolved)
                                (zerop bot-unresolved))))
                  (if emoji-layout
                      (decknix--hub-icon "\u23f3" '(:foreground "#6c6c6c"))
                    (propertize "." 'face '(:foreground "#6c6c6c" :weight normal))))
                 (t "")))
             ;; The bot slot requires an OPEN thread, with no
             ;; no-threads fallback.  A bot's findings ARE threads, so a
             ;; review that found nothing leaves none -- which is exactly
             ;; the "reviewed, 0 items" case that must stay silent.
             (b (cond
                 ((if attributed
                      (> bot-unresolved 0)
                    (and bot-attributable unresolved (> unresolved 0)))
                  (if bot-replies-to-me
                      (if emoji-layout
                          (decknix--hub-icon "\U0001F47D" '(:foreground "#af5f87" :weight bold))
                        (propertize "\u03b2" 'face '(:foreground "#af5f87" :weight bold)))
                    (if emoji-layout
                        (decknix--hub-icon "\U0001F916" '(:foreground "#af5f87"))
                      (propertize "\u03b2" 'face '(:foreground "#af5f87" :weight normal)))))
                 (t ""))))
        (if (and (string-empty-p h) (string-empty-p b))
            ""
          (concat (if (string-empty-p h) " " h)
                  (if (string-empty-p b) " " b)))))))

(defun decknix--hub-wip-reply-icon (pr)
  "Back-compat shim: return `decknix--hub-activity-icons' for PR."
  (decknix--hub-activity-icons pr))

(defun decknix--hub-format-row-label (pr &optional tc-status)
  "Return a human-readable state label for PR.
OPTIONAL TC-STATUS is a TeamCity build alist."
  (let* ((state (alist-get 'state pr))
         (draft (eq (alist-get 'draft pr) t))
         (ci (alist-get 'ci pr))
         (mergeable (alist-get 'mergeable pr))
         (classified (decknix--hub-ci-classify ci))
         (decision (or (alist-get 'review_decision pr)
                       (alist-get 'my_review pr)))
         (tc-fail (member (alist-get 'status tc-status) '("FAILURE" "ERROR")))
         (tc-running (string= (alist-get 'state tc-status) "running")))
    (cond
     ((string= state "MERGED") "merged")
     ((string= state "CLOSED") "closed")
     ((equal mergeable "CONFLICTING") "merge conflict")
     (draft "drafting")
     ((or tc-fail (equal classified "fail")) "CI failing")
     ((or tc-running (equal classified "running")) "CI running")
     ((equal decision "CHANGES_REQUESTED") "changes requested")
     ((equal decision "APPROVED") "approved")
     ((equal decision "REVIEW_REQUIRED") "awaiting review")
     (t "open"))))

(provide 'decknix-hub-icons)
;;; decknix-hub-icons.el ends here
