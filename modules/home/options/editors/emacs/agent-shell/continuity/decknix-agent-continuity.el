;;; decknix-agent-continuity.el --- Bring a reattached session back as it was -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-broker-rehydrate "0.1"))
;; Keywords: agent, agent-shell, decknix, broker, session

;;; Commentary:
;;
;; A session whose broker survived an Emacs restart is still running: the
;; bridge holds the whole conversation and may be mid-turn.  What the new
;; buffer lacked was everything the user SEES.  The broker log records only
;; bridge->client bytes, so the agent's side of each turn is there but the
;; user's prompts are not, and the replay that read it was silently broken
;; besides.  The result, counted over the month before this was written,
;; was a "where are we up to?" as the first prompt in 24 sessions across 8
;; restarts.
;;
;; This package renders the last few turns as a conversation:
;;
;;   - agent side: the broker log window before the live attach marker,
;;     split into turns at each `stopReason' result;
;;   - user side: the Claude transcript's TAIL (bounded bytes), each turn's
;;     prompt found by anchoring the turn's closing text to the transcript
;;     entry that ends with it.  Counting prompts does not work: background
;;     task notifications arrive as user entries mid-turn, and on a real
;;     session pairing by count put the wrong prompt on 6 of 6 turns, while
;;     anchoring matched 12 of 12;
;;   - rendering: through upstream's own restore path
;;     (`agent-shell--render-pending-restore'), so the history is styled as a
;;     live turn, lands above the live prompt, and user prompts render as
;;     prompts.  Live output that arrives before the render is held in the
;;     same accumulator and replayed after the history, so a turn streaming
;;     through the restart continues below its own beginning.
;;
;; It also restores what the user would otherwise have to rediscover: the
;; asking/waiting state derived from the last turn's closing text, a
;; permission request the bridge is still waiting on (re-shown and
;; answerable), the comint input ring, and the review-session mode.
;;
;; Renders are queued and run one at a time off a short timer that re-defers
;; while input is pending, so a restart with a dozen sessions never parses
;; them all in one go on the daemon thread.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'ring)
(require 'seq)
(require 'subr-x)
(require 'decknix-agent-broker-rehydrate)

(declare-function agent-shell--state "agent-shell" ())
(declare-function agent-shell--make-pending-restore "agent-shell" ())
(declare-function agent-shell--pop-pending-restore "agent-shell" (state))
(declare-function agent-shell--append-restore-notification "agent-shell" (state n))
(declare-function agent-shell--render-pending-restore "agent-shell" (state))
(declare-function agent-shell--effective-restore-verbosity "agent-shell" (state))
(declare-function agent-shell--on-request "agent-shell" (&rest args))
(declare-function agent-shell-subscribe-to "agent-shell" (&rest args))
(declare-function agent-shell-unsubscribe "agent-shell" (&rest args))
(declare-function decknix-agent-turn-restored-facts "decknix-agent-turn-signals" (turns))
(declare-function decknix-review-session-maybe-enable "decknix-session-urls-ui" (&optional buffer))
(declare-function decknix--agent-resume-focus-prompt "decknix-agent-resume-native" (shell-buf))
(declare-function map-elt "map" (map key &optional default))
(declare-function map-put! "map" (map key value &optional testfn))
(declare-function map-nested-elt "map" (map keys &optional default))

(defvar decknix--agent-turn-question)
(defvar decknix--agent-turn-closing-text)
(defvar decknix--agent-turn-answered)
(defvar comint-input-ring)
(defvar comint-input-ring-size)

(defgroup decknix-agent-continuity nil
  "Restore a reattached agent session's visible conversation."
  :group 'decknix)

(defcustom decknix-agent-continuity-enable t
  "Non-nil to render a reattached session's recent conversation.
Nil falls back to the agent-side-only broker replay."
  :type 'boolean :group 'decknix-agent-continuity)

(defcustom decknix-agent-continuity-turns 3
  "Committed turns rendered above the live prompt, plus any in-flight turn.
Older turns load on demand with `decknix-agent-broker-replay-more'."
  :type 'integer :group 'decknix-agent-continuity)

(defcustom decknix-agent-continuity-transcript-bytes (* 4 1024 1024)
  "Bytes read from the end of a session transcript to find its prompts.
Never the whole file: transcripts of long sessions exceed 50 MB."
  :type 'integer :group 'decknix-agent-continuity)

(defcustom decknix-agent-continuity-stagger 0.3
  "Seconds between queued renders.  Each render re-defers while input is pending."
  :type 'number :group 'decknix-agent-continuity)

(defcustom decknix-agent-continuity-init-timeout 30
  "Seconds to wait for a reattached session's handshake before rendering anyway.
Output that arrives meanwhile is held, so it must be released even when
the session never reports itself initialised (a broker that died during
the restart)."
  :type 'number :group 'decknix-agent-continuity)

(defcustom decknix-agent-continuity-transcript-path-function nil
  "Function of (PROVIDER SESSION-ID) returning the session's transcript path.
Nil means no prompts are rendered, only the agent side."
  :type '(choice (const nil) function) :group 'decknix-agent-continuity)

;; -- Pure: the broker log as turns ------------------------------------------

(defun decknix--continuity-parse (line)
  "Parse LINE as JSON, or nil.  Alias of the broker parser for brevity."
  (decknix--agent-broker-parse-json-line line))

(defun decknix--continuity-get (obj &rest keys)
  "Follow KEYS through nested alists from OBJ; nil at any non-alist step.
Not `let-alist': it binds every path up front, and ACP puts arrays
\(vectors) where other updates put objects, so `assq' would signal."
  (while (and keys (consp obj))
    (setq obj (alist-get (pop keys) obj)))
  (and (null keys) obj))

(defun decknix--continuity-permission-request (line)
  "Return LINE parsed when it is a `session/request_permission' request."
  (when (string-search "\"session/request_permission\"" line)
    (let ((obj (decknix--continuity-parse line)))
      (and (equal (alist-get 'method obj) "session/request_permission")
           (alist-get 'id obj)
           obj))))

(defun decknix--continuity-permission-tool-id (request)
  "The tool call id a permission REQUEST is about."
  (decknix--continuity-get request 'params 'toolCall 'toolCallId))

(defun decknix--continuity-settles-permission-p (notification tool-id)
  "Non-nil when NOTIFICATION shows TOOL-ID moved past its permission prompt."
  (let ((update (decknix--continuity-get notification 'params 'update)))
    (and (equal (decknix--continuity-get update 'sessionUpdate) "tool_call_update")
         (equal (decknix--continuity-get update 'toolCallId) tool-id)
         (decknix--continuity-get update 'status)
         (not (equal (decknix--continuity-get update 'status) "pending")))))

(defun decknix--continuity-stop-reason (line)
  "The stopReason of boundary LINE."
  (decknix--continuity-get (decknix--continuity-parse line) 'result 'stopReason))

(defun decknix--continuity-turns (lines turns)
  "Split broker log LINES into the last TURNS committed turns and any in flight.

Reads the window ending at the last `# client attached' marker (everything
after it is the live stream).  Returns a plist, or nil without a marker:

  :turns    oldest first, each (:notes NOTES :stop-reason SR :committed BOOL)
  :anchor   closing text of the committed turn just before the window, or nil
  :pending  a `session/request_permission' request with no answer since, or nil

One extra turn is read and kept only as the anchor, so the first rendered
turn's prompt can be bounded on both sides in the transcript."
  (let* ((vec (vconcat lines))
         (end (decknix--agent-broker-attach-index vec)))
    (when end
      (let ((start (decknix--agent-broker-window-start vec end (1+ turns)))
            (out nil) (cur nil) (pending nil) (i nil))
        (setq i (1+ start))
        (while (< i end)
          (let ((line (aref vec i)))
            (cond
             ((decknix--agent-broker-line-boundary-p line)
              (push (list :notes (nreverse cur)
                          :stop-reason (decknix--continuity-stop-reason line)
                          :committed t)
                    out)
              (setq cur nil pending nil))
             ((decknix--continuity-permission-request line)
              (setq pending (decknix--continuity-permission-request line)))
             (t
              (when-let* ((n (decknix--agent-broker-line-notification line)))
                (push n cur)
                (when (and pending
                           (decknix--continuity-settles-permission-p
                            n (decknix--continuity-permission-tool-id pending)))
                  (setq pending nil))))))
          (setq i (1+ i)))
        (when cur
          (push (list :notes (nreverse cur) :committed nil) out))
        (let* ((all (nreverse out))
               (committed (seq-count (lambda (tn) (plist-get tn :committed)) all))
               (anchor (and (> committed turns) (car all))))
          (list :turns (if anchor (cdr all) all)
                :anchor (and anchor (decknix--continuity-turn-text anchor))
                :pending pending))))))

(defun decknix--continuity-turn-text (turn)
  "The agent's message text in TURN, concatenated."
  (mapconcat (lambda (n)
               (let ((update (decknix--continuity-get n 'params 'update)))
                 (if (equal (decknix--continuity-get update 'sessionUpdate)
                            "agent_message_chunk")
                     (let ((text (decknix--continuity-get update 'content 'text)))
                       (if (stringp text) text ""))
                   "")))
             (plist-get turn :notes) ""))

;; -- Pure: the transcript tail as entries ------------------------------------

(defun decknix--continuity-content-text (content)
  "Text of a message CONTENT (a string or a list of parts), or nil."
  (cond
   ((stringp content) content)
   ((and (or (consp content) (vectorp content))
         (not (seq-some (lambda (p) (equal (alist-get 'type p) "tool_result"))
                        content)))
    (let ((s (mapconcat (lambda (p)
                          (if (equal (alist-get 'type p) "text")
                              (or (alist-get 'text p) "")
                            ""))
                        content "")))
      (unless (string-empty-p s) s)))))

(defun decknix--continuity-transcript-entries (lines)
  "Return (KIND . TEXT) entries from Claude transcript LINES, in order.
KIND is `user' (a prompt, or anything the harness injected as one) or
`assistant' (a message's text).  Tool results, meta entries and
sidechains (sub-agents) are skipped."
  (let (out)
    (dolist (line lines)
      (let ((kind (cond ((and (string-search "\"type\":\"user\"" line)
                              (not (string-search "\"tool_result\"" line)))
                         'user)
                        ((and (string-search "\"type\":\"assistant\"" line)
                              (string-search "\"type\":\"text\"" line))
                         'assistant))))
        (when kind
          (when-let* ((obj (decknix--continuity-parse line))
                      ((equal (alist-get 'type obj) (symbol-name kind)))
                      ((not (alist-get 'isMeta obj)))
                      ((not (alist-get 'isSidechain obj)))
                      (text (decknix--continuity-content-text
                             (alist-get 'content (alist-get 'message obj)))))
            (push (cons kind text) out)))))
    (nreverse out)))

(defun decknix--continuity-command-text (text)
  "Return \"/name args\" for a slash-command TEXT, or nil."
  (when (string-match "<command-name>\\([^<]*\\)</command-name>" text)
    (let ((name (string-trim (match-string 1 text)))
          (args (and (string-match "<command-args>\\([^<]*\\)</command-args>" text)
                     (string-trim (match-string 1 text)))))
      (concat (if (string-prefix-p "/" name) name (concat "/" name))
              (if (and args (not (string-empty-p args))) (concat " " args) "")))))

(defun decknix--continuity-prompt-text (texts)
  "Render the user entries TEXTS of one turn as a single prompt, or nil.
Typed prompts are kept and joined; slash commands are shown as typed;
harness-injected entries (task notifications, reminders, any other
`<tag>' text) are dropped, and a turn started only by them reads
\"[background task notification]\"."
  (let (real noise)
    (dolist (text texts)
      (let ((cmd (decknix--continuity-command-text text))
            (trimmed (string-trim text)))
        (cond (cmd (push cmd real))
              ((string-prefix-p "<" trimmed) (setq noise t))
              ((not (string-empty-p trimmed)) (push trimmed real)))))
    (cond (real (string-join (nreverse real) "\n\n"))
          (noise "[background task notification]"))))

(defun decknix--continuity-last-prompt (texts)
  "The last typed prompt among user TEXTS, rendered; else their label or nil.
Used where a turn's start cannot be bounded, so only one entry is taken,
and an injected notification must not stand in for what the user typed."
  (or (seq-some (lambda (text)
                  (let ((p (decknix--continuity-prompt-text (list text))))
                    (and p (not (string-prefix-p "[" p)) p)))
                (reverse texts))
      (decknix--continuity-prompt-text (last texts))))

(defconst decknix--continuity-signature-length 60
  "Characters of a turn's closing text used to find it in the transcript.")

(defun decknix--continuity-signature (text)
  (let ((s (string-trim (or text ""))))
    (unless (string-empty-p s)
      (substring s (max 0 (- (length s) decknix--continuity-signature-length))))))

(defun decknix--continuity-find-assistant (entries sig from)
  "Index of the first assistant entry at or after FROM whose text ends with SIG."
  (when sig
    (cl-loop for e in (nthcdr from entries)
             for i from from
             when (and (eq (car e) 'assistant)
                       (string-suffix-p sig (string-trim (cdr e))))
             return i)))

(defun decknix--continuity-users-between (entries from to)
  "User texts among ENTRIES with index in [FROM, TO)."
  (cl-loop for e in (nthcdr from entries)
           for i from from
           while (< i to)
           when (eq (car e) 'user) collect (cdr e)))

(defun decknix--continuity-pair (turns entries &optional anchor)
  "Pair each of TURNS with its prompt from transcript ENTRIES.
Returns a list of (PROMPT . TURN), PROMPT a string or nil.

Each committed turn is located by the transcript assistant entry ending
with the turn's closing text; its prompt is the user entries between the
previous located turn and it.  ANCHOR, the closing text of the turn before
the first, bounds the first turn's prompt; without it only the last typed
prompt before the first located turn is used.  The in-flight turn takes
the user entries after the last located turn."
  (let* ((prev (when-let* ((sig (decknix--continuity-signature anchor)))
                 (decknix--continuity-find-assistant entries sig 0)))
         (pos (if prev (1+ prev) 0))
         (n (length entries))
         out)
    (dolist (turn turns)
      (if (plist-get turn :committed)
          (let ((found (decknix--continuity-find-assistant
                        entries (decknix--continuity-signature
                                 (decknix--continuity-turn-text turn))
                        pos)))
            (if (null found)
                (push (cons nil turn) out)
              (let ((prompt (if prev
                                (decknix--continuity-prompt-text
                                 (decknix--continuity-users-between entries (1+ prev) found))
                              (decknix--continuity-last-prompt
                               (decknix--continuity-users-between entries 0 found)))))
                (push (cons prompt turn) out)
                (setq prev found pos (1+ found)))))
        (push (cons (if prev
                        (decknix--continuity-prompt-text
                         (decknix--continuity-users-between entries (1+ prev) n))
                      (decknix--continuity-last-prompt
                       (decknix--continuity-users-between entries 0 n)))
                    turn)
              out)))
    (nreverse out)))

(defun decknix--continuity-user-chunk (text)
  "A `user_message_chunk' notification carrying TEXT, as the bridge would send."
  `((method . "session/update")
    (params (update (sessionUpdate . "user_message_chunk")
                    (content (type . "text") (text . ,text))))))

(defun decknix--continuity-notifications (pairs)
  "Flatten PAIRS into the notification stream to render, oldest first."
  (cl-loop for (prompt . turn) in pairs
           when prompt collect (decknix--continuity-user-chunk prompt)
           append (plist-get turn :notes)))

(defun decknix--continuity-restored-turns (pairs)
  "PAIRS as (USER . ASSISTANT-TEXT) turns for `decknix-agent-turn-restored-facts'.
Nil when the last turn is still in flight: its closing text does not exist
yet, and a question from an earlier turn must not be resurrected."
  (when (and pairs (plist-get (cdr (car (last pairs))) :committed))
    (mapcar (lambda (p) (cons (or (car p) "") (decknix--continuity-turn-text (cdr p))))
            pairs)))

(defun decknix--continuity-prompts (entries)
  "The typed prompts in transcript ENTRIES, oldest first, for the input ring."
  (delq nil (mapcar (lambda (e)
                      (and (eq (car e) 'user)
                           (let ((p (decknix--continuity-prompt-text (list (cdr e)))))
                             (and p (not (string-prefix-p "[" p)) p))))
                    entries)))

(defun decknix--continuity-last-turn (lines)
  "The turn that committed after the live attach in LINES (a log tail), or nil.
Returns (:notes NOTES :committed t).  Used once a turn in flight at the
reattach settles.  A boundary BEFORE the attach marker is an older turn,
so a turn abandoned when its bridge went away yields nil rather than
the previous turn's question.  A tail with no marker began after it."
  (let* ((vec (vconcat lines))
         (n (length vec))
         (attach (or (decknix--agent-broker-attach-index vec) -1))
         (last (decknix--agent-broker-boundary-before vec n)))
    (when (> last attach)
      (list :notes (decknix--agent-broker-notifications-between
                    vec (decknix--agent-broker-boundary-before vec last) last)
            :committed t))))

;; -- Pure: the render queue ------------------------------------------------

(defun decknix--continuity-next-action (queue input-pending)
  "Decide the next queue step.  Pure.
Returns `idle' for an empty QUEUE, `wait' while INPUT-PENDING (re-defer,
the user is typing), else (run HEAD . REST)."
  (cond ((null queue) 'idle)
        (input-pending 'wait)
        (t (cons 'run queue))))

;; -- Side effects ------------------------------------------------------------

(defvar-local decknix--continuity-armed nil
  "Non-nil once this buffer is waiting to render its restored conversation.")

(defvar-local decknix--continuity-rendered nil
  "Turns rendered by the continuity restore, or nil when none ran.")

(defvar-local decknix--continuity-permission nil
  "Non-nil when a pending permission request was re-shown on restore.")

(defvar-local decknix--continuity-provider nil)
(defvar-local decknix--continuity-inflight-prompt nil)
(defvar-local decknix--continuity-settle-timer nil)

(defvar decknix--continuity-queue nil "Buffers waiting to render, in order.")
(defvar decknix--continuity-timer nil)

(defun decknix--continuity-available-p ()
  (and decknix-agent-continuity-enable
       (fboundp 'agent-shell--make-pending-restore)
       (fboundp 'agent-shell--render-pending-restore)
       (fboundp 'agent-shell--append-restore-notification)
       (fboundp 'agent-shell--pop-pending-restore)))

(defun decknix-agent-continuity-arm (buffer provider)
  "Prepare BUFFER, reattaching to a live broker for PROVIDER, to restore its view.
Holds live output from now on, and queues the render for when the
session finishes its handshake (or after
`decknix-agent-continuity-init-timeout').  Returns non-nil when armed."
  (when (and (buffer-live-p buffer) (decknix--continuity-available-p))
    (with-current-buffer buffer
      (let ((state (ignore-errors (agent-shell--state))))
        (when state
          (map-put! state :pending-restore (agent-shell--make-pending-restore))
          (setq decknix--continuity-armed t
                decknix--continuity-provider provider)
          (let ((done nil) (token nil))
            (setq token
                  (ignore-errors
                    (agent-shell-subscribe-to
                     :shell-buffer buffer :event 'init-finished
                     :on-event (lambda (_e)
                                 (unless done
                                   (setq done t)
                                   (when token (agent-shell-unsubscribe :subscription token))
                                   (decknix--continuity-enqueue buffer))))))
            (run-at-time decknix-agent-continuity-init-timeout nil
                         (lambda ()
                           (unless done
                             (setq done t)
                             (decknix--continuity-enqueue buffer)))))
          t)))))

(defun decknix--continuity-enqueue (buffer)
  (unless (memq buffer decknix--continuity-queue)
    (setq decknix--continuity-queue (append decknix--continuity-queue (list buffer))))
  (decknix--continuity-schedule))

(defun decknix--continuity-schedule ()
  (unless (timerp decknix--continuity-timer)
    (setq decknix--continuity-timer
          (run-at-time decknix-agent-continuity-stagger nil #'decknix--continuity-tick))))

(defun decknix--continuity-tick ()
  "Render the next queued buffer, unless the user is typing."
  (setq decknix--continuity-timer nil)
  (pcase (decknix--continuity-next-action
          decknix--continuity-queue
          (or (input-pending-p) (active-minibuffer-window)))
    ('idle nil)
    ('wait (decknix--continuity-schedule))
    (`(run ,buf . ,rest)
     (setq decknix--continuity-queue rest)
     (when (buffer-live-p buf)
       (condition-case err
           (decknix-agent-continuity-render buf)
         (error (message "decknix: restoring %s failed: %s"
                         (buffer-name buf) (error-message-string err)))))
     (when rest (decknix--continuity-schedule)))))

(defun decknix--continuity-read-tail (file bytes)
  "Complete lines from the last BYTES of FILE, or nil.
A leading line torn by the byte offset is dropped, as is a trailing line
still being written.  Line splitting stays in C (`split-string' on a
buffer substring); an elisp scan for the last newline cost more than the
read itself on a megabyte."
  (when (and file (file-readable-p file))
    (let* ((size (or (file-attribute-size (file-attributes file)) 0))
           (beg (max 0 (- size bytes))))
      (decknix--agent-broker-without-file-hooks
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (insert-file-contents-literally file nil beg size)
          (goto-char (point-max))
          (when (search-backward "\n" nil t)
            (let ((end (point)))
              (goto-char (point-min))
              (when (> beg 0) (forward-line 1))
              (when (< (point) end)
                (split-string (buffer-substring-no-properties (point) end)
                              "\n" t)))))))))

(defun decknix--continuity-transcript (provider)
  "Transcript entries for the current buffer's session, or nil."
  (let* ((sid (ignore-errors (map-nested-elt (agent-shell--state) '(:session :id))))
         (path (and sid decknix-agent-continuity-transcript-path-function
                    (ignore-errors
                      (funcall decknix-agent-continuity-transcript-path-function
                               provider sid)))))
    (when path
      (decknix--continuity-transcript-entries
       (decknix--continuity-read-tail path decknix-agent-continuity-transcript-bytes)))))

(defun decknix--continuity-seed-input-ring (prompts)
  "Seed `comint-input-ring' from PROMPTS when it is empty."
  (when (and prompts (boundp 'comint-input-ring)
             (or (null comint-input-ring) (ring-empty-p comint-input-ring)))
    (setq-local comint-input-ring
                (make-ring (or (bound-and-true-p comint-input-ring-size) 500)))
    (dolist (p prompts) (ring-insert comint-input-ring p))))

(defun decknix--continuity-apply-facts (pairs)
  "Restore the turn-end flags from the last committed turn of PAIRS."
  (when-let* ((turns (decknix--continuity-restored-turns pairs))
              ((fboundp 'decknix-agent-turn-restored-facts))
              (facts (decknix-agent-turn-restored-facts turns)))
    (setq-local decknix--agent-turn-question (plist-get facts :question))
    (setq-local decknix--agent-turn-closing-text (plist-get facts :text))
    (setq-local decknix--agent-turn-answered (plist-get facts :answered))))

(defun decknix-agent-continuity-render (buffer)
  "Render BUFFER's restored conversation above its live prompt.
Called from the queue.  Releases any live output held since the attach
below the history.  Returns the number of turns rendered."
  (with-current-buffer buffer
    (let* ((state (agent-shell--state))
           (held (apply #'append (agent-shell--pop-pending-restore state)))
           (key (bound-and-true-p decknix--agent-broker-key))
           (log (and key (decknix--agent-broker-log-path key)))
           (window decknix-agent-broker-replay-window-bytes)
           (lines (and log (decknix--continuity-read-tail log window)))
           (page (and lines (decknix--continuity-turns
                             lines decknix-agent-continuity-turns)))
           (entries (and page (decknix--continuity-transcript decknix--continuity-provider)))
           (pairs (and page (decknix--continuity-pair
                             (plist-get page :turns) entries (plist-get page :anchor))))
           (notes (append (decknix--continuity-notifications pairs) held)))
      (setq decknix--continuity-armed nil)
      (map-put! state :pending-restore (agent-shell--make-pending-restore))
      (dolist (n notes) (agent-shell--append-restore-notification state n))
      ;; Our own verbosity: upstream falls back to `minimal' (render
      ;; nothing) by provider capability, which is about `session/load',
      ;; not about this replay.
      (cl-letf (((symbol-function 'agent-shell--effective-restore-verbosity)
                 (lambda (_state) 'full)))
        (agent-shell--render-pending-restore state))
      (map-put! state :pending-restore nil)
      (when page
        (setq decknix--agent-broker-replay-window window
              decknix--agent-broker-replay-depth decknix-agent-continuity-turns))
      (setq decknix--continuity-rendered (length pairs))
      (decknix--continuity-apply-facts pairs)
      (decknix--continuity-seed-input-ring (decknix--continuity-prompts entries))
      (when-let* ((req (plist-get page :pending))
                  ((not (seq-some
                         (lambda (n)
                           (decknix--continuity-settles-permission-p
                            n (decknix--continuity-permission-tool-id req)))
                         held))))
        (setq decknix--continuity-permission t)
        (ignore-errors (agent-shell--on-request :state state :acp-request req)))
      (let ((last (car (last pairs))))
        (when (and last (not (plist-get (cdr last) :committed)))
          (setq decknix--continuity-inflight-prompt (car last))
          (decknix--continuity-watch-settle buffer)))
      (when (fboundp 'decknix-review-session-maybe-enable)
        (ignore-errors (decknix-review-session-maybe-enable buffer)))
      (when (fboundp 'decknix--agent-resume-focus-prompt)
        (decknix--agent-resume-focus-prompt buffer))
      (length pairs))))

(defcustom decknix-agent-continuity-settle-interval 5
  "Seconds between checks of whether a reattached in-flight turn has ended."
  :type 'number :group 'decknix-agent-continuity)

(defun decknix--continuity-watch-settle (buffer)
  "Derive BUFFER's turn-end state once the turn in flight at reattach ends.
The bridge answers that turn's prompt to the client that sent it, which
no longer exists, so the new buffer never sees `turn-complete'; without
this it reads as still assessing until its next turn."
  (with-current-buffer buffer
    (when (timerp decknix--continuity-settle-timer)
      (cancel-timer decknix--continuity-settle-timer))
    (let ((cell (list nil)))
      (setcar cell (run-at-time decknix-agent-continuity-settle-interval
                                decknix-agent-continuity-settle-interval
                                #'decknix--continuity-settle-tick buffer cell))
      (setq decknix--continuity-settle-timer (car cell)))))

(defun decknix--continuity-settle-tick (buffer cell)
  "Check BUFFER's in-flight turn; CELL holds this repeating timer."
  (if (not (buffer-live-p buffer))
      (cancel-timer (car cell))
    (with-current-buffer buffer
      (unless (or (input-pending-p)
                  (decknix--agent-broker-working-p buffer))
        (cancel-timer (car cell))
        (setq decknix--continuity-settle-timer nil)
        (when-let* ((log (decknix--agent-broker-log-path
                          (bound-and-true-p decknix--agent-broker-key)))
                    (turn (decknix--continuity-last-turn
                           (decknix--agent-broker-read-log-tail log))))
          (decknix--continuity-apply-facts
           (list (cons decknix--continuity-inflight-prompt turn))))))))

(provide 'decknix-agent-continuity)
;;; decknix-agent-continuity.el ends here
