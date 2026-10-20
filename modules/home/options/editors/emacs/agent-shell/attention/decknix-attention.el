;;; decknix-attention.el --- One definition of "a session needs you" -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, attention

;;; Commentary:
;;
;; Which sessions are blocked on the user, in what order to visit them, and
;; how to get there.
;;
;; Two models of "needs you" had grown up side by side.  Upstream
;; `agent-shell-attention' marks a buffer pending when a turn ends with
;; `end_turn', which is every turn, and clears it when the buffer is
;; looked at; it drove `C-c A j' and the AS:n/m counter.  decknix's own
;; session states (`waiting' on a permission prompt, `asking' when the turn
;; ended on a question, `netfail' when it died on the link) drove the
;; sidebar.  They disagreed constantly: a session that finished cleanly was
;; "pending" to one and idle to the other, and a session asking a question
;; you had glanced at was idle to the first and blocked to the second.
;;
;; This module is the decknix definition, and the jump and counter are
;; driven from it so the two cannot disagree.
;;
;; Cheap by construction: `decknix-attention-observe' is a hash put, fed
;; from places that already compute session states (the session snapshot
;; and the sidebar's idle fingerprint), and the counter reads only that
;; table.  Nothing here computes a status on a redisplay path.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defconst decknix-attention-states '("netfail" "waiting" "asking")
  "Session states meaning the session is blocked on the user, most urgent first.

`netfail' first: the turn died and produced nothing, and every minute it
sits there is lost work.  `waiting' next: a permission prompt halts the
agent mid-task.  `asking' last: the turn finished, on a question.")

(defun decknix-attention-state-p (state)
  "Return non-nil when STATE means the session is blocked on the user."
  (and (member state decknix-attention-states) t))

(defun decknix-attention-rank (state)
  "Return STATE's urgency rank, lower first, or nil when it is not attention."
  (seq-position decknix-attention-states state))

(defconst decknix-attention-glyph "⚑"
  "Glyph for a session blocked on the user, wherever it is shown.

Not the half circle: that is the shape for work in flight, and an agent
paused on a question was drawn exactly like one producing output, with
only a colour between them.  The flag is already what a Reviews group
shows when one of its sessions is blocked on you.")

(defconst decknix-attention-color "#c678dd"
  "Foreground for anything blocked on the user.

Purple because it borrows no other meaning: red already says broken, amber
in progress, green done.  The sidebar, the Requests indicator and the
Reviews group rows used three different colours for this one state, so
none of them could be read without knowing which screen it was.")

(defconst decknix-attention-background "#3a1f45"
  "Background tint, a dark `decknix-attention-color', for tab-bar tabs.")

(defface decknix-attention-face
  `((t :foreground ,decknix-attention-color :weight bold))
  "Face for a session, row or tab that is blocked on the user."
  :group 'decknix)

(defun decknix-attention-age-label (since &optional now)
  "Return how long ago SINCE was, compactly: `now', `12m', `3h', `2d'."
  (if (not (numberp since))
      ""
    (let ((secs (max 0 (floor (- (or now (float-time)) since)))))
      (cond ((< secs 60) "now")
            ((< secs 3600) (format "%dm" (/ secs 60)))
            ((< secs 86400) (format "%dh" (/ secs 3600)))
            (t (format "%dd" (/ secs 86400)))))))

;; --- when each session started needing you -----------------------------

(defvar decknix-attention--seen (make-hash-table :test 'eq :weakness 'key)
  "Buffer -> (STATE . SINCE) for every agent buffer whose state was observed.

SINCE is when the buffer entered STATE.  Weak on the key so a killed
buffer drops out without a hook.")

(defun decknix-attention-observe (buffer state &optional now)
  "Record that BUFFER is in STATE, as of NOW.

Return non-nil when this is an EDGE into an attention state: BUFFER was
not in one before, or was in a different one.  The time is kept across
repeated observations of the same state, so `oldest waiting' means the
session that has been waiting longest, not the one observed last."
  (when (buffer-live-p buffer)
    (let* ((prev (gethash buffer decknix-attention--seen))
           (same (equal (car prev) state)))
      (unless same
        (puthash buffer (cons state (or now (float-time)))
                 decknix-attention--seen))
      (and (not same) (decknix-attention-state-p state)))))

(defun decknix-attention-since (buffer)
  "Return when BUFFER entered its current observed state, or nil."
  (cdr (gethash buffer decknix-attention--seen)))

(defun decknix-attention-observed-state (buffer)
  "Return BUFFER's last observed state, or nil."
  (car (gethash buffer decknix-attention--seen)))

(defun decknix-attention-count ()
  "Return (NEED . ACTIVE) from the observed states.

NEED counts live buffers in an attention state.  ACTIVE adds those
`working'.  Reads only the observation table, so it is safe to call from
a mode line."
  (let ((need 0) (active 0))
    (maphash (lambda (buf cell)
               (when (buffer-live-p buf)
                 (cond ((decknix-attention-state-p (car cell))
                        (setq need (1+ need) active (1+ active)))
                       ((equal (car cell) "working")
                        (setq active (1+ active))))))
             decknix-attention--seen)
    (cons need active)))

;; --- ordering ------------------------------------------------------------

(defun decknix-attention-order (sessions &optional since-fn)
  "Return the attention SESSIONS, most urgent first.

SESSIONS are snapshot tuples (BUFFER-NAME TAGS PRS STATE ...).  Ordered
by state rank, then by how long each has been waiting -- oldest first,
because the longest wait is the one most likely forgotten -- then by
name.  SINCE-FN maps a session to its start time; nil or a missing time
counts as now."
  (let* ((now (float-time))
         (since (lambda (s) (or (and since-fn (funcall since-fn s)) now))))
    (sort (seq-filter (lambda (s) (decknix-attention-state-p (nth 3 s))) sessions)
          (lambda (a b)
            (let ((ra (decknix-attention-rank (nth 3 a)))
                  (rb (decknix-attention-rank (nth 3 b))))
              (cond ((/= ra rb) (< ra rb))
                    ((/= (funcall since a) (funcall since b))
                     (< (funcall since a) (funcall since b)))
                    (t (string< (or (nth 0 a) "") (or (nth 0 b) "")))))))))

(defun decknix-attention-next (ordered current)
  "Return the element of ORDERED after CURRENT, wrapping, or the first.

Repeating the jump walks the queue rather than returning to the head:
answering the first session takes a turn, during which it is often still
`asking', and a jump that keeps landing there cannot reach the second."
  (let ((tail (cdr (member current ordered))))
    (or (car tail) (car ordered))))

;; --- live sessions -------------------------------------------------------

(declare-function decknix--hub-review-session-snapshot "decknix-agent-shell-hub" ())
(declare-function decknix-agent-buffer-status "decknix-agent-auto-close" (buffer))
(declare-function agent-shell-buffers "ext:agent-shell" ())
(defvar agent-shell-attention--pending)

(defun decknix-attention--sessions ()
  "Return the live session tuples, observing each one's state on the way."
  (let ((sessions
         (cond
          ((fboundp 'decknix--hub-review-session-snapshot)
           (ignore-errors (decknix--hub-review-session-snapshot)))
          ((fboundp 'agent-shell-buffers)
           (mapcar (lambda (b)
                     (list (buffer-name b) nil nil
                           (and (fboundp 'decknix-agent-buffer-status)
                                (ignore-errors (decknix-agent-buffer-status b)))))
                   (agent-shell-buffers))))))
    (dolist (s sessions)
      (let ((buf (get-buffer (or (nth 0 s) ""))))
        (when buf (decknix-attention-observe buf (nth 3 s)))))
    sessions))

(defun decknix-attention--session-since (session)
  "Return when SESSION started needing attention, or nil."
  (let ((buf (get-buffer (or (nth 0 session) ""))))
    (and buf
         (or (decknix-attention-since buf)
             ;; Upstream stamps a pending buffer when its turn ends; useful
             ;; for sessions observed for the first time just now.
             (and (boundp 'agent-shell-attention--pending)
                  (hash-table-p agent-shell-attention--pending)
                  (let ((e (gethash buf agent-shell-attention--pending)))
                    (and (consp e) (numberp (cdr e)) (cdr e))))))))

(defun decknix-attention-ordered-sessions (sessions)
  "Return the attention SESSIONS in jump order, using the observed times."
  (decknix-attention-order sessions #'decknix-attention--session-since))

(defun decknix-attention-buffers ()
  "Return the live buffers needing attention, most urgent first."
  (delq nil (mapcar (lambda (s)
                      (let ((b (get-buffer (or (nth 0 s) ""))))
                        (and (buffer-live-p b) b)))
                    (decknix-attention-ordered-sessions (decknix-attention--sessions)))))

;; --- getting there -------------------------------------------------------

(defun decknix-attention--tab-shows-p (tab buffer)
  "Return non-nil when TAB's stored window state shows BUFFER."
  (let ((ws (alist-get 'ws tab)))
    (and ws (fboundp 'window-state-buffers)
         (let ((bufs (ignore-errors (window-state-buffers ws))))
           (or (memq buffer bufs) (member (buffer-name buffer) bufs))))))

(defun decknix-attention-display-across-tabs (buffer _alist)
  "Display action: select the tab already showing BUFFER and reuse its window.

The same contract as upstream's
`agent-shell-attention-display-buffer-across-tabs', which this replaces so
the jump does not depend on that package: a session
living in its own tab is visited THERE, rather than being dragged into
whatever window happens to be selected."
  (when (and (bound-and-true-p tab-bar-mode) (fboundp 'tab-bar-tabs))
    (let* ((tabs (funcall #'tab-bar-tabs))
           (target (cl-position-if
                    (lambda (tab)
                      (if (eq (car tab) 'current-tab)
                          (get-buffer-window buffer)
                        (decknix-attention--tab-shows-p tab buffer)))
                    tabs)))
      (when target
        (unless (eq (car (nth target tabs)) 'current-tab)
          (tab-bar-select-tab (1+ target)))
        (let ((win (get-buffer-window buffer)))
          (and (window-live-p win) win))))))

(defvar decknix-attention-display-action
  '((display-buffer-reuse-window
     decknix-attention-display-across-tabs
     display-buffer-same-window))
  "Display action for `decknix-attention-jump'.
Prefers a window already showing the session, then the tab that holds it,
then the selected window.")

(declare-function agent-shell-attention--clear-buffer "ext:agent-shell-attention" (buffer))
(declare-function agent-shell-attention--permission-pending-p
                  "ext:agent-shell-attention" (buffer))

(defun decknix-attention-display (buffer)
  "Show BUFFER the way the attention jump does, and select it."
  (unless (buffer-live-p buffer) (user-error "That session is gone"))
  ;; Leaving a side or dedicated window first: from the sidebar, `same
  ;; window' would otherwise mean the sidebar's own window.
  (let ((win (selected-window)))
    (when (or (window-parameter win 'window-side) (window-dedicated-p win))
      (let ((main (window-main-window)))
        (when (window-live-p main)
          (select-window (or (seq-find (lambda (w)
                                         (not (or (window-parameter w 'window-side)
                                                  (window-dedicated-p w))))
                                       (window-list nil 'no-minibuf))
                             main))))))
  ;; Keep upstream's table tidy while it still exists, as its own jump did.
  (when (and (fboundp 'agent-shell-attention--clear-buffer)
             (fboundp 'agent-shell-attention--permission-pending-p)
             (not (ignore-errors (agent-shell-attention--permission-pending-p buffer))))
    (ignore-errors (agent-shell-attention--clear-buffer buffer)))
  (pop-to-buffer buffer decknix-attention-display-action))

(defun decknix-attention-jump (&optional prompt)
  "Go to the next session that needs you.

Ranked `netfail', then `waiting', then `asking', then by how long each has
been waiting.  Pressed again, it moves on to the next one rather than
returning to the first.  With PROMPT (prefix argument), choose from all
of them."
  (interactive "P")
  (let ((bufs (decknix-attention-buffers)))
    (cond
     ((null bufs) (message "No session needs you"))
     (prompt
      (let ((choice (completing-read
                     "Needs you: "
                     (mapcar (lambda (b)
                               (format "%s  %s" (buffer-name b)
                                       (or (decknix-attention-observed-state b) "")))
                             bufs)
                     nil t)))
        (decknix-attention-display
         (seq-find (lambda (b) (string-prefix-p (concat (buffer-name b) "  ") choice))
                   bufs))))
     (t (decknix-attention-display
         (decknix-attention-next bufs (window-buffer (selected-window))))))))

;; --- mode-line counter -------------------------------------------------

(defvar decknix-attention-lighter " AS:%d/%d"
  "Mode-line template: sessions needing you, then those plus working ones.")

(defvar decknix-attention--lighter-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1]
                (lambda () (interactive) (decknix-attention-jump t)))
    map)
  "Keymap for the counter: click to choose a session that needs you.")

(defun decknix-attention-render-lighter (&rest _upstream-counts)
  "Render the AS:n/m counter from decknix's attention states.

Installed as `agent-shell-attention-render-function', whose arguments --
upstream's own pending and busy counts -- are ignored: those come from the
end_turn model this replaces, and showing them beside the sidebar's count
let the two disagree on screen.  Reads only the observation table."
  (let ((counts (decknix-attention-count)))
    (when (or (> (car counts) 0) (> (cdr counts) 0))
      (propertize (format decknix-attention-lighter (car counts) (cdr counts))
                  'face (and (> (car counts) 0) 'decknix-attention-face)
                  'mouse-face 'mode-line-highlight
                  'help-echo "Sessions needing you / active.  mouse-1: choose one"
                  'local-map decknix-attention--lighter-map))))

(provide 'decknix-attention)
;;; decknix-attention.el ends here
