;;; decknix-agent-header.el --- Unified header-line for agent-shell buffers -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, header-line

;;; Commentary:
;;
;; Pure presentation + tiny timer plumbing for the per-buffer
;; header-line shown in every agent-shell buffer.  Merges
;; agent-shell's upstream header (agent name, model, mode,
;; workspace, busy animation) with decknix-specific extras
;; (status icon + label, conversation tags, context-panel items).
;;
;; Carved out of `decknix-agent-shell-main' (main-bulk) into the
;; `agent-shell/header/' cluster so the ~150-line block of icon
;; tables, face mappings, and refresh-timer scaffolding lives in
;; its own byte-compiled unit.  The agent-shell startup hook that
;; seeds `decknix--header-update' / `-start-timer' / `-stop-timer'
;; stays in the heredoc per AGENTS.md Rule 2 (top-level
;; side-effects belong in main).
;;
;; Public surface:
;;
;;   `decknix--header-timer'             buffer-local refresh timer
;;   `decknix--header-prev-status'       buffer-local transition memo
;;
;;   `decknix--header-detect-status'     -> "ready" | "working" | ...
;;   `decknix--header-status-icon' (s)   -> "●" | "◐" | ...
;;   `decknix--header-status-face' (s)   -> face spec
;;   `decknix--header-tags'              -> list of tag strings
;;   `decknix--header-workspace-short'   -> abbreviated workspace path
;;   `decknix--header-upstream'          -> agent-shell text header
;;   `decknix--header-build'             -> joined header string
;;
;;   `decknix--header-update'            sets `header-line-format'
;;   `decknix--header-start-timer'       starts the 2-second refresh
;;   `decknix--header-stop-timer'        cancels the refresh
;;
;; Status transitions: `working|waiting -> ready' is rendered as
;; `finished' until the user returns to the buffer; once focus
;; lands the icon collapses back to plain `ready'.

;;; Code:

(require 'map)

;; -- Forward declarations ----------------------------------------

;; Upstream agent-shell / shell-maker symbols touched at runtime.
(declare-function agent-shell-workspace--buffer-status
                  "agent-shell-workspace" (buffer))
;; decknix auto-close overlay (optional; fboundp-guarded at call sites).
(declare-function decknix-agent-closing-p "decknix-agent-auto-close" (&optional buffer))
(declare-function agent-shell--make-header "agent-shell" (state))
(declare-function agent-shell--state "agent-shell")
(defvar agent-shell-header-style)
(defvar agent-shell--state)
(defvar shell-maker--busy)

;; Sibling carved modules.
(declare-function decknix--agent-tags-for-buffer
                  "decknix-agent-tags-read" (buffer))
(declare-function decknix--agent-tags-for-conv-key
                  "decknix-agent-tags-read" (conv-key))
(declare-function decknix--agent-tags-for-session
                  "decknix-agent-tags-read" (session-id))
(declare-function decknix--agent-session-current-model-id
                  "decknix-agent-session-model" ())
(declare-function decknix--agent-session-model-for-conv-key
                  "decknix-agent-session-model" (conv-key))

;; Symbols owned by main-bulk (buffer-local defvars / contextual
;; helpers).  Forward-declared as `defvar' without value so the
;; byte-compile pass resolves the reference; the actual binding
;; lives in `decknix-agent-shell-main' or in
;; `decknix-agent-shell-context' (loaded conditionally).
(defvar decknix--agent-conv-key)
(defvar decknix--agent-auggie-session-id)
(defvar decknix--agent-session-workspace)
(declare-function decknix--context-header-string
                  "decknix-agent-shell-context")

;; Focus-steal detector (optional; fboundp-guarded at the call site so
;; the header still works in isolation when `decknix-focus' is absent).
(declare-function decknix-focus-note-status "decknix-focus")

;; == Header-line state ===========================================

(defvar-local decknix--header-timer nil
  "Buffer-local timer for refreshing the header-line.")

(defvar-local decknix--header-prev-status nil
  "Previous raw status string, used to detect transitions.")

;; == Status detection + icon / face tables =======================

(defun decknix--header-detect-status ()
  "Return the current agent status as a string.
Uses agent-shell-workspace's detection when available (richer states),
otherwise falls back to shell-maker--busy.  A session counting down to
auto-close reports \"closing\" (decknix overlay) ahead of the upstream state."
  (cond
   ;; decknix overlay: a session in its auto-close countdown.
   ((and (fboundp 'decknix-agent-closing-p) (decknix-agent-closing-p))
    "closing")
   ;; Rich detection from agent-shell-workspace
   ((fboundp 'agent-shell-workspace--buffer-status)
    (agent-shell-workspace--buffer-status (current-buffer)))
   ;; Fallback: shell-maker busy flag
   ((bound-and-true-p shell-maker--busy) "working")
   ;; Check if process is alive
   ((and (get-buffer-process (current-buffer))
         (process-live-p (get-buffer-process (current-buffer))))
    "ready")
   ((not (get-buffer-process (current-buffer))) "killed")
   (t "unknown")))

(defun decknix--header-status-icon (status)
  "Return a status icon string for STATUS.
Uses the shape-family system: ○ = pre-active (initializing),
◐ = in-progress (working/waiting), ● = settled (ready/finished/killed)."
  (pcase status
    ("ready"        "●")
    ("finished"     "●")
    ("working"      "◐")
    ("waiting"      "◐")
    ("closing"      "⏻")
    ("initializing" "○")
    ("killed"       "●")
    (_              "○")))

(defun decknix--header-status-face (status)
  "Return a face for STATUS.
Colour semantics: green = good/ready, cyan = finished/transitioning,
yellow = in-progress, red = blocked/killed, grey = idle/initializing."
  (pcase status
    ("ready"        'success)
    ("finished"     '(:foreground "cyan" :weight bold))
    ("working"      'warning)
    ("waiting"      'error)
    ("closing"      '(:foreground "orange" :weight bold))
    ("initializing" 'shadow)
    ("killed"       'error)
    (_              'shadow)))

(defun decknix--header-tags ()
  "Return the tag list for the current buffer's conversation, or nil.
Fast path: uses `decknix--agent-conv-key' (set during post-create) to
look up tags directly, bypassing the session-list cache.  Falls back to
the session-id-based lookup if conv-key is not set yet."
  (or
   ;; Fast path: conv-key available (set during quickaction or
   ;; deferred prompt-ready) -- no session-list cache dependency.
   ;; One resolver rather than a second hand-rolled fallback below: this
   ;; unions the two lookups, where the `or' only takes the first hit and
   ;; so lost tags whenever a resume split them across entries.
   (decknix--agent-tags-for-buffer (current-buffer))
   ;; Slow path: look up via session-id -> session-list -> conv-key
   (when (and (boundp 'decknix--agent-auggie-session-id)
              decknix--agent-auggie-session-id)
     (decknix--agent-tags-for-session
      decknix--agent-auggie-session-id))))


(defun decknix--header-workspace-short ()
  "Return an abbreviated workspace path for the header-line."
  (when (and (boundp 'decknix--agent-session-workspace)
             decknix--agent-session-workspace
             (not (string-empty-p decknix--agent-session-workspace)))
    (abbreviate-file-name decknix--agent-session-workspace)))

;; -- Essentials block (glyph ▶ model @ workspace) ----------------

(defvar decknix--header-agent-glyph-alist
  '(("Auggie"    . "A")
    ("Claude"    . "C")
    ("Codex"     . "X")
    ("Gemini"    . "G")
    ("OpenCode"  . "O")
    ("Goose"     . "🪿")
    ("Qwen Code" . "Q"))
  "Map of agent `:buffer-name' to a glyph.
Used by `decknix--header-agent-glyph' to build the abbreviated
essentials block.  Unknown agents fall back to the uppercase first
character of the name; no agent at all defaults to \"A\" (Auggie).
Goose needs an explicit entry: its name would otherwise fall back to
\"G\" and collide with Gemini.")

(defun decknix--header-agent-glyph ()
  "Return a single-character glyph for the current buffer's agent.
Looks up the agent's `:buffer-name' from `agent-shell--state' against
`decknix--header-agent-glyph-alist'.  Falls back to the uppercase first
character of the name, or \"A\" when no state exists."
  (let* ((state (and (boundp 'agent-shell--state) agent-shell--state))
         (name  (and state
                     (ignore-errors
                       (map-nested-elt state '(:agent-config :buffer-name)))))
         (hit   (and name
                     (cdr (assoc name decknix--header-agent-glyph-alist)))))
    (cond
     (hit hit)
     ((and (stringp name) (> (length name) 0))
      (upcase (substring name 0 1)))
     (t "A"))))

(defun decknix--header-workspace-basename ()
  "Return the last path component of the current session's workspace.
Returns nil when the workspace is unset or empty.  A trailing slash on
the workspace path is stripped before the basename is extracted."
  (when (and (boundp 'decknix--agent-session-workspace)
             decknix--agent-session-workspace
             (not (string-empty-p decknix--agent-session-workspace)))
    (file-name-nondirectory
     (directory-file-name decknix--agent-session-workspace))))

(defun decknix--header-model-short ()
  "Return a short model identifier for the current conversation, or nil.
Delegates to `decknix--agent-session-model-for-conv-key' keyed by the
buffer-local `decknix--agent-conv-key'."
  (when (bound-and-true-p decknix--agent-conv-key)
    (ignore-errors
      ;; Live first: reading only the store reported what we recorded rather
      ;; than what the session is running, which went stale on a model change.
      (or (and (fboundp 'decknix--agent-session-current-model-id)
               (decknix--agent-session-current-model-id))
          (decknix--agent-session-model-for-conv-key decknix--agent-conv-key)))))

(defun decknix--header-essentials ()
  "Return the abbreviated essentials string, or nil.
Format is \"<glyph> ▶ <model> @ <workspace>\"; the `▶ <model>' and
`@ <workspace>' segments are each omitted when their underlying value
is nil.  Returns nil entirely when both model and workspace are nil so
the part can be cheaply skipped by `decknix--header-build'."
  (let ((glyph (decknix--header-agent-glyph))
        (model (decknix--header-model-short))
        (ws    (decknix--header-workspace-basename)))
    (when (or model ws)
      (propertize (concat glyph
                          (when model (concat " ▶ " model))
                          (when ws    (concat " @ " ws)))
                  'face 'font-lock-keyword-face))))

(defun decknix--header-queue-badge ()
  "Return a badge for this buffer's pending prompt queue, or nil.

The queue had no indicator at all, so a message waiting to auto-submit --
or one HELD because the session is asking you something -- was invisible.
A held queue uses the warning face: it has stopped moving and only the
user can restart it."
  (when (and (fboundp 'decknix--compose-queue-summary)
             (bound-and-true-p decknix--compose-queued-prompt))
    (let* ((held (bound-and-true-p decknix--compose-queue-held))
           (label (decknix--compose-queue-summary
                   decknix--compose-queued-prompt held)))
      (when label
        (propertize (concat "⏳ " label)
                    'face (if held 'warning 'font-lock-constant-face))))))

(defun decknix--header-parts-fit-p (parts available)
  "Non-nil when PARTS joined with the standard separator fit in AVAILABLE."
  (<= (string-width (mapconcat #'identity (delq nil parts) "  │  ")) available))

(defun decknix--header-redundant-essentials-p (essentials upstream parts available)
  "Non-nil when ESSENTIALS should be dropped as a duplicate.  Pure.

ESSENTIALS is the abbreviated `<glyph> ▶ <model> @ <workspace>' block,
UPSTREAM agent-shell's breadcrumb (nil when absent), and PARTS the full
list including it.

The block exists as a FALLBACK: when the window is too narrow for the
breadcrumb, it preserves the agent and workspace in a few characters.
When the breadcrumb IS shown it repeats what the breadcrumb already says
-- `C @ nurturecloud' beside `Claude › … › nurturecloud › …'.

Both conditions are required.  UPSTREAM must exist -- an earlier version
tested only that the parts list was non-empty, which dropped the block
even when there was no breadcrumb to replace it, losing the agent and
workspace entirely.  And the parts must FIT: upstream existing is not the
same as upstream surviving the width fit, and a narrow window is exactly
the case the block was added for.

"
  (and essentials
       upstream
       parts
       (decknix--header-parts-fit-p parts available)))

(defun decknix--header-available-width ()
  "Return the usable character width for the current buffer's header-line.
Falls back to `frame-width' when the buffer has no displayed window."
  (let ((win (get-buffer-window (current-buffer))))
    (if win (window-body-width win) (frame-width))))

(defun decknix--header-fit-parts (ordered-parts available)
  "Join ORDERED-PARTS into a string that fits within AVAILABLE characters.
ORDERED-PARTS is a list of propertized strings in descending stability
order: the first element is most stable (never dropped); the last is most
expendable (dropped first).  Parts are joined with \"  │  \".
If only the first part remains and still exceeds AVAILABLE, it is
hard-truncated at the right edge with a trailing ellipsis character (…)."
  (let ((sep "  │  ")
        (parts (copy-sequence ordered-parts)))
    (while (and (cdr parts)
                (> (string-width (mapconcat #'identity parts sep))
                   available))
      (setq parts (butlast parts)))
    (let ((joined (mapconcat #'identity parts sep)))
      (if (> (string-width joined) available)
          (truncate-string-to-width joined available 0 nil "…")
        joined))))

(defun decknix--header-upstream ()
  "Return agent-shell's text header string.
This embeds the upstream header (agent name, model, mode, workspace,
session ID, context/usage indicator, busy animation) so we inherit
any improvements to agent-shell--make-header automatically."
  (ignore-errors
    (when (fboundp 'agent-shell--make-header)
      (let ((agent-shell-header-style 'text))
        (agent-shell--make-header (agent-shell--state))))))

(defun decknix--header-build ()
  "Build the unified header-line string for the current agent-shell buffer.
Order (left to right, stable before animated):
  status icon + label  │  conversation tags  │  essentials  │  context badge  │  upstream

The `essentials' part is the abbreviated `<glyph> ▶ <model> @ <ws>'
block produced by `decknix--header-essentials'; it sits between tags
and the context badge so it survives longer than context/upstream when
the window narrows.

Parts are built in priority order — status first (never dropped), upstream
last (dropped first) — then passed to `decknix--header-fit-parts' which
iteratively removes trailing parts until the string fits the window width.
If only the status part remains and still overflows, it is hard-truncated
with an ellipsis.  This gives a graceful degradation path:
  wide:   status │ tags │ essentials │ ctx │ upstream
  medium: status │ tags │ essentials │ ctx
  narrow: status │ tags │ essentials
  tiny:   status (possibly truncated)

Note: `header-line-format' is a mode-line format spec; literal \\n in a string
renders as ^J, not a line break.  All items therefore live on one line."
  (let* ((raw-status (decknix--header-detect-status))
         ;; Track transitions: working -> ready = finished
         (status (cond
                  ((and (member decknix--header-prev-status
                                '("working" "waiting"))
                        (string= raw-status "ready"))
                   "finished")
                  (t raw-status)))
         (icon (decknix--header-status-icon status))
         (face (decknix--header-status-face status))
         (upstream (decknix--header-upstream))
         (tags (decknix--header-tags))
         (essentials (decknix--header-essentials))
         (parts nil))
    ;; Clear "finished" once user returns to the buffer
    (when (and (string= status "finished")
               (eq (current-buffer) (window-buffer (selected-window))))
      (setq status raw-status))
    ;; Update previous status for next cycle
    (when (member raw-status '("working" "waiting"))
      (setq decknix--header-prev-status raw-status))
    (when (not (member raw-status '("working" "waiting")))
      (setq decknix--header-prev-status nil))
    ;; Focus steal: when enabled, a backgrounded session entering a
    ;; needs-attention state raises the Emacs frame.  Decoupled from the
    ;; header's own prev-status tracking — `decknix-focus' keeps its own
    ;; per-buffer edge state; fboundp-guarded so the header still works
    ;; when the focus feature is absent (e.g. in isolation under test).
    (when (fboundp 'decknix-focus-note-status)
      (decknix-focus-note-status
       raw-status
       (eq (current-buffer) (window-buffer (selected-window)))))
    ;; Item 1: Status icon + label (stable, always first)
    (push (propertize (format " %s %s" icon status)
                      'face face)
          parts)
    ;; Item 2: Conversation tags (stable)
    (when tags
      (push (propertize
             (mapconcat (lambda (tg) (format "#%s" tg)) tags " ")
             'face 'font-lock-type-face)
            parts))
    ;; Item 3: Pending prompt queue (stable -- actionable, so it ranks
    ;; above the context badge and upstream when the window narrows)
    (when-let ((queue (decknix--header-queue-badge)))
      (push queue parts))
    ;; Item 4: Context panel badge (stable)
    (let* ((ctx (when (fboundp 'decknix--context-header-string)
                  (decknix--context-header-string)))
           (up (when (and upstream (not (string-empty-p upstream)))
                 (string-trim upstream)))
           (available (decknix--header-available-width))
           (tail (delq nil (list ctx up)))
           ;; Essentials ABBREVIATES the upstream breadcrumb, so it is only
           ;; worth showing when the breadcrumb will not be.
           (with-up (append (reverse parts) tail))
           (drop-essentials
            (decknix--header-redundant-essentials-p
             essentials up with-up available)))
      (decknix--header-fit-parts
       (if drop-essentials
           with-up
         (append (reverse (if essentials (cons essentials parts) parts)) tail))
       available))))

(defun decknix--header-update ()
  "Update the header-line-format for the current agent-shell buffer.
Skips the update when input is pending so the 2-second repeating
timer (one per live buffer) does not block the user while typing.
The header catches up on the next tick.

Redisplay perf: also skips buffers not shown in any window (refreshing
an offscreen header helps no one and still dirties it), and only calls
`force-mode-line-update' when the freshly built header actually differs
from what is displayed — so a steady-state (non-animating) session no
longer forces a window relayout every tick.  This is the difference
between one `force-mode-line-update' per *visible, changed* buffer and
one per *live* buffer every 2 s, which CPU sampling showed re-paying
the full bidi/interval relayout cost across all sessions."
  (unless (input-pending-p)
    (when (and (derived-mode-p 'agent-shell-mode)
               (get-buffer-window (current-buffer) t))
      (let ((new (list (decknix--header-build))))
        (unless (equal new header-line-format)
          (setq-local header-line-format new)
          (force-mode-line-update))))))

;; ---------------------------------------------------------------------------
;; Project-name cache
;; ---------------------------------------------------------------------------

(defvar-local decknix--header-project-name-cache nil
  "Cons of (DIRECTORY . NAME) for this buffer's cached project name.
A cons rather than a bare name so a nil NAME is still a cache HIT --
a directory outside any project is precisely the case that pays the
full filesystem walk, so re-running it every tick is the worst version
of the problem.")

(defun decknix--header-project-name-advice (orig &rest args)
  "Around-advice for `agent-shell--project-name': cache per directory.

Upstream calls `project-current', which walks the filesystem
\(`locate-dominating-file' / `directory-files' / `vc-file-getprop').
That sits on the header render path, so it ran for every visible agent
buffer every 2 seconds; CPU sampling attributed ~6% of the daemon to it.

The answer depends only on `default-directory', so it is cached against
it and recomputed when that changes -- a stale project name would be
worse than the cost it saves, since the header would name the wrong
project."
  (if (and (consp decknix--header-project-name-cache)
           (equal (car decknix--header-project-name-cache) default-directory))
      (cdr decknix--header-project-name-cache)
    (let ((name (apply orig args)))
      (setq decknix--header-project-name-cache (cons default-directory name))
      name)))

;; ---------------------------------------------------------------------------
;; Header refresh timer
;; ---------------------------------------------------------------------------

(defcustom decknix-header-refresh-interval 2
  "Seconds between header-line refreshes.
One shared timer serves every visible agent buffer; see
`decknix--header-tick-all'."
  :type 'number :group 'decknix)

(defvar decknix--header-shared-timer nil
  "The single header-refresh timer, or nil when not armed.")

(defun decknix--header-dedupe-agent-buffers (buffers)
  "Return the distinct live agent-shell buffers in BUFFERS, order preserved.

Carved out for ERT: the live caller maps `window-buffer' over every
window on every frame, and the same buffer shown in two windows must be
refreshed ONCE -- the whole point of the shared timer is to make the
work proportional to what is on screen, not to how it is arranged."
  (let (seen)
    (dolist (buf buffers)
      (when (and (buffer-live-p buf)
                 (not (memq buf seen))
                 (with-current-buffer buf (derived-mode-p 'agent-shell-mode)))
        (push buf seen)))
    (nreverse seen)))

(defun decknix--header-visible-agent-buffers ()
  "Return the distinct live agent-shell buffers currently on screen."
  (decknix--header-dedupe-agent-buffers
   (mapcar #'window-buffer
           (apply #'append
                  (mapcar (lambda (f) (window-list f 'no-mini)) (frame-list))))))

(defun decknix--header-tick-all ()
  "Refresh the header of every VISIBLE agent-shell buffer.

Replaces the per-buffer timer this module used to start (#148).  With 17
live sessions that meant 17 independent 2-second timers -- ~9 firings a
second, and the hitch profiler recorded 282 of them blocking for a
combined 134 seconds, several over 7s.  Each fired regardless of whether
its buffer was on screen, so the cost scaled with sessions ever opened
rather than with what is actually being looked at.

One timer, driven from the window list, scales with the latter: a
20-session day with two visible splits does two refreshes per tick.
Bails early while input is pending so it never blocks typing -- the
profiler caught `self-insert-command' stalling 2.3s."
  (unless (input-pending-p)
    (dolist (buf (decknix--header-visible-agent-buffers))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (ignore-errors (decknix--header-update)))))))

(defcustom decknix-header-event-throttle 0.3
  "Minimum seconds between header refreshes driven by agent events.

Bounds the EVENT path (`agent-shell--update-header-and-mode-line', which
upstream calls per streamed notification), not the shared timer.  A turn
streaming hundreds of chunks would otherwise rebuild the header hundreds
of times, each rebuild forcing a redisplay -- and, because the tab-bar
keymap is uncached, a tab-bar rebuild with it.

Small enough that a status transition still looks instant; the shared
timer bounds worst-case staleness at
`decknix-header-refresh-interval' regardless."
  :type 'number :group 'decknix)

(defvar-local decknix--header-last-event-update 0.0
  "`float-time' of this buffer's last event-driven header refresh.
Buffer-local so a session streaming flat out cannot starve the header of
a different session that just changed status.")

(defun decknix--header-update-throttled ()
  "Refresh the header from the high-frequency agent-event path.

Collapses a burst of streamed chunks into at most one refresh per
`decknix-header-event-throttle' seconds.  Anything suppressed here is
picked up by the shared timer within
`decknix-header-refresh-interval', so no state is lost -- only the
redundant rebuilds are."
  (let ((now (float-time)))
    (when (>= (- now decknix--header-last-event-update)
              decknix-header-event-throttle)
      (setq decknix--header-last-event-update now)
      (decknix--header-update))))

(defun decknix--header-start-shared-timer ()
  "Arm the single shared header-refresh timer (idempotent)."
  (when (timerp decknix--header-shared-timer)
    (cancel-timer decknix--header-shared-timer))
  (setq decknix--header-shared-timer
        (run-with-timer decknix-header-refresh-interval
                        decknix-header-refresh-interval
                        #'decknix--header-tick-all)))

(defun decknix--header-start-timer ()
  "Ensure header refreshing is running for this buffer.

Kept as the per-buffer entry point the shell-creation path already
calls, but it no longer starts a per-buffer timer: it arms the single
shared one (idempotent) and cancels any legacy timer this buffer still
owns, so a daemon carrying pre-existing buffers converges onto the
shared timer instead of running both."
  (decknix--header-stop-timer)
  (unless (timerp decknix--header-shared-timer)
    (decknix--header-start-shared-timer)))

(defun decknix--header-stop-timer ()
  "Stop this buffer's legacy per-buffer header timer, if any."
  (when decknix--header-timer
    (cancel-timer decknix--header-timer)
    (setq decknix--header-timer nil)))

(provide 'decknix-agent-header)
;;; decknix-agent-header.el ends here
