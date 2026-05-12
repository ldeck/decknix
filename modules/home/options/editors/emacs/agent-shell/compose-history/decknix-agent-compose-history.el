;;; decknix-agent-compose-history.el --- Compose buffer prompt history -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, compose, history

;;; Commentary:
;;
;; Prompt-history navigation for the compose buffer (PR B.75), carved
;; out of main-bulk so the on-demand item/queue/dedup state machine
;; can be exercised in isolation.
;;
;; Public surface:
;;
;;   `decknix--compose-history-init'                seed items + queue
;;   `decknix--compose-history-load-next-batch'     stream next file(s)
;;   `decknix--compose-history-navigate-previous'   M-p / M-P backend
;;   `decknix--compose-history-navigate-next'       M-n / M-N backend
;;   `decknix--compose-history-reset'               clear all state
;;
;; The seven buffer-local defvars are owned here (history-index,
;; saved-input, items, seen, file-queue, exhausted, local-only).  The
;; interactive `decknix-agent-compose-{previous,next}-input{,-global}'
;; wrappers in main-bulk flip the local-only flag and dispatch to the
;; navigate-{previous,next} backends per AGENTS.md Rule 2.
;;
;; The buffer-local `decknix--compose-target-buffer' defvar stays in
;; main-bulk because it is read by all compose code; this file
;; forward-declares it.  Same for `decknix--agent-auggie-session-id'
;; (initialised inside the agent-shell startup hook) and
;; `decknix--agent-sessions-dir' / `decknix--prompt-extract-from-file'
;; which live in their respective carved packages.

;;; Code:

(require 'ring)

;; Forward declarations -- defined in main-bulk and carved siblings.
;; These keep the byte-compiler quiet without creating hard load-
;; order coupling.
(defvar decknix--compose-target-buffer)
(defvar decknix--agent-auggie-session-id)
(defvar decknix--agent-sessions-dir)
(defvar comint-input-ring)

(declare-function decknix--prompt-extract-from-file
                  "decknix-agent-prompt-extract" (file))

(defvar-local decknix--compose-history-index -1
  "Current position in the prompt history.
-1 means not navigating history (showing user's own input).")

(defvar-local decknix--compose-saved-input nil
  "Saved user input before history navigation started.
Restored when cycling past the newest history entry.")

(defvar-local decknix--compose-history-items nil
  "Prompts loaded so far (current ring + streamed sessions).")

(defvar-local decknix--compose-history-seen nil
  "Hash table tracking prompts already in history-items (for dedup).")

(defvar-local decknix--compose-history-file-queue nil
  "Remaining session files to load on-demand (newest first).")

(defvar-local decknix--compose-history-exhausted nil
  "Non-nil when all session files have been processed.")

(defvar-local decknix--compose-history-local-only t
  "When non-nil, M-p/M-n only cycle the current session's prompts.
Set to nil by M-P/M-N to enable cross-session history navigation.")

(defun decknix--compose-history-reset ()
  "Reset all prompt-history navigation state in the current buffer.
Called by `decknix--compose-finish' on submit/cancel and by
`decknix-agent-compose-search-history' after a consult jump."
  (setq decknix--compose-history-index -1
        decknix--compose-saved-input nil
        decknix--compose-history-items nil
        decknix--compose-history-seen nil
        decknix--compose-history-file-queue nil
        decknix--compose-history-exhausted nil
        decknix--compose-history-local-only t))

(defun decknix--compose-history-init ()
  "Initialize on-demand history for this compose buffer.
Populates items from comint-input-ring.  When
`decknix--compose-history-local-only' is non-nil (default / M-p/M-n),
only current-session prompts are loaded.  When nil (M-P/M-N), also
builds the cross-session file queue for on-demand streaming."
  (let ((seen (make-hash-table :test 'equal))
        (items nil)
        (current-session-id nil))
    ;; 1. Current session's comint-input-ring
    (when (and decknix--compose-target-buffer
               (buffer-live-p decknix--compose-target-buffer))
      (with-current-buffer decknix--compose-target-buffer
        (setq current-session-id
              (when (bound-and-true-p decknix--agent-auggie-session-id)
                decknix--agent-auggie-session-id))
        (when (and (bound-and-true-p comint-input-ring)
                   (not (ring-empty-p comint-input-ring)))
          (dotimes (i (ring-length comint-input-ring))
            (let ((item (ring-ref comint-input-ring i)))
              (when (and (stringp item)
                         (not (string-empty-p (string-trim item)))
                         (not (gethash item seen)))
                (puthash item t seen)
                (push item items)))))))
    (setq items (nreverse items))
    ;; 2. File queue: only when cross-session mode is active (M-P/M-N)
    (if decknix--compose-history-local-only
        ;; Local-only: no file queue, mark exhausted immediately
        (setq decknix--compose-history-items items
              decknix--compose-history-seen seen
              decknix--compose-history-file-queue nil
              decknix--compose-history-exhausted t)
      ;; Cross-session: build file queue, exclude current session
      (let* ((dir decknix--agent-sessions-dir)
             (exclude-file (when current-session-id
                             (expand-file-name
                              (concat current-session-id ".json") dir)))
             ;; ls -t gives newest-first by mtime
             (all-files
              (split-string
               (shell-command-to-string
                (concat "ls -t "
                        (shell-quote-argument dir)
                        "/*.json 2>/dev/null"))
               "\n" t))
             (queue (if exclude-file
                        (seq-remove
                         (lambda (f) (string= f exclude-file))
                         all-files)
                      all-files)))
        (setq decknix--compose-history-items items
              decknix--compose-history-seen seen
              decknix--compose-history-file-queue queue
              decknix--compose-history-exhausted (null queue))))))

(defun decknix--compose-history-load-next-batch ()
  "Load prompts from the next session file(s) in the queue.
Keeps loading files until at least one new prompt is found or queue is empty.
Returns non-nil if new prompts were added."
  (let ((added nil))
    (while (and (not added) decknix--compose-history-file-queue)
      (let* ((file (pop decknix--compose-history-file-queue))
             (msgs (decknix--prompt-extract-from-file file)))
        (dolist (msg msgs)
          (unless (gethash msg decknix--compose-history-seen)
            (puthash msg t decknix--compose-history-seen)
            ;; Append to end of items list
            (setq decknix--compose-history-items
                  (nconc decknix--compose-history-items (list msg)))
            (setq added t)))))
    (when (null decknix--compose-history-file-queue)
      (setq decknix--compose-history-exhausted t))
    added))

(defun decknix--compose-history-navigate-previous ()
  "Core implementation: move to the previous (older) prompt in history."
  ;; Initialize on first navigation
  (unless decknix--compose-history-seen
    (decknix--compose-history-init))
  (let ((items decknix--compose-history-items))
    ;; Save current input when starting navigation
    (when (= decknix--compose-history-index -1)
      (setq decknix--compose-saved-input
            (buffer-substring-no-properties (point-min) (point-max))))
    ;; Try to move backward
    (let ((new-index (1+ decknix--compose-history-index)))
      (when (and (>= new-index (length items))
                 (not decknix--compose-history-exhausted))
        ;; Need more -- load next session file(s)
        (decknix--compose-history-load-next-batch)
        (setq items decknix--compose-history-items))
      (if (>= new-index (length items))
          (progn
            (message "End of %s history (%d prompts)"
                     (if decknix--compose-history-local-only
                         "session" "global")
                     (length items))
            (ding))
        (setq decknix--compose-history-index new-index)
        (erase-buffer)
        (insert (nth new-index items))
        (goto-char (point-max))))))

(defun decknix--compose-history-navigate-next ()
  "Core implementation: move to the next (newer) prompt in history."
  (cond
   ;; Already at current input
   ((= decknix--compose-history-index -1)
    (message "End of history") (ding))
   ;; Moving to current input (restore saved)
   ((= decknix--compose-history-index 0)
    (setq decknix--compose-history-index -1)
    (erase-buffer)
    (when decknix--compose-saved-input
      (insert decknix--compose-saved-input))
    (goto-char (point-max)))
   ;; Move forward (newer)
   (t
    (setq decknix--compose-history-index
          (1- decknix--compose-history-index))
    (erase-buffer)
    (insert (nth decknix--compose-history-index
                 decknix--compose-history-items))
    (goto-char (point-max)))))

(provide 'decknix-agent-compose-history)
;;; decknix-agent-compose-history.el ends here
