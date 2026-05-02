;;; decknix-progress-ui-test.el --- Characterisation tests for decknix-progress-ui -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-progress-ui "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests pinning the current behaviour of the rendering helpers in
;; `decknix-progress-ui'.  Focus is on the pure helper layer (glyphs,
;; faces, grouping, summary, fold state) — the buffer renderer itself
;; is exercised indirectly through these and through future snapshot
;; tests.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-test-helpers)
(require 'decknix-progress)
(require 'decknix-progress-ui)

;; -- Glyphs ----------------------------------------------------------

(ert-deftest decknix-progress--state-glyph/known-states ()
  (should (equal "☐" (decknix-progress--state-glyph 'todo)))
  (should (equal "◐" (decknix-progress--state-glyph 'wip)))
  (should (equal "⊘" (decknix-progress--state-glyph 'blocked)))
  (should (equal "☒" (decknix-progress--state-glyph 'done)))
  (should (equal "·" (decknix-progress--state-glyph 'neutral)))
  (should (equal "·" (decknix-progress--state-glyph nil))))

(ert-deftest decknix-progress--attention-glyph/dot-or-fallback ()
  (should (equal "●" (decknix-progress--attention-glyph 'red)))
  (should (equal "●" (decknix-progress--attention-glyph 'amber)))
  (should (equal "●" (decknix-progress--attention-glyph 'green)))
  (should (equal "·" (decknix-progress--attention-glyph 'none)))
  (should (equal "·" (decknix-progress--attention-glyph nil))))

;; -- Faces -----------------------------------------------------------

(ert-deftest decknix-progress--attention-face/maps-to-faces ()
  (should (eq 'decknix-progress-attention-red
              (decknix-progress--attention-face 'red)))
  (should (eq 'decknix-progress-attention-amber
              (decknix-progress--attention-face 'amber)))
  (should (eq 'decknix-progress-attention-green
              (decknix-progress--attention-face 'green)))
  (should (eq 'decknix-progress-attention-none
              (decknix-progress--attention-face 'none)))
  (should (eq 'decknix-progress-attention-none
              (decknix-progress--attention-face nil))))

(ert-deftest decknix-progress--title-face/done-and-blocked-only ()
  (should (eq 'decknix-progress-state-done
              (decknix-progress--title-face 'done)))
  (should (eq 'decknix-progress-state-blocked
              (decknix-progress--title-face 'blocked)))
  (should (null (decknix-progress--title-face 'wip)))
  (should (null (decknix-progress--title-face 'todo)))
  (should (null (decknix-progress--title-face nil))))

(ert-deftest decknix-progress--provider-label/known-and-fallback ()
  (should (equal (alist-get 'pr   decknix-progress-provider-labels)
                 (decknix-progress--provider-label 'pr)))
  (should (equal (alist-get 'jira decknix-progress-provider-labels)
                 (decknix-progress--provider-label 'jira)))
  ;; Unknown provider falls back to the symbol name.
  (should (equal "linear" (decknix-progress--provider-label 'linear)))
  (should (equal "unknown" (decknix-progress--provider-label nil))))

;; -- Grouping --------------------------------------------------------

(ert-deftest decknix-progress--group-by-provider/preserves-order ()
  (let* ((items (list (list :provider 'pr   :id "p1")
                      (list :provider 'jira :id "j1")
                      (list :provider 'pr   :id "p2")
                      (list :provider 'todo :id "t1")
                      (list :provider 'jira :id "j2")))
         (groups (decknix-progress--group-by-provider items)))
    (should (equal '(pr jira todo) (mapcar #'car groups)))
    (should (equal '("p1" "p2")
                   (mapcar (lambda (it) (plist-get it :id))
                           (alist-get 'pr groups))))
    (should (equal '("j1" "j2")
                   (mapcar (lambda (it) (plist-get it :id))
                           (alist-get 'jira groups))))))

(ert-deftest decknix-progress--group-by-provider/missing-provider-becomes-unknown ()
  (let* ((items (list (list :id "x") (list :provider 'pr :id "y")))
         (groups (decknix-progress--group-by-provider items)))
    (should (equal '(unknown pr) (mapcar #'car groups)))))

;; -- Counts ----------------------------------------------------------

(ert-deftest decknix-progress--count-summary/recurses ()
  (let ((items (list (list :state 'wip
                           :children (list (list :state 'done)
                                           (list :state 'todo
                                                 :children
                                                 (list (list :state 'done)))))
                     (list :state 'done))))
    ;; Total = root1 + child1 + child2 + grandchild + root2 = 5
    ;; Done  = grandchild + child1 + root2 = 3
    (should (equal '(3 . 5) (decknix-progress--count-summary items)))))

(ert-deftest decknix-progress--count-summary/empty-is-zero-zero ()
  (should (equal '(0 . 0) (decknix-progress--count-summary nil))))

;; -- Fold state ------------------------------------------------------
;; `decknix-progress--fold-state' is `defvar-local'; tests run inside
;; a temp buffer so the buffer-local binding is what gets read.

(ert-deftest decknix-progress--folded-p/honours-table-when-set ()
  (with-temp-buffer
    (setq decknix-progress--fold-state (make-hash-table :test 'equal))
    (puthash "id-1" t   decknix-progress--fold-state)
    (puthash "id-2" nil decknix-progress--fold-state)
    (should (eq t   (decknix-progress--folded-p "id-1" nil)))
    (should (eq nil (decknix-progress--folded-p "id-2" t)))
    ;; Untouched keys fall through to DEFAULT.
    (should (eq t   (decknix-progress--folded-p "missing" t)))
    (should (eq nil (decknix-progress--folded-p "missing" nil)))))

(ert-deftest decknix-progress--folded-p/nil-table-falls-back ()
  (with-temp-buffer
    (setq decknix-progress--fold-state nil)
    (should (eq t   (decknix-progress--folded-p "x" t)))
    (should (eq nil (decknix-progress--folded-p "x" nil)))))

;; -- Mode + keymap ---------------------------------------------------

(ert-deftest decknix-progress-mode-map/has-expected-bindings ()
  (should (eq 'decknix-progress-toggle
              (lookup-key decknix-progress-mode-map (kbd "TAB"))))
  (should (eq 'decknix-progress-open-at-point
              (lookup-key decknix-progress-mode-map (kbd "RET"))))
  (should (eq 'decknix-progress-refresh
              (lookup-key decknix-progress-mode-map (kbd "g"))))
  (should (eq 'decknix-progress-next-item
              (lookup-key decknix-progress-mode-map (kbd "n"))))
  (should (eq 'decknix-progress-previous-item
              (lookup-key decknix-progress-mode-map (kbd "p"))))
  (should (eq 'quit-window
              (lookup-key decknix-progress-mode-map (kbd "q")))))

(provide 'decknix-progress-ui-test)
;;; decknix-progress-ui-test.el ends here
