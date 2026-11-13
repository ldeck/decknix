;;; decknix-layout-restart-test.el --- Restart initiated by the CLI -*- lexical-binding: t -*-

;;; Commentary:
;;
;; `decknix switch --restart-emacs' talks to the daemon through files: a
;; ready file after the save, a one-shot marker that makes the next first
;; frame restore without asking, and a summary the command prints.  These
;; pin that contract, plus the compose draft and prompt queue that now
;; travel with a session across the restart.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'decknix-layout-persist)

(defvar decknix--compose-queued-prompt nil)
(defvar decknix--compose-target-buffer nil)

(defmacro decknix-restart-test--in-dir (&rest body)
  (declare (indent 0))
  `(let* ((dir (make-temp-file "dk-restart-" t))
          (decknix-layout-restart-marker-file (expand-file-name "marker" dir))
          (decknix-layout-restart-summary-file (expand-file-name "summary.json" dir))
          (decknix-layout-persist-file (expand-file-name "layout.el" dir))
          (decknix-layout--last-written nil)
          (decknix-layout--rotated nil))
     (unwind-protect (progn ,@body)
       (delete-directory dir t))))

;; -- the marker is one-shot and expires ----------------------------------------

(ert-deftest decknix-restart/marker-acts-once ()
  (decknix-restart-test--in-dir
    (with-temp-file decknix-layout-restart-marker-file (insert "1"))
    (should (decknix-layout--consume-restart-marker))
    (should-not (file-exists-p decknix-layout-restart-marker-file))
    (should-not (decknix-layout--consume-restart-marker))))

(ert-deftest decknix-restart/stale-marker-is-ignored-and-removed ()
  (decknix-restart-test--in-dir
    (with-temp-file decknix-layout-restart-marker-file (insert "1"))
    (should-not (decknix-layout--consume-restart-marker
                 nil (+ (float-time) decknix-layout-restart-marker-max-age 1)))
    (should-not (file-exists-p decknix-layout-restart-marker-file))))

(ert-deftest decknix-restart/marker-offers-even-when-restore-is-off ()
  "The command's intent outranks `decknix-layout-restore-on-start' nil."
  (decknix-restart-test--in-dir
    (with-temp-file decknix-layout-restart-marker-file (insert "1"))
    (let ((decknix-layout--offered nil)
          (decknix-layout-restore-on-start nil)
          (noninteractive nil)
          (scheduled nil))
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                ((symbol-function 'run-with-idle-timer)
                 (lambda (_secs _rep fn &rest args) (setq scheduled (cons fn args)))))
        (decknix-layout--maybe-offer))
      (should (eq (car scheduled) #'decknix-layout--offer-safely))
      (should (eq (nth 2 scheduled) t)))))

(ert-deftest decknix-restart/no-marker-and-restore-off-offers-nothing ()
  (decknix-restart-test--in-dir
    (let ((decknix-layout--offered nil)
          (decknix-layout-restore-on-start nil)
          (noninteractive nil)
          (scheduled nil))
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                ((symbol-function 'run-with-idle-timer)
                 (lambda (&rest args) (setq scheduled args))))
        (decknix-layout--maybe-offer))
      (should-not scheduled))))

(ert-deftest decknix-restart/restart-offer-restores-with-sessions-unasked ()
  (decknix-restart-test--in-dir
    (with-temp-file decknix-layout-persist-file
      (prin1 (list :version decknix-layout--version :saved-at (float-time)
                   :buffers nil :frames (list (list :tabs nil)))
             (current-buffer)))
    (let ((decknix-layout-restore-on-start 'ask) (called nil))
      (cl-letf (((symbol-function 'decknix-layout-restore)
                 (lambda (prev sessions) (setq called (list prev sessions))))
                ((symbol-function 'read-char-choice)
                 (lambda (&rest _) (error "must not prompt")))
                ((symbol-function 'decknix-layout--schedule-restart-summary) #'ignore))
        (decknix-layout--offer (selected-frame) t))
      (should (equal called '(nil t))))))

;; -- prepare: returns at once, then writes the ready file -----------------------

(ert-deftest decknix-restart/prepare-returns-before-saving ()
  (decknix-restart-test--in-dir
    (let* ((ready (expand-file-name "ready.json" (file-name-directory decknix-layout-persist-file)))
           (timer nil))
      (cl-letf (((symbol-function 'run-with-timer)
                 (lambda (_s _r fn &rest args) (setq timer (cons fn args)))))
        (should (decknix-layout-prepare-restart ready)))
      (should-not (file-exists-p ready))
      (apply (car timer) (cdr timer))
      (let ((data (json-read-file ready)))
        (should (assq 'saved data))
        (should (assq 'sessions data))))))

;; -- summary ------------------------------------------------------------------

(ert-deftest decknix-restart/summary-data-names-what-came-back-and-what-did-not ()
  (let* ((data (decknix-layout--restart-summary-data
                (list :summary "1 frame, 2 tabs, 3 sessions" :resumed 2 :missing 0
                      :failed '(("*Claude: gone*" . "no session")))
                (list (list :name "*Claude: a*" :status "working" :history 3 :permission t))
                (list :done 2 :no-conv 1 :dropped 0)))
         (json (json-read-from-string (json-encode data))))
    (should (equal (alist-get 'layout json) "1 frame, 2 tabs, 3 sessions"))
    (should (equal (alist-get 'resumed json) 2))
    (should (equal (alist-get 'name (aref (alist-get 'failed json) 0)) "*Claude: gone*"))
    (let ((s (aref (alist-get 'sessions json) 0)))
      (should (equal (alist-get 'historyTurns s) 3))
      (should (eq (alist-get 'permission s) t)))
    (should (equal (alist-get 'noConversation (alist-get 'reattach json)) 1))))

(ert-deftest decknix-restart/summary-waits-for-the-reattach-sweep ()
  (let ((decknix-agent-broker-reattach-delay 12))
    (should (= (decknix-layout--summary-delay 0) 22))
    (should (= (decknix-layout--summary-delay 100) 3))))

(ert-deftest decknix-restart/write-summary-is-readable-json ()
  (decknix-restart-test--in-dir
    (let ((decknix-layout--last-restore (list :summary "x" :resumed 1)))
      (decknix-layout-write-restart-summary)
      (should (equal (alist-get 'layout (json-read-file decknix-layout-restart-summary-file))
                     "x")))))

;; -- the compose draft and queue travel with the session --------------------------

(ert-deftest decknix-restart/queue-and-draft-values ()
  (should (equal (decknix-layout--queue-value "one") '("one")))
  (should (equal (decknix-layout--queue-value '("a" "  " nil "b")) '("a" "b")))
  (should-not (decknix-layout--draft-text " \n\t"))
  (should (equal (decknix-layout--draft-text "x") "x")))

(ert-deftest decknix-restart/extras-capture-queue-and-draft ()
  (let ((agent (generate-new-buffer "*Claude: s*")) compose)
    (unwind-protect
        (progn
          (with-current-buffer agent (setq-local decknix--compose-queued-prompt '("next")))
          (setq compose (get-buffer-create "*Compose: *Claude: s**"))
          (with-current-buffer compose (insert "half written"))
          (should (equal (decknix-layout--agent-extras agent)
                         '(:queue ("next") :draft "half written"))))
      (kill-buffer agent) (when compose (kill-buffer compose)))))

(ert-deftest decknix-restart/apply-extras-restores-without-overwriting-or-sending ()
  (let ((agent (generate-new-buffer "*Claude: r*")) (made nil))
    (unwind-protect
        (cl-letf (((symbol-function 'decknix--compose-create-buffer)
                   (lambda (target &optional name)
                     (setq made (get-buffer-create
                                 (or name (format "*Compose: %s*" (buffer-name target))))))))
          (should (decknix-layout--apply-extras agent '(:queue ("q1" "q2") :draft "draft")))
          (should (equal (buffer-local-value 'decknix--compose-queued-prompt agent) '("q1" "q2")))
          (should (equal (with-current-buffer made (buffer-string)) "draft"))
          ;; A second application does not clobber what is there now.
          (with-current-buffer agent (setq-local decknix--compose-queued-prompt '("mine")))
          (decknix-layout--apply-extras agent '(:queue ("old") :draft "other"))
          (should (equal (buffer-local-value 'decknix--compose-queued-prompt agent) '("mine")))
          (should (equal (with-current-buffer made (buffer-string)) "draft")))
      (kill-buffer agent) (when made (kill-buffer made)))))

(ert-deftest decknix-restart/compose-follows-the-placeholder-to-its-session ()
  (let ((ph (generate-new-buffer "*Resume: s*"))
        (target (generate-new-buffer "*Claude: s*"))
        (compose (generate-new-buffer "*Compose: *Resume: s**")))
    (unwind-protect
        (progn
          (with-current-buffer compose (setq-local decknix--compose-target-buffer ph))
          (decknix-layout--retarget-compose ph target)
          (should (eq (buffer-local-value 'decknix--compose-target-buffer compose) target))
          (should (equal (buffer-name compose) "*Compose: *Claude: s**")))
      (mapc #'kill-buffer (list ph target compose)))))

(provide 'decknix-layout-restart-test)
;;; decknix-layout-restart-test.el ends here
