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
;;   `decknix--agent-session-parse-object'  (jq single-object output ->
;;                                           one session alist; tolerates
;;                                           trailing process noise after
;;                                           `}'.  The sequential
;;                                           per-file jq path emits a
;;                                           bare `{...}' object, which
;;                                           the array parser above
;;                                           rejects)
;;   `decknix--prompt-search-parse'         (jq line-stream output ->
;;                                           deduplicated prompt list)
;;   `decknix--agent-conversation-key-raw'  (first-message string ->
;;                                           SHA-256 truncated to 16
;;                                           hex chars; input is itself
;;                                           truncated to the first
;;                                           `decknix--agent-conv-key-canonical-length'
;;                                           characters first to match
;;                                           the jq `[:200]' slice
;;                                           applied on the read side)
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

(defun decknix--agent-session-parse-object (raw)
  "Parse RAW json string into a single session alist.
Mirrors `decknix--agent-session-parse' but for the bare `{...}' object
emitted by the sequential per-file jq path (the array parser only
accepts input starting with `[').  Tolerates process output with
trailing text after the closing `}' and returns nil for empty,
malformed, or non-object (e.g. array) input."
  (condition-case nil
      (let* ((json-array-type 'list)
             (json-object-type 'alist)
             (json-key-type 'symbol)
             (trimmed (string-trim raw))
             ;; Only accept a bare object; an array `[...]' is the
             ;; array parser's job.  Slice to the last `}' so trailing
             ;; process noise (e.g. 'Process ... finished') is dropped.
             (end (when (string-prefix-p "{" trimmed)
                    (1+ (or (cl-position ?\} trimmed :from-end t) -1))))
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

(defconst decknix--agent-conv-key-canonical-length 200
  "Character cap applied to FIRST-MESSAGE before hashing.
Mirrors the jq filter `[:200]' slice in
`decknix--agent-session-ensure-jq-filter' so that the write side
(comint input filter, quickaction launchers) and the read side
(picker, sidebar, header lookups) hash the same canonical form.

Without this cap, messages longer than 200 codepoints produced
write-side keys that the read side could never resolve, leaving
their tags / workspace / linked-PR metadata orphaned in
`agent-sessions.json'.")

(defun decknix--agent-conversation-key-raw (first-message)
  "Derive the raw conversation key from FIRST-MESSAGE.
Truncates FIRST-MESSAGE to the first
`decknix--agent-conv-key-canonical-length' characters and returns
SHA-256 of that prefix, itself truncated to 16 hex chars.  Does NOT
resolve merges — use `decknix--agent-conversation-key' for the
canonical key."
  (when (and first-message (not (string-empty-p first-message)))
    (let* ((len (length first-message))
           (canonical (if (> len decknix--agent-conv-key-canonical-length)
                          (substring first-message 0
                                     decknix--agent-conv-key-canonical-length)
                        first-message)))
      (substring (secure-hash 'sha256 canonical) 0 16))))

(provide 'decknix-agent-parse)
;;; decknix-agent-parse.el ends here
