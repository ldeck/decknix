;;; decknix-session-urls-ui-test.el --- Tests for session URL commands and review mode -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Specification tests for `decknix-session-urls-ui': the cached,
;; bounded collection over a buffer, identity gathering, cycling,
;; action dispatch (with `browse-url' and `kill-new' stubbed), the
;; review-session letter keys and the mode's auto-enable rule.  A stand-in
;; `agent-shell-mode' is defined when the real one is not loaded.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-session-urls-ui)

(unless (fboundp 'agent-shell-mode)
  (define-derived-mode agent-shell-mode fundamental-mode "AgentShell"
    "Stand-in for agent-shell in tests."))

(defvar decknix--agent-conv-key nil)

(defmacro decknix-session-urls-test--in-session (text &rest body)
  "Run BODY in a fresh `agent-shell-mode' buffer holding TEXT, point at end."
  (declare (indent 1))
  `(with-temp-buffer
     (agent-shell-mode)
     (insert ,text)
     ,@body))

(defmacro decknix-session-urls-test--stub-actions (&rest body)
  "Run BODY with `browse-url' and `kill-new' recording into `opened'/`copied'."
  `(let (opened copied)
     (cl-letf (((symbol-function 'browse-url) (lambda (url &rest _) (push url opened)))
               ((symbol-function 'kill-new) (lambda (s &rest _) (push s copied))))
       ,@body)))

(defconst decknix-session-urls-test--text
  (concat "intro https://example.com/one\n"
          "middle https://github.com/acme/widget/pull/7\n"
          "last https://example.com/three\n"
          "> "))

;; ── collection over a buffer ─────────────────────────────────────────

(ert-deftest decknix-session-urls-ui-entries-cached-until-output ()
  (decknix-session-urls-test--in-session decknix-session-urls-test--text
    (let ((a (decknix-session-urls-entries)))
      (should (eq a (decknix-session-urls-entries)))
      (goto-char (point-max))
      (insert "\nnew https://example.com/four\n")
      (let ((b (decknix-session-urls-entries)))
        (should-not (eq a b))
        (should (equal "https://example.com/four" (plist-get (car b) :url)))))))

(ert-deftest decknix-session-urls-ui-entries-scan-is-bounded ()
  (decknix-session-urls-test--in-session
      (concat "old https://example.com/old\n" (make-string 500 ?x) "\nnew https://example.com/new\n")
    (let ((decknix-session-urls-scan-limit 100))
      (should (equal '("https://example.com/new")
                     (mapcar (lambda (e) (plist-get e :url)) (decknix-session-urls-entries)))))))

(ert-deftest decknix-session-urls-ui-identity-reviewed-linked-created ()
  (decknix-session-urls-test--in-session "nothing here\n"
    (setq-local decknix--agent-conv-key "conv-1")
    (setq-local decknix--agent-broker-key "broker-1")
    (cl-letf (((symbol-function 'decknix--agent-review-prs-for-conv-key)
               (lambda (_) '("acme/widget#460")))
              ((symbol-function 'decknix--agent-linked-prs)
               (lambda (_) '(((url . "https://github.com/acme/gadget/pull/3") (type . "subject")))))
              ((symbol-function 'decknix--agent-pr-url-accessor)
               (lambda (rec field) (alist-get (intern field) rec)))
              ((symbol-function 'decknix-session-assoc-created)
               (lambda (_) '("acme/widget#461"))))
      (let ((entries (decknix-session-urls-entries)))
        (should (equal '(reviewing linked created)
                       (mapcar (lambda (e) (plist-get e :source)) entries)))
        (should (equal "https://github.com/acme/widget/pull/460"
                       (plist-get (car entries) :url)))))))

;; ── cycling ──────────────────────────────────────────────────────────

(ert-deftest decknix-session-urls-ui-cycle-previous-from-prompt-then-next-wraps ()
  (decknix-session-urls-test--in-session decknix-session-urls-test--text
    (goto-char (point-max))
    (should (equal "https://example.com/three" (decknix-session-urls-step -1)))
    (should (looking-at "https://example.com/three"))
    (should (equal "https://example.com/three" (decknix-session-urls-at-point)))
    (should (equal "https://github.com/acme/widget/pull/7" (decknix-session-urls-step -1)))
    (should (looking-at "https://github.com/acme/widget/pull/7"))
    (should (equal "https://example.com/three" (decknix-session-urls-step 1)))
    ;; Past the last URL, next wraps to the first.
    (should (equal "https://example.com/one" (decknix-session-urls-step 1)))
    (should (looking-at "https://example.com/one"))
    ;; And previous from the first wraps to the last.
    (should (equal "https://example.com/three" (decknix-session-urls-step -1)))))

(ert-deftest decknix-session-urls-ui-cycle-highlights-and-unhighlights ()
  (decknix-session-urls-test--in-session decknix-session-urls-test--text
    (goto-char (point-max))
    (decknix-session-urls-step -1)
    (should (overlayp decknix-session-urls--overlay))
    (should (= (point) (overlay-start decknix-session-urls--overlay)))
    (decknix-session-urls-unhighlight)
    (should (null decknix-session-urls--overlay))))

(ert-deftest decknix-session-urls-ui-cycle-from-inside-a-url-skips-it ()
  (decknix-session-urls-test--in-session decknix-session-urls-test--text
    (goto-char (point-min))
    (search-forward "example.com/o")
    (should (equal "https://github.com/acme/widget/pull/7" (decknix-session-urls-step 1)))))

(ert-deftest decknix-session-urls-ui-cycle-nil-without-urls ()
  (decknix-session-urls-test--in-session "no links at all\n"
    (should (null (decknix-session-urls-step 1)))))

;; ── actions ──────────────────────────────────────────────────────────

(ert-deftest decknix-session-urls-ui-dispatch-browse-copy-markdown ()
  (decknix-session-urls-test--stub-actions
   (let ((e (decknix-session-urls-classify "https://github.com/acme/widget/pull/7")))
     (decknix-session-urls-dispatch 'browse e)
     (decknix-session-urls-dispatch 'copy e)
     (decknix-session-urls-dispatch 'markdown e)
     (decknix-session-urls-dispatch 'files e)
     (decknix-session-urls-dispatch 'checks e)
     (should (equal '("https://github.com/acme/widget/pull/7/checks"
                      "https://github.com/acme/widget/pull/7/files"
                      "https://github.com/acme/widget/pull/7")
                    opened))
     (should (equal '("[widget#7](https://github.com/acme/widget/pull/7)"
                      "https://github.com/acme/widget/pull/7")
                    copied)))))

(ert-deftest decknix-session-urls-ui-dispatch-pr-actions-refuse-non-prs ()
  (decknix-session-urls-test--stub-actions
   (let ((e (decknix-session-urls-classify "https://example.com/x")))
     (should-error (decknix-session-urls-dispatch 'files e) :type 'user-error)
     (should-error (decknix-session-urls-dispatch 'board e) :type 'user-error)
     (should (null opened)))))

(ert-deftest decknix-session-urls-ui-dispatch-jira-opens-the-ticket ()
  (decknix-session-urls-test--stub-actions
   (decknix-session-urls-dispatch
    'jira (decknix-session-urls-classify "https://t.example/browse/ABC-1"))
   (should (equal '("https://t.example/browse/ABC-1") opened))))

(ert-deftest decknix-session-urls-ui-open-current-uses-url-at-point ()
  (decknix-session-urls-test--stub-actions
   (decknix-session-urls-test--in-session decknix-session-urls-test--text
     (goto-char (point-max))
     (decknix-session-urls-step -1)
     (decknix-session-url-open-current)
     (should (equal '("https://example.com/three") opened)))))

(ert-deftest decknix-session-urls-ui-bind-session-keys ()
  (let ((map (decknix-session-urls-bind-session-keys (make-sparse-keymap))))
    (should (eq 'decknix-session-url-open (lookup-key map (kbd "O"))))
    (should (eq 'decknix-session-url-act (lookup-key map (kbd "U"))))
    (should (eq 'decknix-session-url-previous (lookup-key map (kbd "<"))))
    (should (eq 'decknix-session-url-next (lookup-key map (kbd ">"))))))

;; ── review-session mode ──────────────────────────────────────────────

(ert-deftest decknix-review-session-mode-auto-enables-for-reviews-only ()
  (cl-letf (((symbol-function 'decknix--agent-review-prs-for-conv-key)
             (lambda (ck) (when (equal ck "review-conv") '("widget#460")))))
    (decknix-session-urls-test--in-session ""
      (setq-local decknix--agent-conv-key "review-conv")
      (decknix-review-session-maybe-enable)
      (should decknix-review-session-mode)
      (should (string-match-p "widget#460" decknix-review-session--lighter)))
    (decknix-session-urls-test--in-session ""
      (setq-local decknix--agent-conv-key "plain-conv")
      (decknix-review-session-maybe-enable)
      (should-not decknix-review-session-mode))
    ;; Not an agent-shell buffer: never, whatever its identity.
    (with-temp-buffer
      (setq-local decknix--agent-conv-key "review-conv")
      (decknix-review-session-maybe-enable)
      (should-not decknix-review-session-mode))
    ;; Respects the opt-out.
    (decknix-session-urls-test--in-session ""
      (setq-local decknix--agent-conv-key "review-conv")
      (let ((decknix-review-session-auto-enable nil))
        (decknix-review-session-maybe-enable))
      (should-not decknix-review-session-mode))))

(ert-deftest decknix-review-session-mode-name-fallback ()
  (decknix-session-urls-test--in-session ""
    (rename-buffer "*Agent: auto/#12/widget/review*" t)
    (decknix-review-session-maybe-enable)
    (should decknix-review-session-mode)))

(ert-deftest decknix-review-session-letters-insert-at-prompt ()
  (decknix-session-urls-test--in-session "> "
    (decknix-review-session-mode 1)
    (let ((called nil))
      (cl-letf (((symbol-function 'decknix-review-session-open-pr)
                 (lambda () (interactive) (setq called t))))
        (cl-letf (((symbol-function 'decknix-review-session--typing-p) (lambda () t)))
          (let ((last-command-event ?o))
            (decknix-review-session-key))
          (should (equal "> o" (buffer-string)))
          (should-not called))
        (cl-letf (((symbol-function 'decknix-review-session--typing-p) (lambda () nil)))
          (let ((last-command-event ?o))
            (decknix-review-session-key))
          (should called)
          (should (equal "> o" (buffer-string))))))))

(ert-deftest decknix-review-session-keys-do-not-shadow-agent-shell ()
  ;; agent-shell binds these single keys in the transcript; the mode must not.
  (dolist (k '("n" "p" "r" "+" "-" "0" "TAB"))
    (should-not (lookup-key decknix-review-session-mode-map (kbd k))))
  ;; Nor the upstream / comint chords.
  (dolist (k '("C-c C-c" "C-c C-m" "C-c C-v" "C-c C-t" "C-c C-o" "C-c C-s"
               "C-c C-p" "C-c C-n" "C-c C-r" "C-c C-e" "C-c C-u" "C-c C-l"))
    (should-not (lookup-key decknix-review-session-mode-map (kbd k)))))

(ert-deftest decknix-review-session-open-pr-prefers-reviewed ()
  (decknix-session-urls-test--stub-actions
   (decknix-session-urls-test--in-session "Opened https://github.com/acme/widget/pull/9\n"
     (setq-local decknix--agent-conv-key "c")
     (cl-letf (((symbol-function 'decknix--agent-review-prs-for-conv-key)
                (lambda (_) '("acme/widget#460"))))
       (decknix-review-session-open-pr)
       (decknix-review-session-files)
       (should (equal '("https://github.com/acme/widget/pull/460/files"
                        "https://github.com/acme/widget/pull/460")
                      opened))))))

(ert-deftest decknix-review-session-reply-uses-board-quick-reply ()
  (decknix-session-urls-test--in-session ""
    (let (sent)
      (cl-letf (((symbol-function 'decknix-agent-turn-quick-reply)
                 (lambda (buf key) (push (cons buf key) sent) t))
                ((symbol-function 'decknix-agent-turn-reply-key)
                 (lambda (ev) (cond ((eq ev ?y) 'yes) ((eq ev ?2) 2)))))
        (let ((last-command-event ?2))
          (decknix-review-session-reply))
        (should (equal (list (cons (current-buffer) 2)) sent))))))

(provide 'decknix-session-urls-ui-test)
;;; decknix-session-urls-ui-test.el ends here
