;;; decknix-agent-session-cache.el --- Session list cache + jq fetch -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-parse "0.1"))
;; Keywords: agent, agent-shell, decknix, session, cache

;;; Commentary:
;;
;; In-process cache for the auggie session list, populated by parsing
;; `~/.augment/sessions/*.json' directly with jq instead of shelling
;; out to `auggie session list' (which loads full chat history and
;; emits terminal escape codes that break async process output).
;;
;; The cache has a TTL; the first call ever blocks (synchronous fetch)
;; so the picker has data, and subsequent stale reads kick off a non-
;; blocking refresh and serve the previous list immediately.
;;
;; Public surface used elsewhere in the heredoc:
;;
;;   `decknix--agent-session-list'           — read the (cached) list
;;   `decknix--agent-session-refresh-async'  — kick a background fetch
;;   `decknix--agent-session-refresh-sync'   — block-fetch (first call,
;;                                              tests, manual refresh)
;;   `decknix--agent-session-jq-cmd'         — pure shell-string builder
;;                                              (testable in isolation)
;;   `decknix--agent-session-ensure-jq-filter' — write the jq script
;;                                                to a temp file once
;;
;; The state vars (`-cache', `-cache-time', `-cache-ttl', `-refresh-proc',
;; `-jq-filter-file', `-sessions-dir') are intentionally exposed so the
;; sidebar / picker / batch flows can read or invalidate them directly
;; without going through an accessor.

;;; Code:

(require 'cl-lib)

;; Forward declaration: the parser lives in the sibling
;; `decknix-agent-parse' package, loaded by the heredoc immediately
;; before this module.
(declare-function decknix--agent-session-parse "decknix-agent-parse" (raw))

(defvar decknix--agent-session-cache nil
  "Cached list of auggie sessions (alists).")

(defvar decknix--agent-session-cache-time 0
  "Time when session cache was last updated (float-time).")

(defvar decknix--agent-session-cache-ttl 120
  "Seconds before session cache is considered stale.")

(defvar decknix--agent-session-refresh-proc nil
  "Process handle for async session list refresh.")

(defvar decknix--agent-session-cache-max-files 200
  "Maximum number of session JSON files to scan per refresh (newest first).
With 1000+ session files, scanning all of them in parallel takes 10-20 s.
Limiting to the most-recently-modified files keeps the cache refresh fast
while still covering all sessions that could realistically be active.
Set to nil to disable the limit and scan all files (original behaviour).")

(defvar decknix--agent-sessions-dir
  (expand-file-name "~/.augment/sessions")
  "Directory containing auggie session JSON files.")

(defvar decknix--agent-session-jq-filter-file nil
  "Path to temp file containing the jq filter for session extraction.")

(defun decknix--agent-session-list ()
  "Return cached auggie sessions, refreshing async if stale.
On first call (empty cache), falls back to a synchronous fetch."
  (when (and (null decknix--agent-session-cache)
             (= decknix--agent-session-cache-time 0))
    ;; First call ever: synchronous fetch so picker has data
    (decknix--agent-session-refresh-sync))
  ;; Trigger async refresh if stale
  (when (> (- (float-time) decknix--agent-session-cache-time)
           decknix--agent-session-cache-ttl)
    (decknix--agent-session-refresh-async))
  decknix--agent-session-cache)

(defun decknix--agent-session-ensure-jq-filter ()
  "Create the jq filter file if it doesn't exist. Return its path."
  (unless (and decknix--agent-session-jq-filter-file
              (file-exists-p decknix--agent-session-jq-filter-file))
    (setq decknix--agent-session-jq-filter-file
          (make-temp-file "auggie-session-" nil ".jq"))
    (with-temp-file decknix--agent-session-jq-filter-file
      ;; Use try//default for chatHistory operations so that
      ;; files being actively written (mid-write parse errors)
      ;; still produce partial results instead of being silently
      ;; dropped from the session list.
      ;; Skip MCP startup errors when extracting firstUserMessage —
      ;; find the first real user message instead.
      (insert "{sessionId, created, modified,"
              " exchangeCount: (try (.chatHistory | length) // 0),"
              " firstUserMessage:"
              " (try (first(.chatHistory[]"
              " | .exchange.request_message"
              " | select(. != null)"
              " | select(startswith(\"\\u26a0\") | not)"
              " | select(length > 0))[:200])"
              " // \"\")}\n")))
  decknix--agent-session-jq-filter-file)

(defun decknix--agent-session-jq-cmd ()
  "Shell command to extract session metadata directly from files.
Scans at most `decknix--agent-session-cache-max-files' most-recently-
modified files (via `ls -t'), then sorts results by modified time
(newest first).  When the limit is nil, all files are scanned."
  (let* ((jqf (decknix--agent-session-ensure-jq-filter))
         (dir (shell-quote-argument decknix--agent-sessions-dir))
         (max decknix--agent-session-cache-max-files)
         ;; File-listing step: sort by mtime desc, optionally head-limit.
         (list-cmd (if max
                       (concat "ls -t1 " dir "/*.json 2>/dev/null"
                               " | head -" (number-to-string max))
                     (concat "find " dir
                             " -maxdepth 1 -name '*.json' -print 2>/dev/null"))))
    (concat
     list-cmd
     " | tr '\\n' '\\0'"
     " | xargs -0 -P8 -I{} jq -Mc -f "
     (shell-quote-argument jqf)
     " {} 2>/dev/null"
     " | jq -Msc 'sort_by(.modified) | reverse'")))

(defun decknix--agent-session-refresh-sync ()
  "Synchronous session list fetch (used on first call only)."
  (let ((result (decknix--agent-session-parse
                 (shell-command-to-string
                  (decknix--agent-session-jq-cmd)))))
    (setq decknix--agent-session-cache result
          decknix--agent-session-cache-time (float-time))))

(defun decknix--agent-session-refresh-async ()
  "Refresh session cache asynchronously without blocking."
  (when (or (null decknix--agent-session-refresh-proc)
            (not (process-live-p decknix--agent-session-refresh-proc)))
    (let ((buf (generate-new-buffer " *auggie-session-list*")))
      (setq decknix--agent-session-refresh-proc
            (start-process-shell-command
             "auggie-session-list" buf
             (decknix--agent-session-jq-cmd)))
      (set-process-sentinel
       decknix--agent-session-refresh-proc
       (lambda (proc _event)
         (when (eq (process-status proc) 'exit)
           (let ((pbuf (process-buffer proc)))
             (when (buffer-live-p pbuf)
               (let ((result (decknix--agent-session-parse
                              (with-current-buffer pbuf
                                (buffer-string)))))
                 (when result
                   (setq decknix--agent-session-cache result
                         decknix--agent-session-cache-time
                         (float-time))))
               (kill-buffer pbuf)))))))))

(provide 'decknix-agent-session-cache)
;;; decknix-agent-session-cache.el ends here
