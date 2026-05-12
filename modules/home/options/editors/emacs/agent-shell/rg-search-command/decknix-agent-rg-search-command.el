;;; decknix-agent-rg-search-command.el --- Pure rg search command builders -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, search

;;; Commentary:
;;
;; Pure shell-command builders carved out of
;; `decknix--agent-session-rg-search-fast' /
;; `decknix--agent-session-rg-search-thorough' (PR B.84).
;;
;; The bulk callers retain ownership of `make-process',
;; `accept-process-output', cache lookup, and result parsing per
;; AGENTS.md Rule 2; this module only owns the three pure
;; transforms:
;;
;;   1. (fast cmd)       term + sessions-dir       -> rg -l0 ... 2>/dev/null
;;   2. (thorough cmd)   term + sessions-dir + jqf -> rg -l0 ... | xargs ... | jq ...
;;   3. (paths -> id-set) NUL-delimited paths      -> hash-table of basenames
;;
;; Pinning these as data lets us assert the exact shell quoting and
;; pipeline shape without having to spawn `rg' / `jq' processes.

;;; Code:

(defun decknix--rg-fast-command (rg term sessions-dir)
  "Return the shell command string for the FAST search variant.
RG is the absolute or PATH-relative `rg' executable, TERM the
search term, SESSIONS-DIR the directory to walk.  All three
arguments are `shell-quote-argument'-protected so callers can
pass arbitrary user input safely.

Output is a single command suitable for `(list \"sh\" \"-c\" CMD)'.
The `2>/dev/null' suppresses rg's diagnostic chatter (binary
files, permission errors) so the filter sees only NUL-delimited
match paths on stdout."
  (format "%s -l0 %s %s 2>/dev/null"
          (shell-quote-argument rg)
          (shell-quote-argument term)
          (shell-quote-argument sessions-dir)))

(defun decknix--rg-thorough-command (rg term sessions-dir jq-filter)
  "Return the shell command string for the THOROUGH search variant.
RG is the `rg' executable, TERM the search term, SESSIONS-DIR
the directory to walk, JQ-FILTER the path to the on-disk jq
program file produced by `decknix--agent-session-ensure-jq-filter'.

The pipeline:
  rg -l0 TERM SESSIONS-DIR
    | xargs -0 -P8 -I{} jq -Mc -f JQ-FILTER {}
    | jq -Msc 'sort_by(.modified) | reverse'

Each stage's stderr is redirected to /dev/null so partial
failures (one malformed JSON, one unreadable file) don't
contaminate the output stream the bulk filter accumulates.

Note: SESSIONS-DIR is expected to already be
`shell-quote-argument'-protected by the caller (the bulk
function pre-quotes it once and reuses it).  This matches the
pre-carve calling convention; mirroring that here keeps the
characterisation tests honest."
  (format "%s -l0 %s %s 2>/dev/null | xargs -0 -P8 -I{} jq -Mc -f %s {} 2>/dev/null | jq -Msc 'sort_by(.modified) | reverse'"
          rg
          (shell-quote-argument term)
          sessions-dir
          (shell-quote-argument jq-filter)))

(defun decknix--rg-paths-to-id-set (paths)
  "Return a hash-table keyed by the basename of each path in PATHS.
PATHS is the list returned by `(split-string OUTPUT \"\\0\" t)'
on the rg-fast pipeline's stdout.  Values are uniformly `t' --
the table is membership-only.

Used by the fast-path bulk caller to filter the in-memory
session-metadata cache by `sessionId' (filename basenames are
`<uuid>.json' and `file-name-base' strips the extension).

Empty PATHS yields an empty table.  Duplicate basenames are
collapsed (`puthash' overwrites with the same `t' value)."
  (let ((h (make-hash-table :test 'equal)))
    (dolist (p paths)
      (puthash (file-name-base p) t h))
    h))

(provide 'decknix-agent-rg-search-command)
;;; decknix-agent-rg-search-command.el ends here
