;;; decknix-agent-context-history-test.el --- Tests for context paging -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-context-history "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; Characterisation tests for the Context history paging primitives
;; carved from main-bulk in PR B.68.  The pure `-find-existing'
;; helper is exercised against synthetic buffers; the renderer is
;; exercised against a stub session-history layer (the upstream
;; `extract-all-turns', `window-clamp' and `take-window' helpers
;; are stubbed via `cl-letf').

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-context-history)

;; Forward-declared in the carved file (compiler hint only); tests
;; let-bind these so we re-declare with an initialiser to mark them
;; special variables -- see AGENTS.md "Lexical-binding tests,
;; dynamic free vars".
(defvar decknix-agent-session-history-count 2)
(defvar decknix--agent-context-header-map (make-sparse-keymap))

;; -- find-existing -----------------------------------------------

(ert-deftest decknix-context-find-existing--nil-when-no-section ()
  "Returns nil for a buffer with no `decknix-context-body' region."
  (with-temp-buffer
    (insert "Some plain content with no Context section.")
    (should (null (decknix--agent-context-find-existing)))))

(ert-deftest decknix-context-find-existing--locates-existing-region ()
  "Finds the body region and returns the three offsets as a plist."
  (with-temp-buffer
    (insert "▼ Context (1–2 / 5)\n")
    (let ((body-start (point)))
      (insert (propertize "body content here\n"
                          'decknix-context-body t))
      ;; Trailing content without the property so
      ;; `next-single-property-change' has a transition to find for
      ;; body-end.  In production this is always the prompt line.
      (insert "$ ")
      (let ((result (decknix--agent-context-find-existing)))
        (should result)
        (should (= (plist-get result :body-start) body-start))
        (should (> (plist-get result :body-end) body-start))
        (should (<= (plist-get result :header-start)
                    body-start))))))

;; -- render-window ------------------------------------------------

(ert-deftest decknix-context-render-window--nil-when-cache-empty ()
  "Empty cache produces no render and returns nil."
  (with-temp-buffer
    (setq-local decknix--agent-history-cache nil)
    (cl-letf (((symbol-function 'decknix--agent-session-window-clamp)
               (lambda (_c _n _t) 0))
              ((symbol-function 'decknix--agent-session-take-window)
               (lambda (_a _c _n) nil)))
      (should (null (decknix--agent-context-render-window 0))))))

(ert-deftest decknix-context-render-window--inserts-section-and-updates-cursor ()
  "Renders the section, sets cursor to the clamped value, returns
the cons (clamped . window-len)."
  (with-temp-buffer
    (insert "$ ")  ; mock prompt line
    (setq-local decknix--agent-history-cache
                '(("u1" . "r1") ("u2" . "r2") ("u3" . "r3")))
    (cl-letf (((symbol-function 'decknix--agent-session-window-clamp)
               (lambda (_c _n _t) 0))
              ((symbol-function 'decknix--agent-session-take-window)
               (lambda (_a _c _n)
                 '(("u1" . "r1") ("u2" . "r2")))))
      (let ((ret (decknix--agent-context-render-window 0)))
        (should (equal ret '(0 . 2)))
        (should (= decknix--agent-history-cursor 0))
        ;; Inserted section text shows up in the buffer.
        (should (string-match-p "Context (1–2 / 3)"
                                (buffer-string)))
        (should (string-match-p "u1" (buffer-string)))
        (should (string-match-p "r1" (buffer-string)))))))

(ert-deftest decknix-context-render-window--new-section-starts-collapsed ()
  "First render (no existing section) marks the body invisible."
  (with-temp-buffer
    (insert "$ ")
    (setq-local decknix--agent-history-cache
                '(("u" . "r")))
    (cl-letf (((symbol-function 'decknix--agent-session-window-clamp)
               (lambda (_c _n _t) 0))
              ((symbol-function 'decknix--agent-session-take-window)
               (lambda (_a _c _n) '(("u" . "r")))))
      (decknix--agent-context-render-window 0)
      (let* ((body-start (next-single-property-change
                          (point-min) 'decknix-context-body)))
        (should body-start)
        (should (get-text-property body-start 'invisible))))))

;; -- session-prepopulate ------------------------------------------

(ert-deftest decknix-session-prepopulate--noop-when-no-turns ()
  "When the session has no extractable turns, leaves the cache nil
and renders nothing."
  (with-temp-buffer
    (cl-letf (((symbol-function 'decknix--agent-session-extract-all-turns)
               (lambda (_sid) nil))
              ((symbol-function 'decknix--agent-session-window-clamp)
               (lambda (_c _n _t) 0)))
      (decknix--agent-session-prepopulate "sid" 2)
      (should (null decknix--agent-history-cache))
      (should (null decknix--agent-history-cursor))
      (should (zerop (buffer-size))))))

(ert-deftest decknix-session-prepopulate--seeds-cache-and-renders ()
  "Populates the cache, sets the buffer-local count, and renders
the bottom-most window (cursor = total - count)."
  (with-temp-buffer
    (insert "$ ")
    (let ((all '(("u1" . "r1") ("u2" . "r2") ("u3" . "r3")
                 ("u4" . "r4") ("u5" . "r5"))))
      (cl-letf (((symbol-function 'decknix--agent-session-extract-all-turns)
                 (lambda (_sid) all))
                ((symbol-function 'decknix--agent-session-window-clamp)
                 (lambda (cursor _count total)
                   (max 0 (min cursor total))))
                ((symbol-function 'decknix--agent-session-take-window)
                 (lambda (turns cursor count)
                   (let ((len (length turns)))
                     (cl-subseq turns
                                (min cursor len)
                                (min (+ cursor count) len))))))
        (decknix--agent-session-prepopulate "sid" 2)
        (should (equal decknix--agent-history-cache all))
        ;; Bottom-most window: cursor = total(5) - count(2) = 3.
        (should (= decknix--agent-history-cursor 3))
        ;; Buffer-local count survived the prepopulate.
        (should (= decknix-agent-session-history-count 2))))))

(provide 'decknix-agent-context-history-test)
;;; decknix-agent-context-history-test.el ends here
