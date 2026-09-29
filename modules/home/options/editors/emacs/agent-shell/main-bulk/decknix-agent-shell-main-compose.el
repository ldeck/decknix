;;; decknix-agent-shell-main-compose.el --- Compose buffer + history + queue -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix

;;; Commentary:
;;
;; Compose buffer for agent-shell prompts (magit-style multi-line
;; editor) with history navigation, prompt queue, parent-buffer
;; forwarding commands, and the interrupt sub-keymap.
;;
;; PR Split.S.3: split out of `decknix-agent-shell-main' so the
;; ~3260-line bulk file can be navigated by theme.  Co-resident
;; with the main file in `main-bulk/'.  The pure history layer
;; (`decknix-agent-compose-history'), busy-prompt dispatch
;; (`decknix-agent-compose-busy'), queue resolver
;; (`decknix-agent-compose-queue'), header-line builder
;; (`decknix-agent-compose-header'), find-target / completion
;; helpers (`decknix-agent-compose-internals') and prompt-search
;; cache (`decknix-agent-prompt-search-cache') all live in their
;; own carved + ERT-tested packages.  This file owns the
;; side-effecting orchestration: the minor mode, the buffer-local
;; state, the interactive entry points, and the timer/comint
;; adapters.  Side-effecting `(define-key)' bindings into the
;; heredoc's prefix maps still happen in the heredoc itself
;; (per AGENTS.md Rule 2).

;;; Code:

(declare-function decknix--compose-submit-ok-p
                  "decknix-agent-compose-wait" (buffer-live process-live busy))

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

;; Forward declarations for symbols defined in carved compose/
;; packages, in `decknix-agent-shell-main', or in external Emacs
;; modules.  Resolved at runtime via the heredoc's `(require)'
;; chain in `default.el'.
(declare-function yas-minor-mode "ext:yasnippet")
(declare-function yas-activate-extra-mode "ext:yasnippet")
(declare-function consult--read "ext:consult")
(declare-function shell-maker-submit "ext:shell-maker")
(declare-function shell-maker--busy "ext:shell-maker")
(declare-function agent-shell-interrupt "ext:agent-shell")
(declare-function agent-shell-attention-jump "ext:agent-shell")
(declare-function agent-shell-workspace-toggle
                  "ext:agent-shell-workspace")
(declare-function decknix-context-toggle-or-panel
                  "ext:decknix-agent-shell-context")

;; -- Carved compose/ helpers --
(declare-function decknix--compose-history-init
                  "decknix-agent-compose-history")
(declare-function decknix--compose-history-navigate-previous
                  "decknix-agent-compose-history")
(declare-function decknix--compose-history-navigate-next
                  "decknix-agent-compose-history")
(declare-function decknix--compose-history-reset
                  "decknix-agent-compose-history")
(declare-function decknix--compose-busy-action
                  "decknix-agent-compose-busy" (busy-p))
(declare-function decknix--compose-queue-action
                  "decknix-agent-compose-queue"
                  (queued-prompt buffer-live busy proc-live &optional status))
(declare-function decknix--compose-queue-normalise
                  "decknix-agent-compose-queue" (queue))
(declare-function decknix--compose-queue-append
                  "decknix-agent-compose-queue" (queue input))
(declare-function decknix--compose-queue-drop
                  "decknix-agent-compose-queue" (queue index))
(declare-function decknix--compose-queue-combine
                  "decknix-agent-compose-queue" (queue &optional separator))
(declare-function decknix--compose-queue-summary
                  "decknix-agent-compose-queue" (queue &optional held-reason))
(declare-function decknix--compose-queue-entry-label
                  "decknix-agent-compose-queue" (input index &optional width))
(declare-function decknix--compose-queue-drain-text
                  "decknix-agent-compose-queue" (queue))
(declare-function decknix--compose-queue-split-text
                  "decknix-agent-compose-queue" (text))
(declare-function decknix--compose-queue-enqueue-action
                  "decknix-agent-compose-queue" (queued-count))
(declare-function decknix--compose-queue-interrupt-action
                  "decknix-agent-compose-queue" (queued-count))
(declare-function decknix--header-detect-status "decknix-agent-header" ())
(declare-function decknix--compose-wait-not-busy
                  "decknix-agent-compose-wait"
                  (target on-ready &optional timeout interval))
(declare-function decknix--compose-build-header-line
                  "decknix-agent-compose-header" (sticky))
(declare-function decknix--compose-find-target
                  "decknix-agent-compose-internals")
(declare-function decknix--compose-display-action
                  "decknix-agent-compose-internals")
(declare-function decknix--compose-command-completion-at-point
                  "decknix-agent-compose-internals")
(declare-function decknix--compose-file-completion-at-point
                  "decknix-agent-compose-internals")
(declare-function decknix--compose-trigger-completion
                  "decknix-agent-compose-internals")
(declare-function decknix--compose-setup-completion
                  "decknix-agent-compose-internals")
(declare-function decknix--prompt-extract-ensure-jq-filter
                  "decknix-agent-prompt-extract")
(declare-function decknix--prompt-extract-from-file
                  "decknix-agent-prompt-extract" (file))
(declare-function decknix--prompt-search-jq-cmd
                  "decknix-agent-prompt-search")
(declare-function decknix--prompt-search-refresh-sync
                  "decknix-agent-prompt-search-cache")
(declare-function decknix--prompt-search-refresh-async
                  "decknix-agent-prompt-search-cache")
(declare-function decknix--prompt-search-get
                  "decknix-agent-prompt-search-cache")
(declare-function decknix--prompt-truncate-for-display
                  "decknix-agent-format" (s width))

;; -- Symbols owned by decknix-agent-shell-main proper --
(declare-function decknix-session-picker
                  "decknix-agent-shell-main")
(declare-function decknix-session-tags-show
                  "decknix-agent-shell-main")

;; Forward defvars for heredoc-resident state and carved/external
;; configs.
(defvar decknix--compose-history-local-only)
(defvar decknix--compose-history-seen)
(defvar decknix--prompt-search-cache)
(defvar decknix--prompt-search-cache-time)
(defvar decknix--prompt-search-cache-ttl)
(defvar decknix--prompt-search-refresh-proc)
(defvar agent-shell-confirm-interrupt)


;; -- Buffer-local state --

(defvar-local decknix--compose-target-buffer nil
  "The agent-shell buffer to submit the composed prompt to.")

;; PR B.75: the seven `defvar-local' history-state vars and the
;; init/load-next-batch/navigate-{previous,next}/reset helpers were
;; carved into `decknix-agent-compose-history' (`agent-shell/
;; compose-history/').  The interactive M-p/M-n/M-P/M-N entry points
;; below stay here per AGENTS.md Rule 2; they flip the local-only
;; flag and dispatch to the carved navigate-{previous,next}
;; backends.

(defun decknix-agent-compose-previous-input ()
  "Cycle to the previous prompt from the CURRENT session only.
Use M-P for cross-session history."
  (interactive)
  (when (not decknix--compose-history-local-only)
    ;; Switching from global → local: reset to rebuild
    (setq decknix--compose-history-local-only t
          decknix--compose-history-seen nil))
  (decknix--compose-history-navigate-previous))

(defun decknix-agent-compose-next-input ()
  "Cycle to the next (newer) prompt from the CURRENT session only.
Use M-N for cross-session history."
  (interactive)
  (decknix--compose-history-navigate-next))

(defun decknix-agent-compose-previous-input-global ()
  "Cycle to the previous prompt across ALL sessions.
Starts with the current session, then streams from saved sessions on-demand."
  (interactive)
  (when decknix--compose-history-local-only
    ;; Switching from local → global: reset to rebuild with file queue
    (setq decknix--compose-history-local-only nil
          decknix--compose-history-seen nil))
  (decknix--compose-history-navigate-previous))

(defun decknix-agent-compose-next-input-global ()
  "Cycle to the next (newer) prompt across ALL sessions."
  (interactive)
  (decknix--compose-history-navigate-next))

;; == Consult-based prompt search (M-r) ==
;;
;; PR B.72: cache layer (defvars + `-refresh-sync' / `-refresh-async'
;; / `-get') was carved into `decknix-agent-prompt-search-cache'.
;; The interactive `decknix-agent-compose-search-history' stays
;; here per AGENTS.md Rule 2 -- it consults via `consult--read'
;; and mutates the compose buffer.

(defun decknix-agent-compose-search-history ()
  "Search prompt history using consult with fuzzy matching.
Selected prompt replaces the compose buffer content.
Works in both compose buffers and agent-shell buffers."
  (interactive)
  (require 'consult)
  (let* ((all-prompts (decknix--prompt-search-get))
         ;; Build candidates: truncated display → full prompt
         (candidates
          (mapcar (lambda (p)
                    (cons (decknix--prompt-truncate-for-display p 120) p))
                  all-prompts))
         (selected
          (consult--read
           (mapcar #'car candidates)
           :prompt "Search prompts: "
           :sort nil
           :require-match t
           :category 'decknix-prompt
           :history 'decknix--prompt-search-minibuffer-history))
         (full-prompt (cdr (assoc selected candidates))))
    (when full-prompt
      ;; Insert into compose buffer or show in message
      (if (bound-and-true-p decknix-agent-compose-mode)
          (progn
            (erase-buffer)
            (insert full-prompt)
            (goto-char (point-max))
            ;; Reset M-p/M-n state since we jumped
            (decknix--compose-history-reset))
        ;; In agent-shell buffer: open compose with this prompt
        (let ((target (current-buffer)))
          (decknix--compose-get-or-create target)
          (erase-buffer)
          (insert full-prompt)
          (goto-char (point-max)))))))

(defvar decknix--prompt-search-minibuffer-history nil
  "Minibuffer history for prompt search.")

(defcustom decknix-agent-compose-sticky nil
  "When non-nil, the compose editor stays open after submit/cancel.
Toggle with \\[decknix-agent-compose-toggle-sticky] in the compose buffer."
  :type 'boolean
  :group 'decknix)

(defvar-local decknix--compose-sticky nil
  "Buffer-local sticky state for this compose buffer.")

(defvar decknix-agent-compose-interrupt-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "k") #'decknix-agent-compose-interrupt-agent)
    (define-key map (kbd "C-c") #'decknix-agent-compose-interrupt-and-submit)
    map)
  "Sub-keymap under C-c k in compose mode.
\\`k' interrupts the agent, \\`C-c' interrupts and submits.")

;; -- Compose → parent buffer forwarding commands --
;; These let you invoke parent agent-shell commands without
;; closing the compose window first.

(defun decknix-compose--forward-to-parent (cmd)
  "Run CMD interactively in the compose target (parent) buffer."
  (when-let ((target (and (boundp 'decknix--compose-target-buffer)
                          decknix--compose-target-buffer))
             ((buffer-live-p target)))
    (with-current-buffer target
      (call-interactively cmd))))

(defun decknix-compose-jump ()
  "Jump to next pending session (forwarded to parent)."
  (interactive)
  (if (fboundp 'agent-shell-attention-jump)
      (call-interactively 'agent-shell-attention-jump)
    (message "agent-shell-attention not loaded")))

(defun decknix-compose-workspace-toggle ()
  "Toggle Agents workspace from a compose buffer.
Hide the compose side-window first so the tab switch happens
cleanly (side-windows persist across tab switches and corrupt the
layout otherwise).  The compose buffer itself is buried, not killed,
so any in-flight prompt text is preserved and restored the next time
the user opens compose (`C-c e') against the same target.  Focus
returns to the agent buffer before the toggle."
  (interactive)
  (if (fboundp 'agent-shell-workspace-toggle)
      (let ((target decknix--compose-target-buffer)
            (compose-win (selected-window)))
        ;; Hide the compose side-window but keep the buffer alive
        ;; so the user's partially-typed prompt survives the toggle.
        (quit-restore-window compose-win 'bury)
        ;; Move focus to the target agent buffer if it's visible
        (when (and target (buffer-live-p target))
          (let ((target-win (get-buffer-window target)))
            (when (and target-win (window-live-p target-win))
              (select-window target-win))))
        ;; Now toggle tabs cleanly
        (call-interactively 'agent-shell-workspace-toggle))
    (message "agent-shell-workspace not loaded")))

(defun decknix-compose-session-picker ()
  "Open session picker (forwarded to parent)."
  (interactive)
  (decknix-compose--forward-to-parent 'decknix-session-picker))

(defun decknix-compose-context-panel ()
  "Toggle context or open panel (forwarded to parent).
Without prefix, toggle inline header. With prefix, open side panel."
  (interactive)
  (when (fboundp 'decknix-context-toggle-or-panel)
    (decknix-compose--forward-to-parent
     'decknix-context-toggle-or-panel)))

(defun decknix-compose-tags ()
  "Show session tags (forwarded to parent)."
  (interactive)
  (when (fboundp 'decknix-session-tags-show)
    (decknix-compose--forward-to-parent 'decknix-session-tags-show)))

(defvar decknix-agent-queue-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "s") #'decknix-agent-queue-show)
    (define-key map (kbd "d") #'decknix-agent-queue-drop)
    (define-key map (kbd "k") #'decknix-agent-queue-clear)
    (define-key map (kbd "j") #'decknix-agent-queue-combine)
    (define-key map (kbd "e") #'decknix-agent-queue-edit)
    (define-key map (kbd "f") #'decknix-agent-queue-flush)
    map)
  "Queue commands, bound under \`C-c q' in compose mode and \`C-c A Q'
in an agent-shell buffer (\`C-c A q' is session-quit).
\`s' show, \`d' drop one, \`k' clear, \`j' join into one turn,
\`e' edit (drain into compose; \`C-u' for one entry),
\`f' flush (release a held queue, or interrupt a busy agent).")

(defvar decknix-agent-compose-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'decknix-agent-compose-submit)
    (define-key map (kbd "C-c C-k") #'decknix-agent-compose-cancel)
    (define-key map (kbd "C-c C-q") #'decknix-agent-compose-close)
    (define-key map (kbd "C-c C-s") #'decknix-agent-compose-toggle-sticky)
    (define-key map (kbd "C-c k") decknix-agent-compose-interrupt-map)
    (define-key map (kbd "C-c q") decknix-agent-queue-map)
    (define-key map (kbd "M-p") #'decknix-agent-compose-previous-input)
    (define-key map (kbd "M-n") #'decknix-agent-compose-next-input)
    (define-key map (kbd "M-P") #'decknix-agent-compose-previous-input-global)
    (define-key map (kbd "M-N") #'decknix-agent-compose-next-input-global)
    (define-key map (kbd "M-r") #'decknix-agent-compose-search-history)
    ;; Forward parent buffer commands
    (define-key map (kbd "C-c j") #'decknix-compose-jump)
    (define-key map (kbd "C-c w") #'decknix-compose-workspace-toggle)
    (define-key map (kbd "C-c s") #'decknix-compose-session-picker)
    (define-key map (kbd "C-c i") #'decknix-compose-context-panel)
    (define-key map (kbd "C-c T") #'decknix-compose-tags)
    map)
  "Keymap for `decknix-agent-compose-mode'.")

(define-minor-mode decknix-agent-compose-mode
  "Minor mode for composing agent-shell prompts.
\\<decknix-agent-compose-mode-map>
\\[decknix-agent-compose-submit] submit, \
\\[decknix-agent-compose-cancel] cancel/clear, \
\\[decknix-agent-compose-close] close, \
\\[decknix-agent-compose-toggle-sticky] toggle sticky.
C-c k k interrupt agent, C-c k C-c interrupt & submit."
  :lighter (:eval (if decknix--compose-sticky " Compose[sticky]" " Compose"))
  :keymap decknix-agent-compose-mode-map)


(defun decknix--compose-finish ()
  "Finish a compose action: clear if sticky, close if transient.
Resets prompt history navigation state."
  ;; Reset all history navigation state (rebuilt on next M-p)
  (decknix--compose-history-reset)
  ;; A sticky buffer survives the submit, so leaving this set would split
  ;; every later prompt that happened to contain a `---' line.
  (setq-local decknix--compose-drained nil)
  (if decknix--compose-sticky
      (progn
        (erase-buffer)
        (set-buffer-modified-p nil))
    (let ((win (selected-window)))
      (quit-restore-window win 'kill))))

;; -- Prompt queue: auto-submit when agent becomes idle --
(defvar-local decknix--compose-queued-prompt nil
  "Pending prompts queued for submission when the agent is idle.
A list, submitted one turn at a time in order.  Buffer-local on
agent-shell buffers.  Was a single string, which made a second queued
message overwrite the first; see `decknix-agent-compose-queue'.")

(defvar-local decknix--compose-queue-timer nil
  "Timer polling `shell-maker--busy' to submit a queued prompt.
Buffer-local on agent-shell buffers.")

(defvar-local decknix--compose-queue-held nil
  "Blocking status the queue is currently held on, or nil.
Set so the hold is announced once rather than on every poll tick.")

(defvar-local decknix--compose-queue-release nil
  "When non-nil, submit the queue even though the session wants the user.
Consumed by the next successful submit, so releasing is a one-shot
decision rather than a mode that silently disables the gate.")

(defun decknix--compose-queue-status ()
  "Return the current buffer's session status string, or nil.
Absent the status detector the queue keeps its old behaviour of
submitting whenever idle, rather than stalling on an unknown."
  (and (fboundp 'decknix--header-detect-status)
       (ignore-errors (decknix--header-detect-status))))

(defun decknix--compose-queue-cancel-timer ()
  "Stop this buffer's queue poller."
  (when decknix--compose-queue-timer
    (cancel-timer decknix--compose-queue-timer)
    (setq decknix--compose-queue-timer nil)))

(defun decknix--compose-queue-poll ()
  "Submit the head of the queue when the agent is idle and not asking.
Called by a repeating timer on the agent-shell buffer.  The
cancel/submit/wait/hold decision is pinned by
`decknix-agent-compose-queue'; this is the comint-side adapter."
  (let* ((buf (current-buffer))
         (proc (and (buffer-live-p buf) (get-buffer-process buf)))
         (action (decknix--compose-queue-action
                  decknix--compose-queued-prompt
                  (buffer-live-p buf)
                  (bound-and-true-p shell-maker--busy)
                  (and proc (process-live-p proc))
                  (unless decknix--compose-queue-release
                    (decknix--compose-queue-status)))))
    (pcase (plist-get action :action)
      ('cancel-timer (decknix--compose-queue-cancel-timer))
      ('hold
       (let ((reason (plist-get action :reason)))
         (unless (equal decknix--compose-queue-held reason)
           (setq decknix--compose-queue-held reason)
           (message
            "%s: %s held -- session is %s.  Answer it, or C-c A Q f to release."
            (buffer-name buf)
            (decknix--compose-queue-summary decknix--compose-queued-prompt)
            reason))))
      ('submit
       (let ((input (plist-get action :input))
             (rest (plist-get action :rest)))
         (setq decknix--compose-queued-prompt rest
               decknix--compose-queue-held nil
               decknix--compose-queue-release nil)
         ;; Keep polling while anything remains: the timer used to be
         ;; cancelled on every submit, which with a list would strand the
         ;; tail unsent.
         (unless rest (decknix--compose-queue-cancel-timer))
         (goto-char (point-max))
         (shell-maker-submit :input input)
         (message "Queued prompt submitted%s"
                  (if rest (format " (%d still queued)" (length rest)) ""))))
      ('wait
       (setq decknix--compose-queue-held nil)))))

(defun decknix--compose-queue-count (target)
  "Return how many prompts are queued on TARGET."
  (if (buffer-live-p target)
      (with-current-buffer target
        (length (decknix--compose-queue-normalise
                 decknix--compose-queued-prompt)))
    0))

(defun decknix--compose-enqueue-prompt (target input &optional mode)
  "Add INPUT to TARGET buffer's queue, for submission when the agent is idle.

INPUT may be a string or a list of turns (a drained document split back on
its boundary rules).  MODE is `append' (default), `replace' or `combine',
as resolved by `decknix--compose-queue-enqueue-action'.  Returns the new
queue length, or nil when nothing was queued."
  (when (buffer-live-p target)
    (with-current-buffer target
      (let ((incoming (if (listp input) input (list input))))
        (setq decknix--compose-queued-prompt
              (pcase mode
                ('replace incoming)
                ('combine
                 (list (decknix--compose-queue-combine
                        (append (decknix--compose-queue-normalise
                                 decknix--compose-queued-prompt)
                                incoming))))
                (_ (seq-reduce #'decknix--compose-queue-append
                               incoming
                               decknix--compose-queued-prompt)))))
      ;; Start a polling timer (every 1s) if not already running
      (unless (and decknix--compose-queue-timer
                  (memq decknix--compose-queue-timer timer-list))
        (setq decknix--compose-queue-timer
              (run-at-time
               1.0 1.0
               (eval `(lambda ()
                        (when (buffer-live-p ,target)
                          (with-current-buffer ,target
                            (decknix--compose-queue-poll))))
                     t))))
      (length (decknix--compose-queue-normalise
               decknix--compose-queued-prompt)))))

;; -- Queue inspection and control --
;;
;; The queue had no user-facing surface at all: nothing to see it, drop it,
;; edit it or send it early, so the only way out of a queued message was to
;; kill the buffer.

(defun decknix--compose-queue-buffer ()
  "Return the agent-shell buffer whose queue the current buffer commands.
The compose buffer acts on its target; an agent-shell buffer on itself."
  (or (and (boundp 'decknix--compose-target-buffer)
           decknix--compose-target-buffer
           (buffer-live-p decknix--compose-target-buffer)
           decknix--compose-target-buffer)
      (current-buffer)))

(defmacro decknix--with-compose-queue-buffer (&rest body)
  "Run BODY in the buffer owning the queue this command addresses."
  (declare (indent 0) (debug t))
  `(let ((buf (decknix--compose-queue-buffer)))
     (when (buffer-live-p buf)
       (with-current-buffer buf ,@body))))

(defun decknix-agent-queue-show ()
  "Report the pending prompt queue for this session."
  (interactive)
  (decknix--with-compose-queue-buffer
    (let ((pending (decknix--compose-queue-normalise
                    decknix--compose-queued-prompt)))
      (if (null pending)
          (message "Nothing queued")
        (message "%s\n%s"
                 (decknix--compose-queue-summary
                  pending decknix--compose-queue-held)
                 (mapconcat #'identity
                            (seq-map-indexed
                             (lambda (input i)
                               (decknix--compose-queue-entry-label input i))
                             pending)
                            "\n"))))))

(defun decknix-agent-queue-drop ()
  "Drop one pending prompt from this session's queue."
  (interactive)
  (decknix--with-compose-queue-buffer
    (let ((pending (decknix--compose-queue-normalise
                    decknix--compose-queued-prompt)))
      (if (null pending)
          (message "Nothing queued")
        (let* ((labels (seq-map-indexed
                        (lambda (input i)
                          (decknix--compose-queue-entry-label input i))
                        pending))
               (choice (completing-read "Drop queued prompt: " labels nil t))
               (index (seq-position labels choice)))
          (setq decknix--compose-queued-prompt
                (decknix--compose-queue-drop pending index))
          (unless decknix--compose-queued-prompt
            (decknix--compose-queue-cancel-timer))
          (message "Dropped. %s"
                   (or (decknix--compose-queue-summary
                        decknix--compose-queued-prompt
                        decknix--compose-queue-held)
                       "Queue empty")))))))

(defun decknix-agent-queue-clear ()
  "Drop every pending prompt from this session's queue."
  (interactive)
  (decknix--with-compose-queue-buffer
    (let ((n (length (decknix--compose-queue-normalise
                      decknix--compose-queued-prompt))))
      (if (zerop n)
          (message "Nothing queued")
        (when (yes-or-no-p (format "Drop %d queued prompt%s? "
                                   n (if (= n 1) "" "s")))
          (setq decknix--compose-queued-prompt nil
                decknix--compose-queue-held nil
                decknix--compose-queue-release nil)
          (decknix--compose-queue-cancel-timer)
          (message "Queue cleared"))))))

(defun decknix-agent-queue-combine ()
  "Collapse this session's queue into a single pending prompt.
Separate turns are the default because merging two asks changes what was
asked; this is the explicit opt-in to one turn."
  (interactive)
  (decknix--with-compose-queue-buffer
    (let ((pending (decknix--compose-queue-normalise
                    decknix--compose-queued-prompt)))
      (cond
       ((< (length pending) 2)
        (message "Nothing to combine"))
       (t
        (setq decknix--compose-queued-prompt
              (list (decknix--compose-queue-combine pending)))
        (message "Combined %d prompts into one turn" (length pending)))))))

(defvar-local decknix--compose-drained nil
  "Non-nil when this compose buffer was filled by draining the queue.

Gates boundary splitting on submit.  Splitting every buffer containing a
`---' line would turn an ordinary prompt that happens to use a markdown
rule into several turns, so only a buffer we ourselves drained is split.")

(defun decknix--compose-submit-turns (input)
  "Return INPUT as the list of turns to queue.

One turn normally.  A drained buffer is split back on its boundary rules,
so editing N queued messages and re-queueing gives N turns again rather
than collapsing them into one."
  (if decknix--compose-drained
      (or (decknix--compose-queue-split-text input) (list input))
    (list input)))

(defun decknix-agent-queue-edit (&optional one)
  "Drain this session's queue into a compose buffer for editing.

Turns are separated by a `---' rule, which is a real boundary: submitting
or re-queueing splits on it, so N edited messages go back as N turns.  The
queue is emptied first -- what is in the compose buffer IS the queue now,
and leaving a copy behind would double-send it.

With prefix argument ONE, pick a single entry instead of draining all."
  (interactive "P")
  (let ((target (decknix--compose-queue-buffer)))
    (unless (buffer-live-p target)
      (user-error "No session for this queue"))
    (let ((pending (with-current-buffer target
                     (decknix--compose-queue-normalise
                      decknix--compose-queued-prompt))))
      (unless pending
        (user-error "Nothing queued"))
      (let* ((labels (seq-map-indexed
                      (lambda (in i) (decknix--compose-queue-entry-label in i))
                      pending))
             (index (when one
                      (seq-position
                       labels
                       (completing-read "Edit queued prompt: " labels nil t))))
             (taken (if index (list (nth index pending)) pending))
             (text (decknix--compose-queue-drain-text taken)))
        (with-current-buffer target
          (setq decknix--compose-queued-prompt
                (if index
                    (decknix--compose-queue-drop pending index)
                  nil)
                decknix--compose-queue-held nil)
          (unless decknix--compose-queued-prompt
            (decknix--compose-queue-cancel-timer)))
        (let ((compose (decknix--compose-get-or-create target)))
          (with-current-buffer compose
            (erase-buffer)
            (insert text)
            (setq-local decknix--compose-drained t)
            (goto-char (point-min)))
          (message "%d turn%s drained for editing -- C-c C-c to re-queue"
                   (length taken) (if (= 1 (length taken)) "" "s"))
          compose)))))

(defun decknix-agent-queue-flush ()
  "Release a held queue, or interrupt a busy agent to send it now.

Releasing is one-shot: it clears the question gate for the next submit
only, so a later question stops the queue again rather than the gate
staying off."
  (interactive)
  (decknix--with-compose-queue-buffer
    (cond
     ((null (decknix--compose-queue-normalise decknix--compose-queued-prompt))
      (message "Nothing queued"))
     ((bound-and-true-p shell-maker--busy)
      (when (yes-or-no-p "Agent is busy.  Interrupt and send the queue? ")
        (setq decknix--compose-queue-release t)
        (when (fboundp 'agent-shell-interrupt)
          (let ((agent-shell-confirm-interrupt nil))
            (agent-shell-interrupt)))
        (message "Interrupted; queue will send when the turn settles")))
     (t
      (setq decknix--compose-queue-release t
            decknix--compose-queue-held nil)
      (decknix--compose-queue-poll)))))

(defun decknix--compose-submit-after-wait (target input)
  "Submit INPUT to TARGET after the wait-not-busy coordination.

Returns non-nil ONLY when the input was actually sent, so the caller can
tell a real submit from a refused one and decide whether to consume the
compose buffer.

Returns nil -- silently -- when TARGET is dead, its process has gone, or
it is STILL BUSY.  The busy case is the one that bit: the wait fires on a
budget as well as on the flag clearing, so an un-acked interrupt still
reaches here, the send is refused downstream, and the compose buffer used
to be closed regardless.  A user-error from a timer callback would be
noisy, hence a return value rather than a signal."
  (let* ((live (buffer-live-p target))
         (proc (and live (get-buffer-process target)))
         (proc-live (and proc (process-live-p proc)))
         (busy (and live (with-current-buffer target
                           (bound-and-true-p shell-maker--busy)))))
    (when (decknix--compose-submit-ok-p live proc-live busy)
      (with-current-buffer target
        (goto-char (point-max))
        (shell-maker-submit :input input))
      t)))

(defun decknix--compose-stash-input (input)
  "Save INPUT to the kill-ring so a broken submit never loses the text.
Called from every path that consumes the compose buffer (submit / queue /
interrupt-and-submit); a no-op for blank INPUT.  With
`select-enable-clipboard' (the default) this also reaches the system
clipboard, so the text is recoverable even if the agent send errors out."
  (when (and (stringp input) (not (string-empty-p (string-trim input))))
    (kill-new input)))

(defun decknix-agent-compose-submit ()
  "Submit the compose buffer content to the agent-shell.
If the agent is busy, offers three options:
  - Interrupt and submit immediately
  - Queue the prompt (auto-submitted when agent becomes idle)
  - Cancel
Use C-c k k to pre-emptively interrupt, then C-c C-c to submit cleanly.

The busy-prompt dispatch lives in `decknix--compose-busy-action'
(carved package, `agent-shell/compose/'); this handler `pcase'-es
over the returned action symbol rather than `cl-return-from'-ing
out of nested branches, which both removes the
`No catch for tag: --cl-block-...' bug class and pins the
dispatch table under ERT.

The `interrupt-submit' branch waits on the agent's interrupt
acknowledgement (via `decknix--compose-wait-not-busy') before
calling `shell-maker-submit', so the new prompt lands AFTER the
\"[interrupted]\" marker in the buffer.  The previous fixed
`sit-for 0.3' lost the race when the ack took longer than the
budget and the new prompt was visually ordered before the
interrupt."
  (interactive)
  (let* ((input (string-trim (buffer-string)))
         (target decknix--compose-target-buffer))
    (cond
     ((string-empty-p input)
      (user-error "Empty prompt — nothing to submit"))
     (t
      ;; Safety net: stash the composed text the instant we commit to
      ;; submit/queue, so a broken send (or a cancelled busy prompt) can
      ;; never lose what the user typed.
      (decknix--compose-stash-input input)
      (let* ((busy-p (and (buffer-live-p target)
                          (with-current-buffer target
                            (bound-and-true-p shell-maker--busy))))
             (action (decknix--compose-busy-action busy-p)))
        (pcase action
          ('cancel
           (user-error "Submit cancelled — agent is still processing"))
          ('queue
           (let* ((turns (decknix--compose-submit-turns input))
                  (queued (decknix--compose-queue-count target))
                  (mode (decknix--compose-queue-enqueue-action queued)))
             (if (eq mode 'cancel)
                 (user-error "Nothing queued — existing queue left alone")
               (let ((n (decknix--compose-enqueue-prompt target turns mode)))
                 (decknix--compose-finish)
                 (message "Queued (%d pending) — will submit when agent is ready"
                          (or n 0))))))
          ('interrupt-submit
           ;; The ordering used to be silent: this message ran first and the
           ;; older queued ones followed BEHIND it.
           (let ((choice (decknix--compose-queue-interrupt-action
                          (decknix--compose-queue-count target))))
             (when (eq choice 'cancel)
               (user-error "Interrupt cancelled"))
             (pcase choice
               ('only (with-current-buffer target
                        (setq decknix--compose-queued-prompt nil
                              decknix--compose-queue-held nil)
                        (decknix--compose-queue-cancel-timer)))
               ('last
                ;; Chronological order: this message goes behind what was
                ;; queued before it, and the interrupt lets the queue drain.
                (decknix--compose-enqueue-prompt
                 target (decknix--compose-submit-turns input) 'append)
                (with-current-buffer target
                  (setq decknix--compose-queue-release t))
                (setq input nil))
               (_ nil)))
           (with-current-buffer target
             (when (fboundp 'agent-shell-interrupt)
               (let ((agent-shell-confirm-interrupt nil))
                 (agent-shell-interrupt))))
           ;; Close the compose buffer now so the user sees the
           ;; input depart; the actual submit fires from the wait
           ;; callback once the agent has acked the interrupt.
           (decknix--compose-finish)
           (decknix--compose-wait-not-busy
            target
            (lambda ()
              ;; Nil input means `last' put this message in the queue; the
              ;; poller owns the send from here.
              (when input
                (decknix--compose-submit-after-wait target input)))))
          ('submit
           (unless (and (buffer-live-p target)
                        (get-buffer-process target)
                        (process-live-p (get-buffer-process target)))
             (user-error "Agent process not running — wait for it to start or restart with C-c A a"))
           ;; A drained document is N turns, so the agent being idle means
           ;; send the first and queue the rest rather than collapsing them.
           (let* ((turns (decknix--compose-submit-turns input))
                  (rest (cdr turns))
                  (head (car turns)))
             (decknix--compose-finish)
             (when rest
               (decknix--compose-enqueue-prompt target rest 'append))
             (with-current-buffer target
               (goto-char (point-max))
               (shell-maker-submit :input head))
             (when rest
               (message "Submitted 1 of %d turns (%d queued)"
                        (length turns) (length rest)))))))))))

(defun decknix-agent-compose-interrupt-agent ()
  "Pre-emptively interrupt the agent without submitting.
After interrupting, you can compose your message and submit with
\\[decknix-agent-compose-submit] without the busy prompt."
  (interactive)
  (let ((target decknix--compose-target-buffer))
    (if (and (buffer-live-p target)
             (with-current-buffer target
               (bound-and-true-p shell-maker--busy)))
        (progn
          (with-current-buffer target
            (when (fboundp 'agent-shell-interrupt)
              (let ((agent-shell-confirm-interrupt nil))
                (agent-shell-interrupt))))
          (message "Agent interrupted. Compose your message and C-c C-c to submit."))
      (message "Agent is not busy."))))

(defun decknix-agent-compose-interrupt-and-submit ()
  "Interrupt any in-progress agent response, then submit the compose buffer.
Use this when the agent is processing and you want to interject immediately
rather than waiting for the current response to complete.

The submit waits on the agent's interrupt acknowledgement (via
`decknix--compose-wait-not-busy') before calling
`shell-maker-submit', so the new prompt lands AFTER the
\"[interrupted]\" marker in the buffer.  The compose buffer is
closed/cleared from the wait callback, AFTER the submit, not
before."
  (interactive)
  (let ((input (string-trim (buffer-string)))
        (target decknix--compose-target-buffer)
        (compose-buf (current-buffer)))
    (if (string-empty-p input)
        (user-error "Empty prompt — nothing to submit")
      (decknix--compose-stash-input input)
      ;; Interrupt the agent first.
      (when (buffer-live-p target)
        (with-current-buffer target
          (when (fboundp 'agent-shell-interrupt)
            (let ((agent-shell-confirm-interrupt nil))
              (agent-shell-interrupt)))))
      ;; Wait for the busy flag to clear (or the safety-net timeout)
      ;; before submitting; then close the compose buffer.  Lexical
      ;; binding captures `target' / `input' / `compose-buf' cleanly
      ;; -- the eval/quote dance the old `run-at-time' needed is gone.
      (decknix--compose-wait-not-busy
       target
       (lambda ()
         (if (decknix--compose-submit-after-wait target input)
             ;; Sent: consume the compose buffer as before.
             (when (buffer-live-p compose-buf)
               (with-current-buffer compose-buf
                 (decknix--compose-finish)))
           ;; Refused -- almost always the interrupt never landed.  KEEP
           ;; the compose buffer and say so.  Closing it here is what made
           ;; the prompt look like it vanished; the text is also on the
           ;; kill ring via `decknix--compose-stash-input', but nothing
           ;; told the user that.
           (message
            "Interrupt did not land — prompt NOT sent, left in the compose buffer (also on the kill ring)")))))))

(defun decknix-agent-compose-cancel ()
  "Cancel/clear the compose buffer without submitting.
Sticky mode: clears the buffer. Transient mode: closes the buffer."
  (interactive)
  (decknix--compose-finish)
  (message (if decknix--compose-sticky "Compose cleared." "Compose cancelled.")))

(defun decknix-agent-compose-close ()
  "Close the compose buffer unconditionally (regardless of sticky mode)."
  (interactive)
  (let ((win (selected-window)))
    (quit-restore-window win 'kill))
  (message "Compose closed."))

(defun decknix-agent-compose-toggle-sticky ()
  "Toggle sticky mode for the compose buffer.
Sticky: editor stays open after submit/cancel (content is cleared).
Transient: editor closes after submit/cancel."
  (interactive)
  (setq decknix--compose-sticky (not decknix--compose-sticky))
  (decknix--compose-update-header-line)
  (force-mode-line-update)
  (message "Compose: %s" (if decknix--compose-sticky "sticky (stays open)" "transient (closes on action)")))

;; PR B.74: the propertized-segment builder
;; (`decknix--compose-build-header-line') was carved into
;; `decknix-agent-compose-header'.  This thin wrapper stays here
;; per AGENTS.md Rule 2 -- it owns the `setq-local' side-effect
;; against `header-line-format' and reads the buffer-local
;; `decknix--compose-sticky' flag.

(defun decknix--compose-update-header-line ()
  "Update the header-line to reflect current sticky state.
Compact header — shows C-c as the action prefix and hints that
which-key will reveal bindings.  Full sequences shown via which-key
after pressing C-c."
  (setq-local header-line-format
              (decknix--compose-build-header-line
               decknix--compose-sticky)))

;; PR B.69: `decknix--compose-find-target',
;; `-display-action' and the four completion-at-point helpers
;; were carved into `decknix-agent-compose-internals'.  The
;; interactive `decknix-agent-compose' / `-submit' entry points,
;; the minor mode and its keymap stay here per AGENTS.md Rule 2.

(defun decknix--compose-get-or-create (target)
  "Get the existing compose buffer for TARGET, or create a new one.
If a compose buffer already exists and is visible, just select it."
  (let* ((compose-name (format "*Compose: %s*" (buffer-name target)))
         (existing (get-buffer compose-name)))
    (if (and existing (buffer-live-p existing))
        ;; Re-use existing compose buffer
        (progn
          (unless (get-buffer-window existing)
            (display-buffer existing
                           (decknix--compose-display-action)))
          (select-window (get-buffer-window existing))
          existing)
      ;; Create new compose buffer
      (let ((compose-buf (generate-new-buffer compose-name)))
        (display-buffer compose-buf
                        (decknix--compose-display-action))
        (select-window (get-buffer-window compose-buf))
        (with-current-buffer compose-buf
          (text-mode)
          (decknix-agent-compose-mode 1)
          ;; Enable yasnippet with agent-shell-mode snippets.
          ;; The buffer is text-mode, so yas only sees text-mode
          ;; snippets by default.  yas-activate-extra-mode adds
          ;; agent-shell-mode's snippet table as well.
          (when (fboundp 'yas-minor-mode)
            (yas-minor-mode 1)
            (yas-activate-extra-mode 'agent-shell-mode))
          (setq-local decknix--compose-target-buffer target)
          (setq-local decknix--compose-sticky decknix-agent-compose-sticky)
          ;; Enable slash command (/) and file (@) completion
          (decknix--compose-setup-completion)
          (decknix--compose-update-header-line)
          (set-buffer-modified-p nil))
        compose-buf))))

(defun decknix-agent-compose ()
  "Open or focus the compose buffer for writing a multi-line agent prompt.
The buffer opens at the bottom of the frame. Type your prompt
freely (RET for newlines), then:
  C-c C-c    submit (prompts if agent is busy)
  C-c k k    interrupt agent (pre-emptive)
  C-c k C-c  interrupt agent & submit immediately
  C-c C-k    cancel/clear
  C-c C-s    toggle sticky (stays open) / transient (closes)"
  (interactive)
  (let ((target (decknix--compose-find-target)))
    (decknix--compose-get-or-create target)))

(defun decknix-agent-compose-interrupt ()
  "Interrupt the agent, then open the compose buffer.
Use this when the agent is mid-response and you want to interject."
  (interactive)
  (let ((target (decknix--compose-find-target)))
    ;; Interrupt if busy
    (when (and (buffer-live-p target)
               (with-current-buffer target
                 (bound-and-true-p shell-maker--busy)))
      (with-current-buffer target
        (when (fboundp 'agent-shell-interrupt)
          (let ((agent-shell-confirm-interrupt nil))
            (agent-shell-interrupt))))
      (sit-for 0.3))
    ;; Open/focus compose
    (decknix--compose-get-or-create target)))

(provide 'decknix-agent-shell-main-compose)
;;; decknix-agent-shell-main-compose.el ends here
