;;; decknix-agent-prompt-search-cache.el --- Prompt search cache -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, search, cache

;;; Commentary:
;;
;; Cache layer for the consult-based prompt history search (PR B.72),
;; carved out of main-bulk so the TTL / async-refresh / ring-merge
;; semantics can be exercised from ERT against fixed input rather
;; than against live `~/.augment/sessions/*.json' state.
;;
;; Public surface:
;;
;;   `decknix--prompt-search-cache'           list<string>
;;   `decknix--prompt-search-cache-time'      float-time of last build
;;   `decknix--prompt-search-cache-ttl'       seconds before stale (300)
;;   `decknix--prompt-search-refresh-proc'    in-flight async proc
;;   `decknix--prompt-search-refresh-sync'    sync (re)build
;;   `decknix--prompt-search-refresh-async'   spawn refresh in background
;;   `decknix--prompt-search-get'             current ring + cache, deduped
;;
;; The interactive entry point `decknix-agent-compose-search-history'
;; stays in main-bulk per AGENTS.md Rule 2 -- it consults via
;; `consult--read' and mutates the compose buffer.

;;; Code:

;; Forward declarations -- carved siblings + buffer-local in main-bulk.
(declare-function decknix--prompt-search-jq-cmd
                  "decknix-agent-prompt-search")
(declare-function decknix--prompt-search-parse
                  "decknix-agent-parse" (raw))

(defvar decknix--compose-target-buffer)

(defvar decknix--prompt-search-cache nil
  "Cached list of all user prompts for consult search (strings).")

(defvar decknix--prompt-search-cache-time 0
  "Time when prompt search cache was last updated.")

(defvar decknix--prompt-search-cache-ttl 300
  "Seconds before prompt search cache is stale (5 min).")

(defvar decknix--prompt-search-refresh-proc nil
  "Process handle for async prompt search cache refresh.")

(defun decknix--prompt-search-refresh-sync ()
  "Synchronously build the prompt search cache."
  (message "Loading all prompt history for search…")
  (let ((result (decknix--prompt-search-parse
                 (shell-command-to-string
                  (decknix--prompt-search-jq-cmd)))))
    (setq decknix--prompt-search-cache result
          decknix--prompt-search-cache-time (float-time))
    result))

(defun decknix--prompt-search-refresh-async ()
  "Asynchronously refresh the prompt search cache."
  (when (or (null decknix--prompt-search-refresh-proc)
            (not (process-live-p decknix--prompt-search-refresh-proc)))
    (let ((buf (generate-new-buffer " *auggie-prompt-search*")))
      (setq decknix--prompt-search-refresh-proc
            (start-process-shell-command
             "auggie-prompt-search" buf
             (decknix--prompt-search-jq-cmd)))
      (set-process-sentinel
       decknix--prompt-search-refresh-proc
       (lambda (proc _event)
         (when (eq (process-status proc) 'exit)
           (let ((pbuf (process-buffer proc)))
             (when (buffer-live-p pbuf)
               (let ((result (decknix--prompt-search-parse
                              (with-current-buffer pbuf
                                (buffer-string)))))
                 (when result
                   (setq decknix--prompt-search-cache result
                         decknix--prompt-search-cache-time
                         (float-time))))
               (kill-buffer pbuf)))))))))

(defun decknix--prompt-search-get ()
  "Return all prompts for search, fetching if needed."
  (when (and (null decknix--prompt-search-cache)
             (= decknix--prompt-search-cache-time 0))
    (decknix--prompt-search-refresh-sync))
  (when (> (- (float-time) decknix--prompt-search-cache-time)
           decknix--prompt-search-cache-ttl)
    (decknix--prompt-search-refresh-async))
  ;; Also prepend current comint-input-ring entries
  (let ((seen (make-hash-table :test 'equal))
        (ring-items nil)
        (target (or decknix--compose-target-buffer
                    (when (derived-mode-p 'agent-shell-mode)
                      (current-buffer)))))
    (when (and target (buffer-live-p target))
      (with-current-buffer target
        (when (and (bound-and-true-p comint-input-ring)
                   (not (ring-empty-p comint-input-ring)))
          (dotimes (i (ring-length comint-input-ring))
            (let ((item (ring-ref comint-input-ring i)))
              (when (and (stringp item)
                         (not (string-empty-p (string-trim item)))
                         (not (gethash item seen)))
                (puthash item t seen)
                (push item ring-items)))))))
    ;; Combine: current ring + saved (deduped)
    (let ((result (nreverse ring-items)))
      (dolist (msg decknix--prompt-search-cache)
        (unless (gethash msg seen)
          (puthash msg t seen)
          (push msg result)))
      (nreverse result))))

(provide 'decknix-agent-prompt-search-cache)

;;; decknix-agent-prompt-search-cache.el ends here
