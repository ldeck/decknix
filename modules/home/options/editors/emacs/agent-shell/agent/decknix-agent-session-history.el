;;; decknix-agent-session-history.el --- Local session JSON path + history extractor -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, session, history

;;; Commentary:
;;
;; Pure reader for the on-disk auggie session JSON carved out of
;; `decknix-agent-shell-main' (main-bulk) into the same
;; `agent-shell/agent/' cluster as the rest of the per-conversation
;; persistence helpers.  Two entry points:
;;
;;   `decknix--agent-session-file' -- path builder that maps a
;;       SESSION-ID to the full local transcript path.  For
;;       single-directory providers (Auggie) it is a pure
;;       `expand-file-name' under `~/.augment/sessions/'; for
;;       multi-project providers (Claude) it runs a `find' scan and
;;       memoises the result (see
;;       `decknix--agent-session-file-cache').  Used by the resume flow
;;       (`decknix--agent-session-prepopulate' /
;;       `--restore-input-ring' in main-bulk), the grep
;;       jump-to-match flow, the compose history streamer, and the
;;       backup / cleanup commands.
;;
;;   `decknix--agent-session-extract-all-turns' -- single-pass turn
;;       grouper over the session's `chatHistory' array.  The auggie
;;       JSON splits each user->assistant turn across many entries:
;;       one entry carries the user text in `request_message' (with
;;       `response_text' typically empty), and the assistant's reply
;;       is spread across the *following* entries as response chunks
;;       (their `request_message' is empty -- those entries are
;;       tool-result / streaming fragments attributed to the same
;;       turn).  A new turn opens whenever `request_message' becomes
;;       non-empty again.
;;
;;       Walks the array forward once, accumulating `response_text'
;;       chunks under the current user message, closing the turn on
;;       the next user message or end-of-history.  Returns the full
;;       turn list oldest-first so callers (timeline navigation,
;;       jump-to-match) can index into it without re-parsing.
;;
;;   `decknix--agent-session-extract-history' -- thin wrapper that
;;       delegates to `extract-all-turns' and then takes the last N
;;       turns.  Preserves the original (pre-#136) contract.
;;
;;   `decknix--agent-session-window-clamp' -- pure window math.
;;       Returns CURSOR clamped to [0, max(0, TOTAL-COUNT)] so the
;;       window [cursor, cursor+count) sits inside [0, TOTAL).  Used
;;       by the buffer-side `[' / `]' timeline navigation in
;;       main-bulk.
;;
;;   `decknix--agent-session-take-window' -- pure list slicer.
;;       Returns up to COUNT turns from TURNS starting at the
;;       window-clamped CURSOR.
;;
;;   `decknix--agent-session-find-turn-containing' -- pure search.
;;       Returns the 0-based index of the first turn (oldest-first)
;;       whose user message OR assistant response matches REGEXP
;;       (case-insensitive).  Used by the session-grep jump-to-match
;;       flow (#136) when the matched turn lies outside the loaded
;;       `decknix-agent-session-history-count' window: the buffer
;;       seeds its `decknix--agent-history-cursor' so the matched
;;       turn lands at the bottom of the rendered window.
;;
;; The extractors only read JSON and allocate cons cells, and the
;; window helpers do arithmetic on integers and lists -- no global
;; state, no buffer side-effects.  The path builder is pure for
;; single-directory providers; for multi-project providers it scans
;; with `find' and memoises into `decknix--agent-session-file-cache'
;; (semantically transparent -- same input, same output, just
;; faster).  The companion writer / mutation paths
;; (`decknix--agent-session-restore-input-ring',
;; `decknix--agent-session-prepopulate') stay in main-bulk per
;; AGENTS.md Rule 2 because they touch `comint-input-ring' and
;; insert text into the agent buffer.

;;; Code:

(require 'json)
(require 'subr-x)
(require 'decknix-agent-provider)

;; Cross-module: the mtime-keyed session metadata reader lives in
;; `decknix-agent-session-cache' (not required here to avoid a load
;; cycle -- it is present at runtime in the daemon).
(declare-function decknix--session-meta "decknix-agent-session-cache")

(defvar decknix--agent-session-file-cache (make-hash-table :test 'equal)
  "Memo of resolved multi-project session-transcript paths.
Keyed on (PROVIDER-ID . SESSION-ID); value is the absolute path found by
the `find' scan in `decknix--agent-session-file'.  Transcript files are
stable once written, so a cached path is revalidated cheaply with
`file-exists-p' rather than re-running the (subprocess) scan.  This keeps
the 2-second workspace-sidebar refresh from spawning one `find' per live
Claude session -- previously ~48 ms per session per render, which stalled
cursor motion once several sessions were open.  Reset on module reload.")

(defun decknix--agent-session-file (session-id &optional provider-id)
  "Return the path to the local session transcript for SESSION-ID.
PROVIDER-ID defaults to `decknix-agent-default-provider'.

For single-directory providers (e.g. Auggie) this is a pure
`expand-file-name'.  For multi-project providers (e.g. Claude, whose
transcripts live under dir/<slug>/sid.ext) the first lookup runs a
`find' scan and the resolved path is memoised in
`decknix--agent-session-file-cache' -- see that variable for why."
  (let* ((p-id (or provider-id decknix-agent-default-provider))
         (dir  (decknix-agent-provider-sessions-dir p-id))
         (ext  (decknix-agent-provider-session-file-extension p-id))
         (hist (decknix-agent-provider-history-file p-id)))
    (if hist
        ;; Multi-project structure (e.g. Claude): session file is in
        ;; dir/<slug>/sid.ext.  Memoise the scan result; a still-present
        ;; cached path skips the subprocess entirely.
        (let* ((key (cons p-id session-id))
               (cached (gethash key decknix--agent-session-file-cache)))
          (if (and cached (file-exists-p cached))
              cached
            (let* ((cmd (format "find %s -maxdepth 2 -name '%s%s' -print -quit 2>/dev/null"
                                 (shell-quote-argument dir) session-id ext))
                   (path (string-trim (shell-command-to-string cmd))))
              ;; Only cache real hits; a miss (empty) may resolve later
              ;; once the transcript is flushed to disk.
              (unless (string-empty-p path)
                (puthash key path decknix--agent-session-file-cache))
              path)))
      ;; Single directory structure (e.g. Auggie).
      (expand-file-name (concat session-id ext) dir))))

(defun decknix--agent-session-extract-all-turns (session-id &optional provider-id)
  "Extract ALL user-visible exchanges from SESSION-ID's local transcript.
PROVIDER-ID defaults to `decknix-agent-default-provider'.
Returns a list of (USER-MSG . ASSISTANT-RESP) cons cells, oldest first.
Returns nil if the file does not exist or fails to parse."
  (let* ((p-id (or provider-id decknix-agent-default-provider))
         (file (decknix--agent-session-file session-id p-id))
         (ext  (decknix-agent-provider-session-file-extension p-id)))
    (when (and file (not (string-empty-p file)) (file-exists-p file))
      (if (string= ext ".jsonl")
          (decknix--agent-session-extract-all-turns-jsonl file)
        (decknix--agent-session-extract-all-turns-json file)))))

(defun decknix--agent-session-extract-all-turns-json (file)
  "Extract turns from a single Auggie-style JSON file."
  (condition-case err
      (let* ((json-array-type 'list)
             (json-object-type 'alist)
             (json-key-type 'symbol)
             (data (json-read-file file))
             (history (alist-get 'chatHistory data))
             (turns nil)
             (cur-user nil)
             (cur-resp nil))
        (dolist (entry history)
          (let* ((ex (alist-get 'exchange entry))
                 (req (alist-get 'request_message ex ""))
                 (resp (alist-get 'response_text ex "")))
            (when (and (stringp req)
                       (not (string-empty-p (string-trim req))))
              ;; Close out the previous turn (if any).
              (when cur-user
                (push (cons cur-user
                            (mapconcat #'identity
                                       (nreverse cur-resp) "\n"))
                      turns))
              (setq cur-user req
                    cur-resp nil))
            (when (and cur-user
                       (stringp resp)
                       (not (string-empty-p resp)))
              (push resp cur-resp))))
        ;; Close out the final turn.
        (when cur-user
          (push (cons cur-user
                      (mapconcat #'identity (nreverse cur-resp) "\n"))
                turns))
        (nreverse turns))
    (error
     (message "Failed to read session history (JSON): %s"
              (error-message-string err))
     nil)))

(defun decknix--agent-session-jsonl-user-text (content)
  "Extract displayable user text from a Claude JSONL user message CONTENT.
CONTENT is either a string (a genuine user prompt) or a list of
Anthropic content blocks.  Returns the concatenated text of any
`text' blocks, or nil when CONTENT carries no user-authored text --
e.g. a message whose blocks are all `tool_result' (the delivery of a
tool call's output, which is part of the assistant's work loop, not a
user turn).  Never returns the raw block list, so callers can treat
the result as a string and never hit `wrong-type-argument stringp'."
  (cond
   ((stringp content) content)
   ((listp content)
    (let ((parts nil))
      (dolist (block content)
        ;; A text block is either explicitly typed \"text\" or a bare
        ;; block carrying a `text' key; tool_result / tool_use blocks
        ;; have no user-authored text and contribute nothing.
        (when (consp block)
          (let ((type (alist-get 'type block))
                (text (alist-get 'text block)))
            (when (and (stringp text)
                       (or (null type) (string= type "text")))
              (push text parts)))))
      (when parts
        (mapconcat #'identity (nreverse parts) "\n"))))
   (t nil)))

(defun decknix--agent-session-extract-all-turns-jsonl (file)
  "Extract turns from a Claude-style JSONL file."
  (condition-case err
      (with-temp-buffer
        (insert-file-contents file)
        (let ((turns nil)
              (cur-user nil)
              (cur-resp-parts nil))
          (goto-char (point-min))
          (while (not (eobp))
            (let* ((line (buffer-substring-no-properties
                          (line-beginning-position) (line-end-position)))
                   (data (ignore-errors
                           (let ((json-object-type 'alist)
                                 (json-array-type 'list)
                                 (json-key-type 'symbol))
                             (json-read-from-string line))))
                   (type (alist-get 'type data))
                   (msg  (alist-get 'message data)))
              (cond
               ((string= type "user")
                ;; Start of a new turn -- but ONLY for a genuine user
                ;; prompt.  Claude delivers tool-call results as `user'
                ;; messages whose `content' is a list of `tool_result'
                ;; blocks (no user-authored text); those are part of the
                ;; assistant's own work loop, so they must not split the
                ;; turn nor be stored as `cur-user' (a non-string there
                ;; caused `wrong-type-argument stringp' on restore).
                (let ((text (decknix--agent-session-jsonl-user-text
                             (alist-get 'content msg))))
                  (when (and text
                             (not (string-empty-p (string-trim text))))
                    (when cur-user
                      (push (cons cur-user
                                  (mapconcat #'identity
                                             (nreverse cur-resp-parts) "\n"))
                            turns))
                    (setq cur-user text
                          cur-resp-parts nil))))
               ((string= type "assistant")
                ;; Accumulate assistant response parts
                (let* ((content (alist-get 'content msg))
                       (text (if (listp content)
                                 (mapconcat (lambda (c) (alist-get 'text c ""))
                                            content "\n")
                               (or content ""))))
                  (when (not (string-empty-p text))
                    (push text cur-resp-parts))))))
            (forward-line 1))
          ;; Close final turn
          (when cur-user
            (push (cons cur-user
                        (mapconcat #'identity (nreverse cur-resp-parts) "\n"))
                  turns))
          (nreverse turns)))
    (error
     (message "Failed to read session history (JSONL): %s"
              (error-message-string err))
     nil)))

(defun decknix--agent-session-extract-history (session-id n &optional provider-id)
  "Extract the last N user-visible exchanges from SESSION-ID transcript.
PROVIDER-ID defaults to `decknix-agent-default-provider'.
Returns a list of (USER-MSG . ASSISTANT-RESP) cons cells, oldest first."
  (let* ((all (decknix--agent-session-extract-all-turns session-id provider-id))
         (len (length all)))
    (if (> len n) (nthcdr (- len n) all) all)))

(defun decknix--agent-session-window-clamp (cursor count total)
  "Clamp CURSOR so the window [cursor, cursor+COUNT) sits within [0, TOTAL).
Returns 0 when TOTAL is 0 or COUNT is non-positive, so renderers
get a usable starting point even on an empty session.  Otherwise
returns CURSOR clamped to the closed range [0, max(0, TOTAL-COUNT)]
-- callers (timeline `[' / `]') can pass in arbitrarily-out-of-range
cursors and get back a value safe to pass to
`decknix--agent-session-take-window'."
  (cond
   ((or (<= total 0) (<= count 0)) 0)
   ((<= total count) 0)
   (t (max 0 (min cursor (- total count))))))

(defun decknix--agent-session-take-window (turns cursor count)
  "Return up to COUNT turns from TURNS starting at clamped CURSOR.
CURSOR is run through `decknix--agent-session-window-clamp' against
TURNS' length so out-of-range values are silently corrected.
Returns nil when TURNS is empty or COUNT is non-positive."
  (when (and turns (> count 0))
    (let* ((total (length turns))
           (start (decknix--agent-session-window-clamp cursor count total))
           (rest (nthcdr start turns))
           (taken nil)
           (i 0))
      (while (and rest (< i count))
        (push (car rest) taken)
        (setq rest (cdr rest)
              i (1+ i)))
      (nreverse taken))))

(defun decknix--agent-session-find-turn-containing (turns regexp)
  "Return 0-based index of first turn in TURNS whose text matches REGEXP.
Searches both the user message (car) and assistant response (cdr)
of each turn, case-insensitively (`case-fold-search' bound to t).
Returns nil if TURNS is empty, REGEXP is nil/empty, or no turn
matches.

Used by the session-grep jump-to-match flow (#136): the typed
search term that ripgrep matched against the on-disk JSON is
re-scanned against the same parsed turn list so the buffer-side
caller can position the timeline cursor on the matched turn."
  (when (and turns
             (stringp regexp)
             (not (string-empty-p regexp)))
    (let ((case-fold-search t)
          (idx 0))
      (catch 'found
        (dolist (turn turns)
          (when (or (and (stringp (car turn))
                         (string-match-p regexp (car turn)))
                    (and (stringp (cdr turn))
                         (string-match-p regexp (cdr turn))))
            (throw 'found idx))
          (setq idx (1+ idx)))
        nil))))


(defvar decknix--agent-session-subagents-cache (make-hash-table :test 'equal)
  "Memo cache for `decknix--agent-session-subagents'.
KEY is \"PROVIDER/SESSION-ID\"; VALUE is (:at FLOAT :data LIST).")

(defvar decknix--agent-session-subagents-throttle 3.0
  "Seconds to reuse a memoized `decknix--agent-session-subagents' result.
The sidebar re-renders the full live-session tree on every paint tick,
calling this once per live buffer each time.  Walking the subagents
directory, resolving the session file and sorting on every tick became
the dominant main-thread stall once the session re-parse storm was
throttled: an external `sample' of the wedged daemon put ~54% of
main-thread CPU in this one call.  Within this window the last result is
reused, bounding the work to once per window per session no matter how
often the sidebar repaints.  Set to 0 to always recompute (old
behaviour).")

(defun decknix--agent-session-subagents (session-id &optional provider-id)
  "Return metadata for sub-agents of SESSION-ID, memoized.
PROVIDER-ID defaults to `decknix-agent-default-provider'.  Results are
cached per session for `decknix--agent-session-subagents-throttle'
seconds so repeated sidebar repaints reuse them; see
`decknix--agent-session-subagents-compute' for the actual walk."
  (let* ((p-id (or provider-id decknix-agent-default-provider))
         (key (concat (symbol-name p-id) "/" (or session-id "")))
         (memo (gethash key decknix--agent-session-subagents-cache)))
    (if (and memo
             (> decknix--agent-session-subagents-throttle 0)
             (< (- (float-time) (plist-get memo :at))
                decknix--agent-session-subagents-throttle))
        (plist-get memo :data)
      (let ((result (decknix--agent-session-subagents-compute session-id p-id)))
        (puthash key (list :at (float-time) :data result)
                 decknix--agent-session-subagents-cache)
        result))))

(defun decknix--agent-session-subagents-compute (session-id p-id)
  "Walk the sub-agent transcripts for SESSION-ID under provider P-ID.
Uncached core of `decknix--agent-session-subagents'.
For Claude, sub-agents are stored in a `subagents/' subdirectory next
to the main session transcript."
  (let* ((hist (decknix-agent-provider-history-file p-id)))
    (if (not hist)
        nil ;; Auggie has no known sub-agent structure yet
      (let* ((s-file (decknix--agent-session-file session-id p-id)))
        (when (and s-file (not (string-empty-p s-file)) (file-exists-p s-file))
          ;; For Claude, the session file path might be:
          ;;   projects/slug/sid.jsonl
          ;; OR, sid might be a directory containing subagents/.
          (let* ((base-dir (file-name-directory s-file))
                 ;; Some versions use projects/slug/sid/subagents/
                 ;; Others use projects/slug/subagents/ with agent-ID.jsonl
                 ;; Based on spike: projects/slug/sid/subagents/ exists.
                 (sid-dir (expand-file-name session-id base-dir))
                 (sub-dir (expand-file-name "subagents" sid-dir))
                 (ext (decknix-agent-provider-session-file-extension p-id)))
            (unless (file-directory-p sub-dir)
              ;; Try sibling subagents/
              (setq sub-dir (expand-file-name "subagents" base-dir)))
            (when (file-directory-p sub-dir)
              (let* ((files (directory-files sub-dir t (concat ".*" ext "$")))
                     (subagents nil))
                (dolist (f files)
                  ;; Parse metadata (using the mtime-keyed cache)
                  (let ((data (decknix--session-meta p-id f)))
                    (when data (push data subagents))))
                (sort subagents
                      (lambda (a b)
                        (string> (or (alist-get 'modified a) "")
                                 (or (alist-get 'modified b) ""))))))))))))

(provide 'decknix-agent-session-history)
;;; decknix-agent-session-history.el ends here
