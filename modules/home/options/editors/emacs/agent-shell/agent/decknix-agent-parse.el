;;; decknix-agent-parse.el --- Pure parsers + identity helpers -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, parsing, json, hash

;;; Commentary:
;;
;; Pure text-to-data primitives extracted from the agent-shell heredoc.
;; Three small helpers that share a common shape — "tolerant text in,
;; clean structured value out, never throw":
;;
;;   `decknix--agent-session-parse'         (jq array output -> session
;;                                           alists; tolerates trailing
;;                                           process noise after `]')
;;   `decknix--prompt-search-parse'         (jq line-stream output ->
;;                                           deduplicated prompt list)
;;   `decknix--agent-conversation-key-raw'  (first-message string ->
;;                                           SHA-256 truncated to 16
;;                                           hex chars)
;;
;; All three are leaf primitives — no I/O, no global state, no side
;; effects (except the seen-set local to `prompt-search-parse').
;; `error' branches return nil rather than propagating so callers
;; can wrap unconditionally.

;;; Code:

(require 'cl-lib)
(require 'json)

(defun decknix--agent-session-parse (raw)
  "Parse RAW json string into session alists.
Handles process output that may contain trailing text after the JSON array."
  (condition-case nil
      (let* ((json-array-type 'list)
             (json-object-type 'alist)
             (json-key-type 'symbol)
             (trimmed (string-trim raw))
             ;; Process buffers append 'Process ... finished' — find last ']'
             (end (when (string-prefix-p "[" trimmed)
                    (1+ (or (cl-position ?\] trimmed :from-end t) -1))))
             (json-str (when (and end (> end 1))
                         (substring trimmed 0 end))))
        (when json-str
          (json-read-from-string json-str)))
    (error nil)))

(defun decknix--prompt-search-parse (raw)
  "Parse RAW jq output into a flat deduplicated prompt list."
  (let ((seen (make-hash-table :test 'equal))
        (result nil))
    (dolist (line (split-string (string-trim raw) "\n" t))
      (condition-case nil
          (let* ((json-array-type 'list)
                 (json-key-type 'symbol)
                 (msgs (json-read-from-string line)))
            (dolist (msg msgs)
              (when (and (stringp msg)
                         (not (string-empty-p (string-trim msg)))
                         (not (gethash msg seen)))
                (puthash msg t seen)
                (push msg result))))
        (error nil)))
    (nreverse result)))

(defun decknix--agent-conversation-key-raw (first-message)
  "Derive the raw conversation key from FIRST-MESSAGE.
Uses SHA-256 hash truncated to 16 chars.  Does NOT resolve merges —
use `decknix--agent-conversation-key' for the canonical key."
  (when (and first-message (not (string-empty-p first-message)))
    (substring (secure-hash 'sha256 first-message) 0 16)))

(provide 'decknix-agent-parse)
;;; decknix-agent-parse.el ends here
