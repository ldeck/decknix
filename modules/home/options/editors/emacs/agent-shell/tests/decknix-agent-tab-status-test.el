;;; decknix-agent-tab-status-test.el --- Tests for tab-status tinting -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-tab-status "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests for the PURE layer: window-state buffer extraction (the
;; single-vs-multi window discriminator), status->colour lookup, and face
;; composition.  No live frames, tabs, or agent buffers.

;;; Code:

(require 'ert)
(require 'decknix-agent-tab-status)

;; -- window-state buffer extraction -------------------------------------

;; A realistic single-window state (as tab-bar stores in `ws'): size params,
;; then one `leaf' whose `buffer' entry names the shown buffer.
(defconst decknix-tab-status-test--ws-single
  '((min-height . 4) (min-width . 10)
    (leaf (last . t) (pixel-width . 1920) (pixel-height . 1080)
          (buffer "*Claude: dos/#449*" (selected . t) (hscroll . 0)
                  (point . 1) (start . 1)))))

;; A split (two windows) — a horizontal combination with two leaves.
(defconst decknix-tab-status-test--ws-split
  '((min-height . 4) (min-width . 10)
    (hc (pixel-width . 1920)
        (leaf (pixel-width . 960) (buffer "*Claude: a*" (selected . t)))
        (leaf (pixel-width . 960) (buffer "main.el" (selected . nil))))))

(ert-deftest decknix-tab-status/ws-single-window-one-name ()
  "A single-window state yields exactly one buffer name."
  (should (equal '("*Claude: dos/#449*")
                 (decknix--tab-ws-buffer-names decknix-tab-status-test--ws-single))))

(ert-deftest decknix-tab-status/ws-split-two-names ()
  "A two-window (split) state yields two buffer names."
  (should (= 2 (length (decknix--tab-ws-buffer-names
                        decknix-tab-status-test--ws-split))))
  (should (member "main.el"
                  (decknix--tab-ws-buffer-names decknix-tab-status-test--ws-split))))

(ert-deftest decknix-tab-status/ws-ignores-prev-next-buffers ()
  "prev-buffers/next-buffers entries are NOT counted as windows (no `buffer'
marker), so the window count stays accurate."
  (let ((ws '((leaf (buffer "*Claude: a*" (selected . t))
                    (prev-buffers ("old1" nil nil) ("old2" nil nil))
                    (next-buffers "old3")))))
    (should (equal '("*Claude: a*") (decknix--tab-ws-buffer-names ws)))))

(ert-deftest decknix-tab-status/ws-buffer-object-normalised ()
  "A buffer object (non-writable state) is normalised to its name."
  (with-temp-buffer
    (rename-buffer "*tab-status-obj-test*" t)
    (let ((ws (list (list 'leaf (cons 'buffer (list (current-buffer)))))))
      (should (equal (list (buffer-name))
                     (decknix--tab-ws-buffer-names ws))))))

(ert-deftest decknix-tab-status/ws-empty-nil ()
  "Empty / non-cons input yields nil, never an error."
  (should (null (decknix--tab-ws-buffer-names nil)))
  (should (null (decknix--tab-ws-buffer-names 'x)))
  (should (null (decknix--tab-ws-buffer-names '((min-height . 4))))))

;; -- status -> colour ---------------------------------------------------

(ert-deftest decknix-tab-status/background-known-and-unknown ()
  "Known statuses map to a colour; unknown / nil map to nil (no tint)."
  (should (equal "#3a1418" (decknix-agent-tab-status-background "waiting")))
  (should (equal "#3a330a" (decknix-agent-tab-status-background "working")))
  (should (null (decknix-agent-tab-status-background "bogus")))
  (should (null (decknix-agent-tab-status-background nil))))

(ert-deftest decknix-tab-status/default-palette-covers-every-status ()
  "Every status the sidebar can report has a tint.
A status with no entry silently renders as an untinted tab, which reads
as \"nothing to see here\" — the exact wrong signal for `asking'."
  (dolist (status '("working" "waiting" "asking" "ready"
                    "finished" "initializing" "killed"))
    (should (decknix-agent-tab-status-background status))))

(ert-deftest decknix-tab-status/background-honours-override ()
  "The colour alist is overridable; a nil value disables that status' tint."
  (let ((decknix-agent-tab-status-colors '(("working" . "#010203")
                                           ("waiting" . nil))))
    (should (equal "#010203" (decknix-agent-tab-status-background "working")))
    (should (null (decknix-agent-tab-status-background "waiting")))
    (should (null (decknix-agent-tab-status-background "ready")))))

;; -- face composition ---------------------------------------------------

(ert-deftest decknix-tab-status/face-neutral-without-bg ()
  "With no background the base tab face is returned unchanged."
  (should (eq 'tab-bar-tab (decknix--tab-status-face t nil)))
  (should (eq 'tab-bar-tab-inactive (decknix--tab-status-face nil nil))))

(ert-deftest decknix-tab-status/face-adds-background-inheriting-base ()
  "With a background the face inherits the correct base and sets :background."
  (let ((f (decknix--tab-status-face t "#3a1418")))
    (should (eq 'tab-bar-tab (plist-get f :inherit)))
    (should (equal "#3a1418" (plist-get f :background))))
  (let ((f (decknix--tab-status-face nil "#123010")))
    (should (eq 'tab-bar-tab-inactive (plist-get f :inherit)))
    (should (equal "#123010" (plist-get f :background)))))

(provide 'decknix-agent-tab-status-test)
;;; decknix-agent-tab-status-test.el ends here
