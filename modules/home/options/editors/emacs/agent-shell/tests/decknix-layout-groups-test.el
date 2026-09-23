;;; decknix-layout-groups-test.el --- Tests for saved layout groups -*- lexical-binding: t -*-

;;; Commentary:
;;
;; The window-state walker behind the attention model.  Rendering and the
;; interactive commands are exercised live; only the pure traversal is
;; unit-tested here per AGENTS.md Rule 2.

;;; Code:

(require 'ert)
(require 'decknix-layout-groups)

;; --- the walker must not recurse into window PARAMETERS ---------------
;;
;; `M-x decknix-layout-group-switch' failed outright with
;;
;;     (wrong-type-argument listp 1724)
;;
;; and so did every other entry point, because the reader sorts candidates
;; by attention and the sort calls the same walker.  Three saved groups,
;; all three throwing, no way to pick one.
;;
;; A window-state node's cdr mixes CHILD NODES with PARAMETER PAIRS:
;;
;;     (hc (min-height . 8) (min-pixel-width . 1724) (leaf ...) (leaf ...))
;;
;; The walker recursed over the whole cdr, so it reached
;; `(min-pixel-width . 1724)', found its car was not `leaf', and ran
;; `(dolist (child 1724))'.

(defconst decknix-layout-test--state
  '(hc
    (min-height . 8)
    (min-width . 20)
    (min-pixel-width . 1724)
    (leaf (pixel-width . 860) (buffer "alpha" (selected . t)))
    (vc
     (min-height . 4)
     (leaf (pixel-width . 860) (buffer "beta" (selected . nil)))
     (leaf (pixel-width . 860) (buffer "gamma" (selected . nil)))))
  "A window state shaped like the real ones: parameters beside children.")

(ert-deftest decknix-layout-walker--survives-numeric-parameters ()
  "Parameter pairs must not be walked as if they were nodes."
  (should (listp (decknix-layout-group--state-buffers
                  decknix-layout-test--state))))

(ert-deftest decknix-layout-walker--finds-every-leaf-buffer ()
  "Nested splits are reached; only buffers that exist are returned."
  (let ((a (get-buffer-create "alpha"))
        (b (get-buffer-create "beta")))
    (unwind-protect
        (let ((found (decknix-layout-group--state-buffers
                      decknix-layout-test--state)))
          (should (memq a found))
          (should (memq b found))
          ;; `gamma' was never created, so it is absent rather than nil.
          (should (= 2 (length found))))
      (kill-buffer a)
      (kill-buffer b))))

(ert-deftest decknix-layout-walker--empty-and-degenerate-states ()
  "A nil or atom state yields nothing rather than signalling."
  (should-not (decknix-layout-group--state-buffers nil))
  (should-not (decknix-layout-group--state-buffers 'leaf))
  (should-not (decknix-layout-group--state-buffers '(hc))))

(ert-deftest decknix-layout-walker--buffer-entry-may-be-a-bare-string ()
  "`window-state-get' writes either (buffer NAME . PARAMS) or a name."
  (let ((a (get-buffer-create "alpha")))
    (unwind-protect
        (should (memq a (decknix-layout-group--state-buffers
                         '(leaf (buffer . "alpha")))))
      (kill-buffer a))))

(provide 'decknix-layout-groups-test)
;;; decknix-layout-groups-test.el ends here
