;;; decknix-hub-sidebar-paint.el --- Coalesced idle repaint for the sidebar -*- lexical-binding: t -*-

;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;;
;; The workspace sidebar repaints (erase + rebuild the whole buffer) on
;; an upstream 2-second `run-with-timer' tick, on every hub file-notify
;; event, and on many user actions -- all by calling
;; `agent-shell-workspace-sidebar-refresh' synchronously.  Even after the
;; render tick was made disk-free (see `decknix-hub-path-facts'), that
;; full repaint is ~100+ ms of consing, and firing it mid-keystroke is
;; felt as a hitch: you type, nothing moves, then it catches up.
;;
;; This module defers and COALESCES every repaint request onto a single
;; short-idle timer.  A burst of refresh calls (2 s tick + file-notify +
;; a user action, all within the same active moment) collapses to ONE
;; paint that fires the instant the user pauses -- never while a key is
;; pending.  Continuous typing therefore produces zero paints; a single
;; catch-up paint runs on the next idle gap.
;;
;; Correct-by-construction: each scheduled paint still runs the full,
;; unmodified `agent-shell-workspace-sidebar-refresh', so the rendered
;; content is never stale -- only its timing moves off the keystroke.
;;
;; Wiring lives in the heredoc (see `agent-shell.nix'): the named
;; `decknix--sidebar-refresh-debounce-advice' is attached as the
;; outermost `:around' advice on `agent-shell-workspace-sidebar-refresh'.
;; A named function keeps the advice idempotent across hot-reloads
;; (re-`advice-add' of the same symbol is a no-op), unlike an anonymous
;; lambda which would accumulate a new debounce layer on every reload.

;;; Code:

(require 'cl-lib)

;; Provided by the upstream `agent-shell-workspace' package; only ever
;; called through the advice, so a forward declaration is enough.
(declare-function agent-shell-workspace-sidebar-refresh "ext:agent-shell-workspace")
(declare-function agent-shell-buffers "ext:agent-shell")
(declare-function agent-shell-workspace--buffer-status "ext:agent-shell-workspace")
(defvar decknix--hub-dir)
(defvar agent-shell-workspace-sidebar--refresh-timer)

(defvar decknix-sidebar-paint-idle-delay 0.6
  "Idle seconds to wait before repainting the sidebar after a request.
Small enough to feel near-immediate on a natural typing pause, large
enough that it never fires between two consecutive keystrokes.  Raised
from 0.3 to 0.6 so a brief think-pause mid-typing no longer triggers the
~100ms repaint in front of the next keystroke; the paint tick also
re-defers when input is pending (see `decknix--sidebar-paint-tick').")

(defvar decknix--sidebar-paint-timer nil
  "The single pending coalesced repaint timer, or nil when none is armed.")

(defvar decknix--sidebar-paint-in-progress nil
  "Non-nil only while the idle worker is driving the real repaint.
Bound dynamically by `decknix--sidebar-paint-now' so the debounce advice
lets that real paint through to the underlying refresh instead of
re-deferring it into another idle cycle.")

(defun decknix--sidebar-paint-through-p ()
  "Return non-nil when a refresh call must paint now instead of deferring."
  decknix--sidebar-paint-in-progress)

(defun decknix--sidebar-cancel-paint ()
  "Cancel any pending coalesced repaint and clear the timer slot."
  (when (timerp decknix--sidebar-paint-timer)
    (cancel-timer decknix--sidebar-paint-timer))
  (setq decknix--sidebar-paint-timer nil))

(defun decknix--sidebar-schedule-paint (paint-fn)
  "Coalesce a repaint: cancel any prior pending one and arm PAINT-FN on idle.
Because each request replaces the previous pending timer, a burst of
requests collapses to a single PAINT-FN invocation once the user pauses
for `decknix-sidebar-paint-idle-delay' seconds."
  (decknix--sidebar-cancel-paint)
  (setq decknix--sidebar-paint-timer
        (run-with-idle-timer decknix-sidebar-paint-idle-delay nil paint-fn)))

(defun decknix--sidebar-paint-now (refresh-fn)
  "Run REFRESH-FN as the real synchronous repaint.
Clears the pending-timer slot and holds `decknix--sidebar-paint-in-progress'
non-nil for the duration so the debounce advice paints through rather than
re-deferring.  Errors in REFRESH-FN are swallowed so a single bad paint
cannot leave the guard stuck."
  (setq decknix--sidebar-paint-timer nil)
  (let ((decknix--sidebar-paint-in-progress t))
    (ignore-errors (funcall refresh-fn)))
  ;; Re-baseline the idle-tick dirty check off this fresh paint, so the
  ;; 2 s tick only repaints on changes that happen AFTER it (from any
  ;; source), never redundantly re-painting what we just drew.
  (setq decknix--sidebar-idle-last-fingerprint (decknix--sidebar-idle-fingerprint)
        decknix--sidebar-idle-last-paint (float-time))
  ;; Universal eager-persist net: any state change reaches the sidebar
  ;; through a repaint, so persist toggle state (debounced + dirty-
  ;; checked, hence free when nothing changed) after each real paint.
  ;; This covers hub-filter toggles that refresh but do not call the
  ;; eager saver themselves, so they survive a hard daemon restart
  ;; instead of waiting for the 30s idle save / a clean shutdown.
  (when (fboundp 'decknix--sidebar-state-write)
    (decknix--sidebar-state-write)))

(defun decknix--sidebar-paint-tick ()
  "Idle-timer entry point: perform the real sidebar repaint.
If the user has resumed typing by the moment the idle timer fires
\(`input-pending-p'), re-defer onto a fresh idle timer rather than run
the ~100ms synchronous paint ahead of that queued keystroke.  The paint
then lands on the next genuine pause, so continuous typing yields zero
paints and never a visible input hitch."
  (if (input-pending-p)
      (decknix--sidebar-schedule-paint #'decknix--sidebar-paint-tick)
    (decknix--sidebar-paint-now #'agent-shell-workspace-sidebar-refresh)))

;; -- Dirty-checked idle tick (replaces the blind 2 s repaint timer) --
;;
;; Upstream arms `(run-with-timer 2 2 #'agent-shell-workspace-sidebar-refresh)'
;; in `agent-shell-workspace-sidebar-mode', so the sidebar fully repaints
;; every 2 s forever -- even when nothing changed.  On a large sidebar
;; that ~100ms erase+rebuild, 30x/minute, pegs a core in `redisplay_internal'.
;;
;; We swap that timer for `decknix--sidebar-idle-tick': same 2 s cadence,
;; but it repaints ONLY when the inputs that change passively (hub JSON
;; files + live-session statuses) actually changed, or once per
;; `decknix-sidebar-idle-force-interval' so relative timestamps still
;; advance.  User/event driven changes (toggles, selection, file-notify,
;; `g') keep painting immediately through the normal refresh path, so
;; they need not appear in the fingerprint.

(defvar decknix-sidebar-idle-force-interval 60
  "Seconds after which the idle tick repaints even if nothing changed.
Bounds worst-case staleness (e.g. a relative \"6h\" timestamp, or any
input not covered by the fingerprint) and refreshes relative times.
Small enough to feel current, large enough that a static sidebar costs
one paint a minute instead of one every two seconds.")

(defconst decknix--sidebar-idle-hub-files
  '("github-reviews.json" "github-wip.json" "teamcity-deploys.json"
    "teamcity-builds.json" "jira-tasks.json" "meta.json")
  "Hub data files whose mtime/size drives a sidebar repaint.")

(defvar decknix--sidebar-idle-last-fingerprint 'unset
  "Fingerprint of the sidebar inputs as of the last real paint.")

(defvar decknix--sidebar-idle-last-paint 0
  "`float-time' of the last real sidebar paint (for the force interval).")

(defun decknix--sidebar-idle-fingerprint ()
  "Cheap fingerprint of the sidebar inputs that change passively.
Covers hub data file mtime+size and the live agent-shell buffers'
statuses -- the two things the blind 2 s timer existed to catch.  A few
`file-attributes' calls plus a buffer walk: sub-millisecond, versus the
~100ms paint it guards."
  (list
   (when (and (boundp 'decknix--hub-dir) decknix--hub-dir)
     (mapcar (lambda (f)
               (let ((attrs (file-attributes
                             (expand-file-name f decknix--hub-dir))))
                 (when attrs
                   (list f (file-attribute-modification-time attrs)
                         (file-attribute-size attrs)))))
             decknix--sidebar-idle-hub-files))
   (when (and (fboundp 'agent-shell-buffers)
              (fboundp 'agent-shell-workspace--buffer-status))
     (mapcar (lambda (b)
               (cons (buffer-name b)
                     (ignore-errors (agent-shell-workspace--buffer-status b))))
             (agent-shell-buffers)))))

(defun decknix--sidebar-idle-should-paint-p (fingerprint last-fingerprint
                                                         last-paint now
                                                         force-interval)
  "Return non-nil when the idle tick should repaint the sidebar.
Repaint when FINGERPRINT differs from LAST-FINGERPRINT (an input
changed), or when NOW is at least FORCE-INTERVAL seconds past LAST-PAINT.
Pure, so the decision is unit-testable without a live sidebar."
  (or (not (equal fingerprint last-fingerprint))
      (>= (- now last-paint) force-interval)))

(defun decknix--sidebar-idle-tick ()
  "Dirty-checked replacement for the sidebar's blind 2 s auto-refresh.
Repaints (through the normal debounced refresh) only when an input
changed or the force interval elapsed, so an idle sidebar stops pegging
`redisplay_internal'."
  (when (and (fboundp 'agent-shell-workspace-sidebar-refresh)
             (decknix--sidebar-idle-should-paint-p
              (decknix--sidebar-idle-fingerprint)
              decknix--sidebar-idle-last-fingerprint
              decknix--sidebar-idle-last-paint
              (float-time)
              decknix-sidebar-idle-force-interval))
    (agent-shell-workspace-sidebar-refresh)))

(defun decknix--sidebar-install-idle-tick (&rest _)
  "Swap the sidebar's blind 2 s refresh timer for the dirty-checked tick.
Attached as `:after' advice on `agent-shell-workspace-sidebar-mode'.
Cancels the timer the mode just armed and re-uses the same storage var so
the upstream `kill-buffer-hook' still tears ours down with the buffer."
  (when (boundp 'agent-shell-workspace-sidebar--refresh-timer)
    (when (timerp agent-shell-workspace-sidebar--refresh-timer)
      (cancel-timer agent-shell-workspace-sidebar--refresh-timer))
    (setq decknix--sidebar-idle-last-fingerprint 'unset
          decknix--sidebar-idle-last-paint 0
          agent-shell-workspace-sidebar--refresh-timer
          (run-with-timer 2 2 #'decknix--sidebar-idle-tick))))

(defun decknix--sidebar-refresh-debounce-advice (orig-fn &rest args)
  "Around-advice for `agent-shell-workspace-sidebar-refresh'.
Paint through to ORIG-FN (with ARGS) when the idle worker is already
driving the real repaint; otherwise coalesce this request onto the
short-idle paint timer and return immediately, so no repaint ever runs
between keystrokes."
  (if (decknix--sidebar-paint-through-p)
      (apply orig-fn args)
    (decknix--sidebar-schedule-paint #'decknix--sidebar-paint-tick)))

;; -- Incremental diff render ----------------------------------------
;;
;; Even a needed repaint erases the whole sidebar and re-inserts every
;; row, so `redisplay_internal' reprocesses the entire buffer -- the
;; dominant remaining cost once idle repaints were gone.  Instead, render
;; the fresh content into a scratch buffer and apply only the lines that
;; actually changed to the visible buffer, so redisplay touches just
;; those rows.  A plain `replace-buffer-contents' is unusable here: it
;; keeps the OLD text properties for character-identical text, so a
;; face-only change (the selection highlight moving, a deploy glyph going
;; yellow->green) would silently not render.  Hence a property-aware
;; line diff: lines compare with `equal-including-properties'.

(defun decknix--sidebar-split-lines (s)
  "Split S into a list of lines, each RETAINING its trailing newline.
The final line carries a newline only if S ended with one.  Text
properties are preserved on each substring."
  (let ((lines nil) (start 0) (len (length s)))
    (while (< start len)
      (let ((nl (string-search "\n" s start)))
        (if nl
            (progn (push (substring s start (1+ nl)) lines)
                   (setq start (1+ nl)))
          (push (substring s start) lines)
          (setq start len))))
    (nreverse lines)))

(defun decknix--sidebar-line-diff (old-lines new-lines)
  "Minimal single-region edit turning OLD-LINES into NEW-LINES.
Both are line lists (with trailing newlines) from
`decknix--sidebar-split-lines'; lines compare with
`equal-including-properties' so a face-only change counts as a change.
Returns a plist (:prefix-chars N :suffix-chars M :middle STR): keep the
first N and last M characters of the old text, replace the differing
middle with STR.  Returns nil when the two are identical.  Pure, so the
edit computation is ERT-testable without a buffer."
  (let ((pre-a old-lines) (pre-b new-lines))
    (while (and pre-a pre-b
                (equal-including-properties (car pre-a) (car pre-b)))
      (setq pre-a (cdr pre-a) pre-b (cdr pre-b)))
    (if (and (null pre-a) (null pre-b))
        nil                             ; identical -> no edit
      (let ((suf 0) (x (reverse pre-a)) (y (reverse pre-b)))
        (while (and x y (equal-including-properties (car x) (car y)))
          (setq suf (1+ suf) x (cdr x) y (cdr y)))
        (let ((prefix-lines (butlast old-lines (length pre-a)))
              (suffix-lines (last pre-a suf))
              (middle-lines (butlast pre-b suf)))
          (list :prefix-chars (apply #'+ 0 (mapcar #'length prefix-lines))
                :suffix-chars (apply #'+ 0 (mapcar #'length suffix-lines))
                :middle (apply #'concat middle-lines)))))))

(defun decknix--sidebar-diff-apply (target-buf src-buf)
  "Update TARGET-BUF's text to match SRC-BUF, editing only the changed span.
Computes a property-aware line diff and replaces just the differing
middle region, so redisplay reprocesses only the changed rows and the
common head/tail (usually most of the sidebar) is left untouched."
  (when (and (buffer-live-p target-buf) (buffer-live-p src-buf))
    (let ((new (with-current-buffer src-buf (buffer-string))))
      (with-current-buffer target-buf
        (let ((diff (decknix--sidebar-line-diff
                     (decknix--sidebar-split-lines (buffer-string))
                     (decknix--sidebar-split-lines new))))
          (when diff
            (let ((inhibit-read-only t)
                  (beg (+ (point-min) (plist-get diff :prefix-chars)))
                  (end (- (point-max) (plist-get diff :suffix-chars))))
              (save-excursion
                (goto-char beg)
                (delete-region beg end)
                (insert (plist-get diff :middle))))))))))

(defun decknix--sidebar-diff-render (orig-fn &rest args)
  "Around-advice for `agent-shell-workspace-sidebar--render': diff paint.
Render ORIG-FN's fresh content into a scratch buffer -- with the
sidebar's own window selected so `window-width'-based truncation stays
correct -- then apply only the changed lines to the visible buffer via
`decknix--sidebar-diff-apply'.  Falls back to a direct render when the
sidebar buffer is not live."
  (let* ((target (current-buffer))
         (win (get-buffer-window target))
         (src (get-buffer-create " *decknix-sidebar-render*")))
    (if (not (buffer-live-p target))
        (apply orig-fn args)
      (with-current-buffer src
        (setq-local inhibit-read-only t)
        (erase-buffer))
      (cl-flet ((paint () (with-current-buffer src (apply orig-fn args))))
        (if (window-live-p win)
            (with-selected-window win (paint))
          (paint)))
      (decknix--sidebar-diff-apply target src))))

(provide 'decknix-hub-sidebar-paint)
;;; decknix-hub-sidebar-paint.el ends here
