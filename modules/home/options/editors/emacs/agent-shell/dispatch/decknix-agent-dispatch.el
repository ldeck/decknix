;;; decknix-agent-dispatch.el --- Explicit-approval CLI-to-session prompt dispatch -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, dispatch

;;; Commentary:
;;
;; Receiver half of `decknix-agent-dispatch' (the CLI is the sender).  An
;; outside process hands ONE prompt to ONE live agent-shell session by
;; dropping a request file; this module delivers it through the same submit
;; path the compose buffer uses, and records what happened in a receipt.
;; Nothing here talks to Emacs over `emacsclient -e', opens another ACP
;; attachment, or resumes a session: the only channel is a private directory.
;;
;; State lives in a 0700 directory (`decknix-agent-dispatch-dir'):
;;
;;   pending/   <request-id>.json   written by the CLI (atomic rename, 0600)
;;   inflight/  <request-id>.json   claimed by this receiver (atomic rename)
;;              <request-id>.attempt  marker written just before submit
;;   receipts/  <request-id>.json   one per request, never overwritten
;;   tmp/       scratch for atomic writes
;;
;; Delivery is AT MOST ONCE.  The request is renamed pending -> inflight (an
;; atomic claim; a second claimer loses) before anything else, the attempt
;; marker is written before the submit call, and the receipt is written before
;; the inflight file is removed.  There is no retry anywhere: a crash or an
;; ambiguous outcome produces `unknown' (marker seen) or `not-sent' (never
;; attempted) on recovery.
;;
;; Receipt states: accepted, rejected, expired, not-sent, unknown.
;;
;; The receiver fails closed on: an id that is not an exact lowercase UUID, no
;; or several live buffers holding the session, a buffer that changed between
;; claim and submit, a dead process, text the user has typed but not sent, a
;; stale or future-dated request, a request older than the moment the receiver
;; was armed, an unsafe file (symlink, wrong mode or owner, oversized), and a
;; unsafe state directory.  A busy session is waited on, never interrupted, and
;; only until the request's own expiry.
;;
;; Installing this package is inert: it defines functions and a global minor
;; mode, and starts no timer, watch or directory.  Delivery only happens while
;; `decknix-agent-dispatch-mode' is on, which is a deliberate user action.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'filenotify)

(defvar shell-maker--busy)

(defgroup decknix-agent-dispatch nil
  "Explicit-approval prompt dispatch into live agent-shell sessions."
  :group 'tools)

(declare-function decknix--compose-submit-after-wait "decknix-agent-shell-main-compose"
                  (target input))
(declare-function decknix--agent-buffer-session-id "decknix-agent-buffer-lookup"
                  (&optional buf))
(declare-function agent-shell-buffers "agent-shell")

(defvar decknix-agent-dispatch-dir
  (expand-file-name "decknix/agent-dispatch"
                    (or (getenv "XDG_STATE_HOME") "~/.local/state"))
  "Private state directory shared with the `decknix-agent-dispatch' CLI.")

(defvar decknix-agent-dispatch-max-ttl 900
  "Longest lifetime in seconds a request may claim.")

(defvar decknix-agent-dispatch-max-prompt-bytes 65536
  "Largest prompt, in UTF-8 bytes, the receiver will deliver.")

(defvar decknix-agent-dispatch-poll-interval 2
  "Seconds between scans; file-notify only makes a scan happen sooner.")

(defvar decknix-agent-dispatch-clock-skew 60
  "Seconds a request's creation time may lead the receiver's clock.")

(defvar decknix-agent-dispatch-submit-function #'decknix--compose-submit-after-wait
  "Called with (BUFFER INPUT); non-nil only when INPUT was really submitted.")

(defvar decknix-agent-dispatch-session-id-function
  (lambda (buf) (and (fboundp 'decknix--agent-buffer-session-id)
                     (decknix--agent-buffer-session-id buf)))
  "Called with a buffer; returns its full session id or nil.")

(defvar decknix-agent-dispatch-buffers-function
  (lambda () (and (fboundp 'agent-shell-buffers) (agent-shell-buffers)))
  "Returns the agent-shell buffers to consider.")

(defvar decknix-agent-dispatch--active (make-hash-table :test 'equal)
  "Claimed requests awaiting an idle session: id -> (:req REQ :buffer BUF).")
(defvar decknix-agent-dispatch--armed-at nil
  "Epoch second the receiver was armed; earlier requests are refused.")
(defvar decknix-agent-dispatch--timer nil)
(defvar decknix-agent-dispatch--watch nil)
(defvar decknix-agent-dispatch--kick nil)

(defconst decknix-agent-dispatch--uuid-regexp
  "[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{12\\}")

(defconst decknix-agent-dispatch--subdirs '("pending" "inflight" "receipts" "tmp"))

(defconst decknix-agent-dispatch--reserved-prompts '("help" "clear" "config")
  "Inputs shell-maker handles itself and never sends to the agent.")

;; -- pure ----------------------------------------------------------

(defun decknix-agent-dispatch--now ()
  (floor (float-time)))

(defun decknix-agent-dispatch--uuid-p (s)
  "Non-nil when S is exactly a lowercase 36-character UUID."
  (and (stringp s)
       (let ((case-fold-search nil))
         (string-match-p (concat "\\`" decknix-agent-dispatch--uuid-regexp "\\'") s))
       t))

(defun decknix-agent-dispatch--prompt-hash (prompt)
  (secure-hash 'sha256 (encode-coding-string prompt 'utf-8)))

(defun decknix-agent-dispatch--validate (req now)
  "Return nil when REQ is deliverable at NOW, else a short reason string."
  (if (not (and (consp req) (plistp req)))
      "malformed"
    (let ((prompt (plist-get req :prompt))
          (created (plist-get req :created_at))
          (expires (plist-get req :expires_at)))
      (cond
       ((not (eql (plist-get req :v) 1)) "bad-version")
       ((not (decknix-agent-dispatch--uuid-p (plist-get req :id))) "bad-id")
       ((not (decknix-agent-dispatch--uuid-p (plist-get req :session_id)))
        "bad-session-id")
       ((not (stringp prompt)) "malformed")
       ((string-empty-p (string-trim prompt)) "empty-prompt")
       ((member (downcase (string-trim prompt))
                decknix-agent-dispatch--reserved-prompts)
        "reserved-prompt")
       ((> (length (encode-coding-string prompt 'utf-8))
           decknix-agent-dispatch-max-prompt-bytes)
        "prompt-too-large")
       ((not (equal (plist-get req :prompt_sha256)
                    (decknix-agent-dispatch--prompt-hash prompt)))
        "hash-mismatch")
       ((not (and (integerp created) (integerp expires))) "bad-times")
       ((> created (+ now decknix-agent-dispatch-clock-skew)) "future-dated")
       ((<= expires created) "bad-times")
       ((> (- expires created) decknix-agent-dispatch-max-ttl) "ttl-too-long")
       ((>= now expires) "expired")))))

(cl-defun decknix-agent-dispatch--decide (&key matches same proc unsent busy)
  "Return `submit', `wait' or (refuse . REASON) from the caller's observations.
MATCHES is how many live buffers hold the session, SAME whether that is
still the buffer claimed, PROC whether its process is live, UNSENT whether
the user has typed text not yet sent, BUSY whether a turn is running.
Unsent input outranks busy: waiting on a session someone is typing into
only delays the same refusal."
  (cond
   ((eql matches 0) '(refuse . "no-session"))
   ((> matches 1) '(refuse . "ambiguous-session"))
   ((not same) '(refuse . "session-changed"))
   ((not proc) '(refuse . "no-process"))
   (unsent '(refuse . "unsent-input"))
   (busy 'wait)
   (t 'submit)))

;; -- state directory ----------------------------------------------

(defun decknix-agent-dispatch--sub (name)
  (expand-file-name name decknix-agent-dispatch-dir))

(defun decknix-agent-dispatch--ensure-dirs ()
  "Create any missing state directory with mode 0700.
Existing directories are left as they are so `--check-dirs' can refuse a
loose one instead of this function quietly repairing it."
  (dolist (d (cons "" decknix-agent-dispatch--subdirs))
    (let ((path (directory-file-name (expand-file-name d decknix-agent-dispatch-dir))))
      (unless (file-exists-p path)
        (make-directory path t)
        (set-file-modes path #o700)))))

(defun decknix-agent-dispatch--check-dirs ()
  "Signal a `user-error' unless every state directory is private and ours."
  (dolist (d (cons "" decknix-agent-dispatch--subdirs))
    (let* ((path (directory-file-name (expand-file-name d decknix-agent-dispatch-dir)))
           (attrs (file-attributes path)))
      (unless (and attrs
                   (not (file-symlink-p path))
                   (eq t (file-attribute-type attrs))
                   (= #o700 (logand (file-modes path) #o777))
                   (= (user-uid) (file-attribute-user-id attrs)))
        (user-error "Dispatch state dir %s must be a real directory, mode 0700, owned by you"
                    path)))))

(defun decknix-agent-dispatch--path (sub id &optional ext)
  (expand-file-name (concat id (or ext ".json")) (decknix-agent-dispatch--sub sub)))

(defun decknix-agent-dispatch--receipt-exists-p (id)
  (file-exists-p (decknix-agent-dispatch--path "receipts" id)))

(defun decknix-agent-dispatch--write-receipt (id session-id state reason &optional info)
  "Write the receipt for ID atomically; return nil if one already exists.
INFO is a plist of extra non-nil fields.  The prompt text is never recorded."
  (let* ((body (append (list :v 1 :id id)
                       (and session-id (list :session_id session-id))
                       (list :state state)
                       (and reason (list :reason reason))
                       (list :at (decknix-agent-dispatch--now))
                       info))
         (tmp (decknix-agent-dispatch--path
               "tmp" (format "receipt-%s-%06x" id (random #xffffff)) ".tmp"))
         (final (decknix-agent-dispatch--path "receipts" id)))
    (condition-case nil
        (progn
          (with-file-modes #o600
            (let ((coding-system-for-write 'utf-8-unix))
              (write-region (json-serialize body) nil tmp nil 'silent)))
          (rename-file tmp final nil)
          t)
      (error (ignore-errors (delete-file tmp)) nil))))

(defun decknix-agent-dispatch--claim (id)
  "Atomically move ID from pending to inflight; non-nil if this call won."
  (condition-case nil
      (progn (rename-file (decknix-agent-dispatch--path "pending" id)
                          (decknix-agent-dispatch--path "inflight" id)
                          nil)
             t)
    (error nil)))

(defun decknix-agent-dispatch--cleanup (id)
  (dolist (p (list (decknix-agent-dispatch--path "inflight" id)
                   (decknix-agent-dispatch--path "inflight" id ".attempt")))
    (ignore-errors (delete-file p)))
  (remhash id decknix-agent-dispatch--active))

(defun decknix-agent-dispatch--finish (id session-id state reason &optional info)
  "Record the outcome, then drop the in-flight files (receipt first)."
  (decknix-agent-dispatch--write-receipt id session-id state reason info)
  (decknix-agent-dispatch--cleanup id)
  state)

(defun decknix-agent-dispatch--safe-file-p (path)
  (let ((attrs (file-attributes path)))
    (and attrs
         (not (file-symlink-p path))
         (null (file-attribute-type attrs))
         (= #o600 (logand (file-modes path) #o777))
         (= (user-uid) (file-attribute-user-id attrs))
         (<= (file-attribute-size attrs)
             (+ 4096 (* 6 decknix-agent-dispatch-max-prompt-bytes))))))

(defun decknix-agent-dispatch--read-request (path)
  "Parse the request at PATH into a plist, or nil when unparseable."
  (condition-case nil
      (with-temp-buffer
        (let ((coding-system-for-read 'utf-8))
          (insert-file-contents path))
        (json-parse-string (buffer-string) :object-type 'plist
                           :null-object nil :false-object nil))
    (error nil)))

;; -- session observation ------------------------------------------

(defun decknix-agent-dispatch--matching-buffers (sid)
  (seq-filter
   (lambda (buf)
     (and (buffer-live-p buf)
          (equal sid (ignore-errors
                       (funcall decknix-agent-dispatch-session-id-function buf)))))
   (funcall decknix-agent-dispatch-buffers-function)))

(defun decknix-agent-dispatch--process-live-p (buf)
  (let ((proc (get-buffer-process buf)))
    (and proc (process-live-p proc))))

(defun decknix-agent-dispatch--unsent-input-p (buf)
  "Non-nil when BUF's prompt holds text the user typed but did not send.
Fails closed: an unreadable process mark counts as unsent input."
  (with-current-buffer buf
    (let* ((proc (get-buffer-process buf))
           (pm (and proc (process-mark proc))))
      (if (not (and pm (marker-position pm)))
          t
        (not (string-empty-p
              (string-trim (buffer-substring-no-properties
                            (min pm (point-max)) (point-max)))))))))

(defun decknix-agent-dispatch--busy-p (buf)
  (with-current-buffer buf (bound-and-true-p shell-maker--busy)))

;; -- delivery ------------------------------------------------------

(defun decknix-agent-dispatch--info (req &optional input buf)
  (append (list :prompt_sha256 (plist-get req :prompt_sha256))
          (and input (list :prompt_len (length input)))
          (and buf (list :buffer (buffer-name buf)))))

(defun decknix-agent-dispatch--attempt (id req buf input)
  "Submit INPUT to BUF, the one irreversible step; always ends with a receipt."
  (let ((sid (plist-get req :session_id)))
    (with-file-modes #o600
      (write-region "1" nil (decknix-agent-dispatch--path "inflight" id ".attempt")
                    nil 'silent))
    (condition-case err
        (let ((ok (funcall decknix-agent-dispatch-submit-function buf input)))
          (cond
           ((not ok)
            (decknix-agent-dispatch--finish
             id sid "rejected" "submit-refused" (decknix-agent-dispatch--info req)))
           ((decknix-agent-dispatch--busy-p buf)
            (decknix-agent-dispatch--finish
             id sid "accepted" nil (decknix-agent-dispatch--info req input buf)))
           (t
            (decknix-agent-dispatch--finish
             id sid "unknown" "no-busy-evidence-after-submit"
             (decknix-agent-dispatch--info req input buf)))))
      (error
       (decknix-agent-dispatch--finish
        id sid "unknown"
        (truncate-string-to-width
         (concat "submit-error: " (error-message-string err)) 200)
        (decknix-agent-dispatch--info req input buf))))))

(defun decknix-agent-dispatch--step (id)
  "Advance claimed request ID one decision; never blocks."
  (when-let ((entry (gethash id decknix-agent-dispatch--active)))
    (let* ((req (plist-get entry :req))
           (sid (plist-get req :session_id))
           (info (decknix-agent-dispatch--info req)))
      (if (>= (decknix-agent-dispatch--now) (plist-get req :expires_at))
          (decknix-agent-dispatch--finish id sid "expired" "expired-before-send" info)
        (let* ((matches (decknix-agent-dispatch--matching-buffers sid))
               (buf (and (= 1 (length matches)) (car matches)))
               (claimed (plist-get entry :buffer))
               (decision
                (decknix-agent-dispatch--decide
                 :matches (length matches)
                 :same (or (null claimed) (eq claimed buf))
                 :proc (and buf (decknix-agent-dispatch--process-live-p buf))
                 :unsent (and buf (decknix-agent-dispatch--unsent-input-p buf))
                 :busy (and buf (decknix-agent-dispatch--busy-p buf)))))
          (when (and buf (not claimed))
            (puthash id (plist-put entry :buffer buf) decknix-agent-dispatch--active))
          (cond
           ((eq decision 'wait) nil)
           ((consp decision)
            (decknix-agent-dispatch--finish id sid "rejected" (cdr decision) info))
           ((not (functionp decknix-agent-dispatch-submit-function))
            (decknix-agent-dispatch--finish id sid "rejected" "submit-unavailable" info))
           ((input-pending-p) nil)
           (t (decknix-agent-dispatch--attempt
               id req buf (string-trim-right (plist-get req :prompt))))))))))

(defun decknix-agent-dispatch--process-pending (id)
  "Claim and validate pending request ID, then take its first step."
  (when (decknix-agent-dispatch--claim id)
    (let* ((path (decknix-agent-dispatch--path "inflight" id))
           (now (decknix-agent-dispatch--now)))
      (cond
       ((decknix-agent-dispatch--receipt-exists-p id)
        (decknix-agent-dispatch--cleanup id))
       ((not (decknix-agent-dispatch--safe-file-p path))
        (decknix-agent-dispatch--finish id nil "rejected" "unsafe-file"))
       (t
        (let* ((req (decknix-agent-dispatch--read-request path))
               (sid (and (consp req) (plist-get req :session_id)))
               (sid (and (decknix-agent-dispatch--uuid-p sid) sid))
               (bad (or (decknix-agent-dispatch--validate req now)
                        (and (not (equal id (plist-get req :id))) "bad-id")
                        (and decknix-agent-dispatch--armed-at
                             (< (plist-get req :created_at)
                                decknix-agent-dispatch--armed-at)
                             "predates-arming"))))
          (cond
           ((equal bad "expired")
            (decknix-agent-dispatch--finish id sid "expired" "expired-before-claim"
                                            (decknix-agent-dispatch--info req)))
           (bad
            (decknix-agent-dispatch--finish id sid "rejected" bad))
           (t
            (puthash id (list :req req) decknix-agent-dispatch--active)
            (decknix-agent-dispatch--step id)))))))))

(defun decknix-agent-dispatch--pending-ids ()
  (mapcar (lambda (f) (string-remove-suffix ".json" f))
          (directory-files (decknix-agent-dispatch--sub "pending") nil
                           (concat "\\`" decknix-agent-dispatch--uuid-regexp "\\.json\\'"))))

(defun decknix-agent-dispatch--guard (id thunk)
  "Run THUNK for request ID; an unexpected error settles ID fail-closed.
Before the attempt marker the request was certainly not sent; after it the
outcome is uncertain.  Either way it leaves the in-flight set, so a bug
cannot make the same request retry on every tick."
  (condition-case err
      (funcall thunk)
    (error
     (let* ((req (plist-get (gethash id decknix-agent-dispatch--active) :req))
            (sid (plist-get req :session_id))
            (msg (truncate-string-to-width
                  (concat "internal-error: " (error-message-string err)) 200)))
       (message "decknix-agent-dispatch: %s: %s" id msg)
       (if (file-exists-p (decknix-agent-dispatch--path "inflight" id ".attempt"))
           (decknix-agent-dispatch--finish id sid "unknown" msg)
         (decknix-agent-dispatch--finish id sid "not-sent" msg))))))

(defun decknix-agent-dispatch--tick ()
  "Scan for new requests and advance waiting ones.  Cheap; never blocks."
  (when decknix-agent-dispatch--armed-at
    (condition-case err
        (let ((waiting (hash-table-keys decknix-agent-dispatch--active)))
          (dolist (id (seq-take (decknix-agent-dispatch--pending-ids) 8))
            (decknix-agent-dispatch--guard
             id (lambda () (decknix-agent-dispatch--process-pending id))))
          (dolist (id waiting)
            (decknix-agent-dispatch--guard
             id (lambda () (decknix-agent-dispatch--step id)))))
      (error (message "decknix-agent-dispatch: tick failed: %s"
                      (error-message-string err))))))

(defun decknix-agent-dispatch--recover ()
  "Settle requests a previous receiver left in flight; never retries."
  (let ((ids (delete-dups
              (mapcar (lambda (f) (substring f 0 36))
                      (directory-files
                       (decknix-agent-dispatch--sub "inflight") nil
                       (concat "\\`" decknix-agent-dispatch--uuid-regexp
                               "\\.\\(json\\|attempt\\)\\'"))))))
    (dolist (id ids)
      (unless (decknix-agent-dispatch--receipt-exists-p id)
        (let* ((req (decknix-agent-dispatch--read-request
                     (decknix-agent-dispatch--path "inflight" id)))
               (sid (and (consp req) (plist-get req :session_id)))
               (sid (and (decknix-agent-dispatch--uuid-p sid) sid)))
          (if (file-exists-p (decknix-agent-dispatch--path "inflight" id ".attempt"))
              (decknix-agent-dispatch--write-receipt
               id sid "unknown" "receiver-restarted-after-attempt")
            (decknix-agent-dispatch--write-receipt
             id sid "not-sent" "receiver-restarted"))))
      (decknix-agent-dispatch--cleanup id))))

(defun decknix-agent-dispatch--disarm-requests ()
  "Settle every waiting request as not sent."
  (dolist (id (hash-table-keys decknix-agent-dispatch--active))
    (let ((req (plist-get (gethash id decknix-agent-dispatch--active) :req)))
      (decknix-agent-dispatch--finish id (plist-get req :session_id)
                                      "not-sent" "disarmed"
                                      (decknix-agent-dispatch--info req)))))

;; -- lifecycle -----------------------------------------------------

(defun decknix-agent-dispatch--kick-scan (&rest _)
  "File-notify callback: schedule one scan soon, collapsing bursts."
  (unless decknix-agent-dispatch--kick
    (setq decknix-agent-dispatch--kick
          (run-at-time 0.2 nil
                       (lambda ()
                         (setq decknix-agent-dispatch--kick nil)
                         (decknix-agent-dispatch--tick))))))

(defun decknix-agent-dispatch--start ()
  (decknix-agent-dispatch--ensure-dirs)
  (decknix-agent-dispatch--check-dirs)
  (setq decknix-agent-dispatch--armed-at (decknix-agent-dispatch--now))
  (decknix-agent-dispatch--recover)
  (setq decknix-agent-dispatch--timer
        (run-with-timer decknix-agent-dispatch-poll-interval
                        decknix-agent-dispatch-poll-interval
                        #'decknix-agent-dispatch--tick))
  (setq decknix-agent-dispatch--watch
        (ignore-errors
          (file-notify-add-watch (decknix-agent-dispatch--sub "pending")
                                 '(change) #'decknix-agent-dispatch--kick-scan))))

(defun decknix-agent-dispatch--stop ()
  (when decknix-agent-dispatch--timer (cancel-timer decknix-agent-dispatch--timer))
  (when decknix-agent-dispatch--kick (cancel-timer decknix-agent-dispatch--kick))
  (when decknix-agent-dispatch--watch
    (ignore-errors (file-notify-rm-watch decknix-agent-dispatch--watch)))
  (setq decknix-agent-dispatch--timer nil
        decknix-agent-dispatch--kick nil
        decknix-agent-dispatch--watch nil)
  (decknix-agent-dispatch--disarm-requests)
  (setq decknix-agent-dispatch--armed-at nil))

;;;###autoload
(define-minor-mode decknix-agent-dispatch-mode
  "Deliver explicitly requested prompts to live agent-shell sessions.

Off by default and never enabled automatically.  While on, a request file
dropped by the `decknix-agent-dispatch' CLI is delivered at most once to the
single session whose full id it names.  Turning the mode off settles every
waiting request as not sent.  Requests created before the mode was turned on
are refused, so enabling it cannot release old requests."
  :global t
  :lighter nil
  :group 'decknix-agent-dispatch
  (if decknix-agent-dispatch-mode
      (condition-case err
          (decknix-agent-dispatch--start)
        (error (setq decknix-agent-dispatch-mode nil)
               (decknix-agent-dispatch--stop)
               (signal (car err) (cdr err))))
    (decknix-agent-dispatch--stop)))

(provide 'decknix-agent-dispatch)
;;; decknix-agent-dispatch.el ends here
