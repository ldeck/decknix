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

(require 'cl-lib)
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
                  (queued-prompt buffer-live busy proc-live))
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

(defvar decknix-agent-compose-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'decknix-agent-compose-submit)
    (define-key map (kbd "C-c C-k") #'decknix-agent-compose-cancel)
    (define-key map (kbd "C-c C-q") #'decknix-agent-compose-close)
    (define-key map (kbd "C-c C-s") #'decknix-agent-compose-toggle-sticky)
    (define-key map (kbd "C-c k") decknix-agent-compose-interrupt-map)
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
  (if decknix--compose-sticky
      (progn
        (erase-buffer)
        (set-buffer-modified-p nil))
    (let ((win (selected-window)))
      (quit-restore-window win 'kill))))

;; -- Prompt queue: auto-submit when agent becomes idle --
(defvar-local decknix--compose-queued-prompt nil
  "Pending prompt string queued for submission when the agent is idle.
Buffer-local on agent-shell buffers.")

(defvar-local decknix--compose-queue-timer nil
  "Timer polling `shell-maker--busy' to submit a queued prompt.
Buffer-local on agent-shell buffers.")

(defun decknix--compose-queue-poll ()
  "Check if the agent is idle and submit the queued prompt.
Called by a repeating timer on the agent-shell buffer.

PR B.79: the cancel/submit/wait decision is pinned by
`decknix-agent-compose-queue' (carved, +7 ERT).  This function
is the comint/timer-side adapter that performs the actual
side-effect indicated by the resolver's `:action'."
  (let* ((buf (current-buffer))
         (proc (and (buffer-live-p buf) (get-buffer-process buf)))
         (action (decknix--compose-queue-action
                  decknix--compose-queued-prompt
                  (buffer-live-p buf)
                  (bound-and-true-p shell-maker--busy)
                  (and proc (process-live-p proc)))))
    (pcase (plist-get action :action)
      ('cancel-timer
       (when decknix--compose-queue-timer
         (cancel-timer decknix--compose-queue-timer)
         (setq decknix--compose-queue-timer nil)))
      ('submit
       (let ((input (plist-get action :input)))
         (setq decknix--compose-queued-prompt nil)
         (when decknix--compose-queue-timer
           (cancel-timer decknix--compose-queue-timer)
           (setq decknix--compose-queue-timer nil))
         (goto-char (point-max))
         (shell-maker-submit :input input)
         (message "Queued prompt submitted")))
      ('wait nil))))

(defun decknix--compose-enqueue-prompt (target input)
  "Queue INPUT for submission on TARGET buffer when the agent is idle."
  (when (buffer-live-p target)
    (with-current-buffer target
      (setq decknix--compose-queued-prompt input)
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
                     t)))))))

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
dispatch table under ERT."
  (interactive)
  (let* ((input (string-trim (buffer-string)))
         (target decknix--compose-target-buffer))
    (cond
     ((string-empty-p input)
      (user-error "Empty prompt — nothing to submit"))
     (t
      (let* ((busy-p (and (buffer-live-p target)
                          (with-current-buffer target
                            (bound-and-true-p shell-maker--busy))))
             (action (decknix--compose-busy-action busy-p)))
        (pcase action
          ('cancel
           (user-error "Submit cancelled — agent is still processing"))
          ('queue
           (decknix--compose-enqueue-prompt target input)
           (decknix--compose-finish)
           (message "Prompt queued — will submit when agent is ready"))
          ((or 'submit 'interrupt-submit)
           (when (eq action 'interrupt-submit)
             (with-current-buffer target
               (when (fboundp 'agent-shell-interrupt)
                 (let ((agent-shell-confirm-interrupt nil))
                   (agent-shell-interrupt))))
             (sit-for 0.3))
           ;; Verify the agent process is alive before submitting.
           (unless (and (buffer-live-p target)
                        (get-buffer-process target)
                        (process-live-p (get-buffer-process target)))
             (user-error "Agent process not running — wait for it to start or restart with C-c A a"))
           (decknix--compose-finish)
           (with-current-buffer target
             (goto-char (point-max))
             (shell-maker-submit :input input)))))))))

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
The compose buffer is closed/cleared AFTER the submit, not before."
  (interactive)
  (let ((input (string-trim (buffer-string)))
        (target decknix--compose-target-buffer)
        (compose-buf (current-buffer)))
    (if (string-empty-p input)
        (user-error "Empty prompt — nothing to submit")
      ;; Interrupt the agent first
      (when (buffer-live-p target)
        (with-current-buffer target
          (when (fboundp 'agent-shell-interrupt)
            (let ((agent-shell-confirm-interrupt nil))
              (agent-shell-interrupt)))))
      ;; Submit after a brief delay to let the interrupt settle,
      ;; then close/clear the compose buffer.
      (let ((tgt target)
            (inp input)
            (cbuf compose-buf))
        (run-at-time
         0.3 nil
         (eval
          `(lambda ()
             (when (and (buffer-live-p ,tgt)
                        (get-buffer-process ,tgt)
                        (process-live-p (get-buffer-process ,tgt)))
               (with-current-buffer ,tgt
                 (goto-char (point-max))
                 (shell-maker-submit :input ,inp)))
             ;; Now finish (clear/close) the compose buffer
             (when (buffer-live-p ,cbuf)
               (with-current-buffer ,cbuf
                 (decknix--compose-finish))))
          t))))))

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
