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
(declare-function decknix--agent-subagent-meta
                  "decknix-agent-session-cache" (provider-id path))

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
         (multi (decknix-agent-provider-multi-project-p p-id)))
    (if multi
        ;; Multi-project structure (e.g. Claude, Pi): session file is in
        ;; dir/<slug>/sid.ext.  Memoise the scan result; a still-present
        ;; cached path skips the subprocess entirely.
        (let* ((key (cons p-id session-id))
               (cached (gethash key decknix--agent-session-file-cache)))
          (if (and cached (file-exists-p cached))
              cached
            ;; `*<sid><ext>' rather than `<sid><ext>': pi names its
            ;; transcripts `<timestamp>_<sid>.jsonl', so an exact match
            ;; never resolved one and every reader of a pi session's
            ;; history silently got nothing (the resume primer, the
            ;; `asking'-flag restore).  The glob still matches Claude's
            ;; plain `<sid>.jsonl'.
            (let* ((cmd (format "find %s -maxdepth 2 -name '*%s%s' -print -quit 2>/dev/null"
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

(defconst decknix--agent-turn-timestamp-property 'decknix-turn-timestamp
  "Text property carrying a turn's ISO-8601 timestamp on its user text.")

(defun decknix--agent-turn-timestamp-put (text timestamp)
  "Return TEXT carrying TIMESTAMP, or TEXT unchanged when there is none.

A turn record is a `(USER . RESPONSE)' cons, and every consumer reads it
that way -- the resume primer, the context viewer, the `asking'-flag
restore, the history extractor.  Adding a third field would break all of
them at once for the sake of a field only the viewer wants.

So the timestamp rides as a text property on the user string, which is
transparent to every existing reader: `string=' ignores properties,
`insert' and `mapconcat' preserve them, and anything calling
`substring-no-properties' simply drops it rather than breaking."
  (if (and (stringp text) timestamp)
      (let ((copy (copy-sequence text)))
        (put-text-property 0 (length copy)
                           decknix--agent-turn-timestamp-property
                           timestamp copy)
        copy)
    text))

(defun decknix--agent-turn-timestamp (text)
  "Return the ISO-8601 timestamp carried by TEXT, or nil."
  (and (stringp text)
       (> (length text) 0)
       (get-text-property 0 decknix--agent-turn-timestamp-property text)))

(defun decknix--agent-turn-record-timestamp (turn)
  "Return the timestamp of TURN, a `(USER . RESPONSE)' cons, or nil."
  (and (consp turn) (decknix--agent-turn-timestamp (car turn))))

(defun decknix--agent-session-record-timestamp (data)
  "Return the ISO-8601 timestamp from a parsed transcript record DATA.

Claude writes `timestamp' at the top level of every line; pi nests the
whole record under `message', so check both rather than assuming the
shape -- reading only the top level is what yielded zero turns for every
pi session when the role was read that way."
  (or (alist-get 'timestamp data)
      (alist-get 'timestamp (alist-get 'message data))))

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
                   (msg  (alist-get 'message data))
                   ;; Claude puts the role at the TOP level as `type';
                   ;; pi writes every record as `type: "message"' and
                   ;; nests the role under `message'.  Reading only the
                   ;; top level yielded ZERO turns for every pi session,
                   ;; which silently disabled the resume primer and the
                   ;; `asking'-flag restore for that provider.
                   (type (let ((top (alist-get 'type data)))
                           (if (member top '("user" "assistant"))
                               top
                             (or (alist-get 'role msg) top)))))
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
                    ;; Stamp the turn with the time of the line that STARTS
                    ;; it.  The response accumulates across many later
                    ;; lines, so the user prompt is the only unambiguous
                    ;; moment a turn can be said to have happened at.
                    (setq cur-user (decknix--agent-turn-timestamp-put
                                    text
                                    (decknix--agent-session-record-timestamp
                                     data))
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

(defvar decknix--agent-subagent-task-cache (make-hash-table :test 'equal)
  "META-FILE -> (MTIME . TASK), so a refresh re-reads only what changed.
One session had 156 sub-agents; re-reading every meta.json on every
refresh would cost 156 file reads per sidebar cycle.")

(defun decknix--agent-subagent-task (meta-file)
  "Return (TYPE DESCRIPTION STOPPED) from META-FILE, or nil.

Claude writes `<agent>.meta.json\=' beside each sub-agent transcript:
`{\"agentType\": \"pr-implementer\", \"description\": \"Contacts 01.2 to
ready\", \"stoppedByUser\": true}\='.  Without it every child rendered as
its PARENT\'s name -- six rows of `↳ C mvp/followupboss/us\=' -- with
nothing to say which was doing what."
  (let* ((attrs (file-attributes meta-file))
         (mtime (and attrs (float-time (file-attribute-modification-time attrs))))
         (hit (gethash meta-file decknix--agent-subagent-task-cache)))
    (cond
     ((null mtime) nil)
     ((and hit (equal (car hit) mtime)) (cdr hit))
     (t (let ((task (decknix--agent-subagent-task-read meta-file)))
          (puthash meta-file (cons mtime task) decknix--agent-subagent-task-cache)
          task)))))

(defun decknix--agent-subagent-task-read (meta-file)
  "Parse META-FILE into (TYPE DESCRIPTION STOPPED), or nil."
  (when (file-readable-p meta-file)
    (let ((m (ignore-errors
               (json-parse-string
                ;; Literal: a plain read runs coding detection, which
               ;; editorconfig advises into a walk up the tree for an
               ;; `.editorconfig'; the parser takes UTF-8 bytes as-is.
               (let ((file-name-handler-alist nil))
                 (with-temp-buffer
                   (set-buffer-multibyte nil)
                   (insert-file-contents-literally meta-file)
                   (buffer-string)))
                :object-type 'alist :null-object nil :false-object nil))))
      (when m
        (list (alist-get 'agentType m)
              (alist-get 'description m)
              (eq (alist-get 'stoppedByUser m) t))))))

(defun decknix--agent-subagent-with-task (data file)
  "Return sub-agent DATA with the type and task from FILE\='s meta.json."
  (let ((task (decknix--agent-subagent-task
               (concat (file-name-sans-extension file) ".meta.json"))))
    (append (list (cons 'filePath file)
                  (cons 'agentType (nth 0 task))
                  (cons 'description (nth 1 task))
                  (cons 'stoppedByUser (nth 2 task)))
            data)))

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
            (let ((dir-attrs (file-attributes sub-dir)))
              (when (eq t (file-attribute-type dir-attrs))
                (decknix--agent-subagents-sorted
                 (delq nil
                       (mapcar #'cddr
                               (decknix--agent-subagent-dir-entries
                                p-id sub-dir
                                (float-time (file-attribute-modification-time dir-attrs))
                                (concat ".*" ext "$")
                                (float-time)))))))))))))

;; -- Incremental sub-agent listing ------------------------------------
;;
;; Each refresh listed the `subagents/' dir and rebuilt every child's
;; entry: up to 181 files, each with a regexp match, a metadata lookup, a
;; meta.json stat and a `format-time-string'.  Sampled, that was a fifth
;; of a multi-second paint, and the 3 s window above almost never covered
;; two paints.  The listing changes only when a child is added or
;; removed, which moves the DIRECTORY's mtime, so it is re-read only then;
;; a child's entry is rebuilt only when ITS mtime moves.
;;
;; A child's own writes do not move the directory's mtime, so liveness
;; still needs a stat per child.  That is skipped for children idle past
;; `decknix-agent-subagent-dormant-seconds', which are re-stat'ed only
;; when the listing changes or every
;; `decknix-agent-subagent-dormant-restat-seconds'.  Most of a session's
;; children are long finished, so this is most of the stats.

(defvar decknix-agent-subagent-dormant-seconds 600
  "Seconds since its last write after which a sub-agent is re-stat'ed rarely.
Matches the sub-agent `active' window: older than this it renders as done
whatever its exact age.")

(defvar decknix-agent-subagent-dormant-restat-seconds 60
  "Seconds between stats of a dormant sub-agent\='s transcript.
The cost of a larger value is lag on a finished sub-agent being resumed:
it is seen writing again at most this late.")

(defvar decknix--agent-subagent-dir-cache (make-hash-table :test 'equal)
  "SUB-DIR -> (DIR-MTIME RESTAT-AT . FILES).
FILES is a list of (PATH MTIME . DATA) in listing order; DATA is the
decorated metadata, or nil for a child that could not be parsed yet.
RESTAT-AT is when dormant children were last stat\='ed.")

(defun decknix--agent-subagent-file-entry (p-id path old)
  "Return (PATH MTIME . DATA) for sub-agent PATH, reusing OLD if unchanged."
  (let ((mtime (let ((attrs (file-attributes path)))
                 (and attrs (float-time (file-attribute-modification-time attrs))))))
    (if (and old (equal mtime (cadr old)))
        old
      (cons path
            (cons mtime
                  (when mtime
                    (let ((data (decknix--agent-subagent-meta p-id path)))
                      (and data (decknix--agent-subagent-with-task data path)))))))))

(defun decknix--agent-subagent-dir-entries (p-id sub-dir dir-mtime regexp now)
  "Return SUB-DIR\='s (PATH MTIME . DATA) entries as of NOW.
DIR-MTIME is SUB-DIR\='s current mtime and REGEXP matches transcripts."
  (let* ((hit (gethash sub-dir decknix--agent-subagent-dir-cache))
         (same-dir (and hit (equal dir-mtime (car hit))))
         (restat (or (not same-dir)
                     (>= (- now (cadr hit))
                         decknix-agent-subagent-dormant-restat-seconds)))
         (old (and hit (cddr hit)))
         (by-path (unless same-dir
                    (let ((h (make-hash-table :test 'equal)))
                      (dolist (e old h) (puthash (car e) e h)))))
         (files
          (if same-dir
              (mapcar (lambda (e)
                        (if (and (not restat)
                                 (cadr e)
                                 (> (- now (cadr e))
                                    decknix-agent-subagent-dormant-seconds))
                            e
                          (decknix--agent-subagent-file-entry p-id (car e) e)))
                      old)
            (mapcar (lambda (path)
                      (decknix--agent-subagent-file-entry
                       p-id path (gethash path by-path)))
                    (directory-files sub-dir t regexp)))))
    (puthash sub-dir (cons dir-mtime (cons (if restat now (cadr hit)) files))
             decknix--agent-subagent-dir-cache)
    files))

(defun decknix--agent-subagents-sorted (subagents)
  "Return SUBAGENTS newest first, by their `modified' stamps."
  (sort (copy-sequence subagents)
        (lambda (a b)
          (string> (or (alist-get 'modified a) "")
                   (or (alist-get 'modified b) "")))))

(provide 'decknix-agent-session-history)
;;; decknix-agent-session-history.el ends here
