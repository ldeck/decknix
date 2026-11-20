;;; decknix-agent-dispatch-control.el --- Arm or disarm the dispatch receiver by request -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-dispatch "0.1"))
;; Keywords: agent, agent-shell, decknix, dispatch

;;; Commentary:
;;
;; `decknix session dispatch on|off' drops a version 3 `dispatch' request
;; into agent-dispatch/control/.  This watcher claims it (rename to
;; <id>.claimed, so a second claimer loses and the receiver's crash
;; recovery, which scans inflight/, never sees it), applies it and writes
;; receipts/<id>.json.
;;
;;   op on   turns `decknix-agent-dispatch-mode' on, recording the sender as
;;           who armed it; refused (`remote-control-disabled') while
;;           `decknix-agent-dispatch-remote-control' is nil.
;;   op off  turns it off.  Always honoured: stopping delivery is never the
;;           risky direction.
;;
;; The same file checks as the receiver apply (exact UUID name, 0600, owned
;; by you, no symlink, bounded size), requests live at most
;; `decknix-agent-dispatch-control-max-ttl' seconds, and a request created
;; before this watcher started is refused, so an `on' queued while Emacs
;; was down cannot arm the receiver at startup.
;;
;; Unlike the receiver this watcher is meant to run by default (see the Nix
;; option `programs.emacs.decknix.agentShell.dispatch.remoteControl.enable'):
;; it only ever toggles the receiver, delivers nothing itself, and costs one
;; directory stat every `decknix-agent-dispatch-control-poll-interval'
;; seconds.  Installing the package still starts nothing.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'filenotify)
(require 'decknix-agent-dispatch)

(defcustom decknix-agent-dispatch-remote-control t
  "Non-nil lets a control request turn the dispatch receiver on.
A request to turn it off is honoured either way."
  :type 'boolean
  :group 'decknix-agent-dispatch)

(defvar decknix-agent-dispatch-control-poll-interval 5
  "Seconds between control/ checks; file-notify only makes one sooner.")

(defvar decknix-agent-dispatch-control-max-ttl 300
  "Longest lifetime in seconds a control request may claim.")

(defvar decknix-agent-dispatch-control-rescan-interval 60
  "Seconds after which control/ is listed even though its mtime is unchanged.")

(defvar decknix-agent-dispatch-control-arm-function #'decknix-agent-dispatch-control--arm
  "Called with (ON SOURCE RELEASE-QUEUED) to switch the receiver.")

(defvar decknix-agent-dispatch-control--started-at nil
  "Epoch second the watcher started; earlier requests are refused.")
(defvar decknix-agent-dispatch-control--timer nil)
(defvar decknix-agent-dispatch-control--watch nil)
(defvar decknix-agent-dispatch-control--seen nil
  "(MTIME . AT) of control/ when a listing last left nothing unread, or nil.")

(defun decknix-agent-dispatch-control--arm (on source release-queued)
  "Switch the receiver ON or off, recording SOURCE and RELEASE-QUEUED."
  (if on
      (let ((decknix-agent-dispatch-arming-source source)
            (decknix-agent-dispatch-arming-release-queued release-queued))
        (decknix-agent-dispatch-mode 1))
    (decknix-agent-dispatch-mode -1)))

(defun decknix-agent-dispatch-control--validate (req id now)
  "Return why control request REQ (file name ID) cannot be applied at NOW."
  (let ((from (plist-get req :from)))
    (cond
     ((not (and (consp req) (plistp req))) "malformed")
     ((not (eql 3 (plist-get req :v))) "bad-version")
     ((not (equal "dispatch" (plist-get req :kind))) "bad-kind")
     ((not (equal id (plist-get req :id))) "bad-id")
     ((not (member (plist-get req :op) '("on" "off"))) "bad-op")
     ((and from (not (decknix-agent-dispatch--uuid-p from))) "bad-from")
     ((decknix-agent-dispatch--times-bad req decknix-agent-dispatch-control-max-ttl now))
     ((and decknix-agent-dispatch-control--started-at
           (< (plist-get req :created_at) decknix-agent-dispatch-control--started-at))
      "predates-control"))))

(defun decknix-agent-dispatch-control--apply (req)
  "Apply validated REQ; return (STATE REASON OUTCOME)."
  (let ((on (bound-and-true-p decknix-agent-dispatch-mode))
        (from (plist-get req :from)))
    (if (equal "off" (plist-get req :op))
        (if (not on)
            '("accepted" nil "already-off")
          (funcall decknix-agent-dispatch-control-arm-function nil nil nil)
          (if (bound-and-true-p decknix-agent-dispatch-mode)
              '("unknown" "still-on" nil)
            '("accepted" nil "off")))
      (cond
       ((not decknix-agent-dispatch-remote-control)
        '("rejected" "remote-control-disabled" nil))
       (on '("accepted" nil "already-on"))
       (t
        (condition-case err
            (progn
              (funcall decknix-agent-dispatch-control-arm-function
                       t (if from (concat "control:" from) "control")
                       (eq t (plist-get req :release_queued)))
              (if (bound-and-true-p decknix-agent-dispatch-mode)
                  '("accepted" nil "on")
                '("rejected" "arm-failed" nil)))
          (error (list "rejected"
                       (truncate-string-to-width
                        (concat "arm-failed: " (error-message-string err)) 200)
                       nil))))))))

(defun decknix-agent-dispatch-control--process (id)
  "Claim, check and apply control request ID, then write its receipt."
  (let ((file (expand-file-name (concat id ".json") (decknix-agent-dispatch--sub "control")))
        (claimed (expand-file-name (concat id ".claimed") (decknix-agent-dispatch--sub "control"))))
    (when (condition-case nil (progn (rename-file file claimed nil) t) (error nil))
      (unwind-protect
          (cond
           ((decknix-agent-dispatch--receipt-exists-p id) nil)
           ((not (decknix-agent-dispatch--safe-file-p claimed))
            (decknix-agent-dispatch--write-receipt id nil "rejected" "unsafe-file"
                                                   (list :kind "dispatch")))
           (t
            (let* ((req (decknix-agent-dispatch--read-request claimed))
                   (bad (decknix-agent-dispatch-control--validate
                         req id (decknix-agent-dispatch--now)))
                   (info (list :kind "dispatch" :op (and (consp req) (plist-get req :op)))))
              (cond
               ((equal bad "expired")
                (decknix-agent-dispatch--write-receipt id nil "expired"
                                                       "expired-before-claim" info))
               (bad (decknix-agent-dispatch--write-receipt id nil "rejected" bad info))
               (t
                (pcase-let ((`(,state ,reason ,outcome)
                             (decknix-agent-dispatch-control--apply req)))
                  (decknix-agent-dispatch--write-receipt
                   id nil state reason
                   (append info (and outcome (list :outcome outcome))
                           (list :armed_by (plist-get (decknix-agent-dispatch-state)
                                                      :armed_by))))))))))
        (ignore-errors (delete-file claimed))))))

(defun decknix-agent-dispatch-control--ids ()
  (mapcar (lambda (f) (string-remove-suffix ".json" f))
          (directory-files (decknix-agent-dispatch--sub "control") nil
                           (concat "\\`" decknix-agent-dispatch--uuid-regexp "\\.json\\'"))))

(defun decknix-agent-dispatch-control--tick ()
  "Apply any new control request.  One stat when nothing changed."
  (condition-case err
      (let* ((attrs (file-attributes (decknix-agent-dispatch--sub "control")))
             (mtime (and attrs (file-attribute-modification-time attrs)))
             (now (float-time)))
        (unless (and mtime decknix-agent-dispatch-control--seen
                     (equal mtime (car decknix-agent-dispatch-control--seen))
                     (< (- now (cdr decknix-agent-dispatch-control--seen))
                        decknix-agent-dispatch-control-rescan-interval))
          (let ((ids (decknix-agent-dispatch-control--ids)))
            (setq decknix-agent-dispatch-control--seen
                  (and mtime (<= (length ids) 4) (cons mtime now)))
            (dolist (id (seq-take ids 4))
              (condition-case e
                  (decknix-agent-dispatch-control--process id)
                (error (message "decknix-agent-dispatch-control: %s: %s"
                                id (error-message-string e))))))))
    (error (message "decknix-agent-dispatch-control: tick failed: %s"
                    (error-message-string err)))))

(defun decknix-agent-dispatch-control--kick (&rest _)
  "File-notify callback: check control/ on the next tick of the event loop."
  (setq decknix-agent-dispatch-control--seen nil)
  (run-at-time 0.2 nil #'decknix-agent-dispatch-control--tick))

(defun decknix-agent-dispatch-control--start ()
  (decknix-agent-dispatch--ensure-dirs)
  (decknix-agent-dispatch--check-dirs)
  (setq decknix-agent-dispatch-control--started-at (decknix-agent-dispatch--now)
        decknix-agent-dispatch-control--seen nil)
  (setq decknix-agent-dispatch-control--timer
        (run-with-timer decknix-agent-dispatch-control-poll-interval
                        decknix-agent-dispatch-control-poll-interval
                        #'decknix-agent-dispatch-control--tick))
  (setq decknix-agent-dispatch-control--watch
        (ignore-errors
          (file-notify-add-watch (decknix-agent-dispatch--sub "control")
                                 '(change) #'decknix-agent-dispatch-control--kick))))

(defun decknix-agent-dispatch-control--stop ()
  (when decknix-agent-dispatch-control--timer
    (cancel-timer decknix-agent-dispatch-control--timer))
  (when decknix-agent-dispatch-control--watch
    (ignore-errors (file-notify-rm-watch decknix-agent-dispatch-control--watch)))
  (setq decknix-agent-dispatch-control--timer nil
        decknix-agent-dispatch-control--watch nil
        decknix-agent-dispatch-control--started-at nil))

;;;###autoload
(define-minor-mode decknix-agent-dispatch-control-mode
  "Let `decknix session dispatch on|off' switch the dispatch receiver.
While on, a control request in agent-dispatch/control/ can turn
`decknix-agent-dispatch-mode' on (unless `decknix-agent-dispatch-remote-control'
is nil) or off.  It never delivers anything itself."
  :global t
  :lighter nil
  :group 'decknix-agent-dispatch
  (if decknix-agent-dispatch-control-mode
      (condition-case err
          (decknix-agent-dispatch-control--start)
        (error (setq decknix-agent-dispatch-control-mode nil)
               (decknix-agent-dispatch-control--stop)
               (signal (car err) (cdr err))))
    (decknix-agent-dispatch-control--stop)))

(provide 'decknix-agent-dispatch-control)
;;; decknix-agent-dispatch-control.el ends here
