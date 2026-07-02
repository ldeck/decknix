;;; decknix-agent-header-test.el --- Tests for header-line builder -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-header "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; Characterisation tests for the unified header-line builder.
;; The pure helpers (status icon / face tables, status detection,
;; tags lookup, workspace abbreviation, build composition) are
;; exercised directly; the timer + buffer-local update are tested
;; via stubbed `run-with-timer' and `cancel-timer' so the suite
;; never touches a live timer queue.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-header)

;; Carved module forward-declares these as `defvar'-without-value
;; (compiler hint only).  The let-binding pattern in the tests
;; needs the variable globally bound, so re-declare with an
;; initialiser here.  See AGENTS.md "Lexical-binding tests,
;; dynamic free vars".
(defvar decknix--agent-conv-key nil)
(defvar decknix--agent-auggie-session-id nil)
(defvar decknix--agent-session-workspace nil)
(defvar shell-maker--busy nil)
(defvar agent-shell--state nil)

;; -- Status detection --------------------------------------------

(ert-deftest decknix-header-detect-status--prefers-workspace-detection ()
  "When `agent-shell-workspace--buffer-status' is bound, dispatches
to it instead of the shell-maker fallback."
  (cl-letf (((symbol-function 'agent-shell-workspace--buffer-status)
             (lambda (_buf) "waiting")))
    (with-temp-buffer
      (should (equal (decknix--header-detect-status) "waiting")))))

(ert-deftest decknix-header-detect-status--falls-back-to-shell-maker-busy ()
  "Without the workspace helper, `shell-maker--busy' = t -> working."
  (cl-letf (((symbol-function 'agent-shell-workspace--buffer-status) nil))
    (fmakunbound 'agent-shell-workspace--buffer-status)
    (with-temp-buffer
      (let ((shell-maker--busy t))
        (should (equal (decknix--header-detect-status) "working"))))))

(ert-deftest decknix-header-detect-status--killed-when-no-process ()
  "No live process and no busy flag -> killed."
  (cl-letf (((symbol-function 'agent-shell-workspace--buffer-status) nil))
    (fmakunbound 'agent-shell-workspace--buffer-status)
    (with-temp-buffer
      (let ((shell-maker--busy nil))
        (should (equal (decknix--header-detect-status) "killed"))))))

;; -- Icon / face tables ------------------------------------------

(ert-deftest decknix-header-status-icon--shape-family-mapping ()
  "Icons follow the Circle shape-family system.
○ = pre-active, ◐ = in-progress, ● = settled."
  (should (equal (decknix--header-status-icon "ready")        "●"))
  (should (equal (decknix--header-status-icon "finished")     "●"))
  (should (equal (decknix--header-status-icon "working")      "◐"))
  (should (equal (decknix--header-status-icon "waiting")      "◐"))
  (should (equal (decknix--header-status-icon "initializing") "○"))
  (should (equal (decknix--header-status-icon "killed")       "●"))
  (should (equal (decknix--header-status-icon "garbage")      "○")))

(ert-deftest decknix-header-status-face--colour-semantics ()
  "Faces follow the colour-semantic system.
green = ready, cyan = finished, yellow = working, red = blocked/killed,
grey = initializing/unknown."
  (should (eq   (decknix--header-status-face "ready")        'success))
  (should (equal (decknix--header-status-face "finished")     '(:foreground "cyan" :weight bold)))
  (should (eq   (decknix--header-status-face "working")      'warning))
  (should (eq   (decknix--header-status-face "waiting")      'error))
  (should (eq   (decknix--header-status-face "initializing") 'shadow))
  (should (eq   (decknix--header-status-face "killed")       'error))
  (should (eq   (decknix--header-status-face "garbage")      'shadow)))

;; -- Tags lookup -------------------------------------------------

(ert-deftest decknix-header-tags--prefers-conv-key-fast-path ()
  "When `decknix--agent-conv-key' is set, dispatches to
`-tags-for-conv-key' and bypasses the slow session-id path."
  (cl-letf (((symbol-function 'decknix--agent-tags-for-conv-key)
             (lambda (k)
               (should (equal k "ck-1"))
               '("foo" "bar")))
            ((symbol-function 'decknix--agent-tags-for-session)
             (lambda (_) (error "Should not fall through to slow path"))))
    (let ((decknix--agent-conv-key "ck-1"))
      (should (equal (decknix--header-tags) '("foo" "bar"))))))

(ert-deftest decknix-header-tags--falls-back-to-session-id ()
  "Without conv-key, dispatches to `-tags-for-session'."
  (cl-letf (((symbol-function 'decknix--agent-tags-for-conv-key)
             (lambda (_) nil))
            ((symbol-function 'decknix--agent-tags-for-session)
             (lambda (sid)
               (should (equal sid "sid-7"))
               '("baz"))))
    (let ((decknix--agent-conv-key nil)
          (decknix--agent-auggie-session-id "sid-7"))
      (should (equal (decknix--header-tags) '("baz"))))))

(ert-deftest decknix-header-tags--nil-when-no-identity ()
  "Returns nil when neither identifier is set."
  (let ((decknix--agent-conv-key nil)
        (decknix--agent-auggie-session-id nil))
    (should (null (decknix--header-tags)))))

;; -- Workspace abbreviation --------------------------------------

(ert-deftest decknix-header-workspace-short--abbreviates-home-paths ()
  "Returns the workspace path with `abbreviate-file-name' applied."
  (let* ((home (expand-file-name "~"))
         (decknix--agent-session-workspace
          (concat home "/code/decknix")))
    (should (equal (decknix--header-workspace-short)
                   "~/code/decknix"))))

(ert-deftest decknix-header-workspace-short--nil-when-empty ()
  "Returns nil for nil or empty workspace."
  (let ((decknix--agent-session-workspace nil))
    (should (null (decknix--header-workspace-short))))
  (let ((decknix--agent-session-workspace ""))
    (should (null (decknix--header-workspace-short)))))

;; -- Agent glyph -------------------------------------------------

(ert-deftest decknix-header-agent-glyph--auggie ()
  "Auggie maps to \"A\" via the alist."
  (cl-letf (((symbol-function 'map-nested-elt)
             (lambda (_state _keys) "Auggie")))
    (let ((agent-shell--state '(:agent-config (:buffer-name "Auggie"))))
      (should (equal (decknix--header-agent-glyph) "A")))))

(ert-deftest decknix-header-agent-glyph--claude ()
  "Claude maps to \"C\"."
  (cl-letf (((symbol-function 'map-nested-elt)
             (lambda (_state _keys) "Claude")))
    (let ((agent-shell--state '(:agent-config (:buffer-name "Claude"))))
      (should (equal (decknix--header-agent-glyph) "C")))))

(ert-deftest decknix-header-agent-glyph--codex ()
  "Codex maps to \"X\"."
  (cl-letf (((symbol-function 'map-nested-elt)
             (lambda (_state _keys) "Codex")))
    (let ((agent-shell--state '(:agent-config (:buffer-name "Codex"))))
      (should (equal (decknix--header-agent-glyph) "X")))))

(ert-deftest decknix-header-agent-glyph--gemini ()
  "Gemini maps to \"G\"."
  (cl-letf (((symbol-function 'map-nested-elt)
             (lambda (_state _keys) "Gemini")))
    (let ((agent-shell--state '(:agent-config (:buffer-name "Gemini"))))
      (should (equal (decknix--header-agent-glyph) "G")))))

(ert-deftest decknix-header-agent-glyph--opencode ()
  "OpenCode maps to \"O\"."
  (cl-letf (((symbol-function 'map-nested-elt)
             (lambda (_state _keys) "OpenCode")))
    (let ((agent-shell--state '(:agent-config (:buffer-name "OpenCode"))))
      (should (equal (decknix--header-agent-glyph) "O")))))

(ert-deftest decknix-header-agent-glyph--goose ()
  "Goose maps to the goose emoji (explicit, to avoid a \"G\" clash with Gemini)."
  (cl-letf (((symbol-function 'map-nested-elt)
             (lambda (_state _keys) "Goose")))
    (let ((agent-shell--state '(:agent-config (:buffer-name "Goose"))))
      (should (equal (decknix--header-agent-glyph) "🪿")))))

(ert-deftest decknix-header-agent-glyph--qwen ()
  "Qwen Code maps to \"Q\"."
  (cl-letf (((symbol-function 'map-nested-elt)
             (lambda (_state _keys) "Qwen Code")))
    (let ((agent-shell--state '(:agent-config (:buffer-name "Qwen Code"))))
      (should (equal (decknix--header-agent-glyph) "Q")))))

(ert-deftest decknix-header-agent-glyph--unknown-falls-back-to-first-char ()
  "Unknown agent name falls back to first character uppercased."
  (cl-letf (((symbol-function 'map-nested-elt)
             (lambda (_state _keys) "nova")))
    (let ((agent-shell--state '(:agent-config (:buffer-name "nova"))))
      (should (equal (decknix--header-agent-glyph) "N")))))

(ert-deftest decknix-header-agent-glyph--default-when-no-state ()
  "Without state, defaults to \"A\" (Auggie is the default agent)."
  (let ((agent-shell--state nil))
    (should (equal (decknix--header-agent-glyph) "A"))))

;; -- Workspace basename ------------------------------------------

(ert-deftest decknix-header-workspace-basename--last-component ()
  "Returns the last path component."
  (let ((decknix--agent-session-workspace
         "/Users/foo/Code/nurturecloud/decknix-config"))
    (should (equal (decknix--header-workspace-basename)
                   "decknix-config"))))

(ert-deftest decknix-header-workspace-basename--handles-trailing-slash ()
  "Strips a trailing slash before extracting the basename."
  (let ((decknix--agent-session-workspace "/Users/foo/tools/decknix/"))
    (should (equal (decknix--header-workspace-basename) "decknix"))))

(ert-deftest decknix-header-workspace-basename--nil-when-empty ()
  "Returns nil for nil or empty workspace."
  (let ((decknix--agent-session-workspace nil))
    (should (null (decknix--header-workspace-basename))))
  (let ((decknix--agent-session-workspace ""))
    (should (null (decknix--header-workspace-basename)))))

;; -- Model short -------------------------------------------------

(ert-deftest decknix-header-model-short--delegates-to-session-lookup ()
  "Dispatches to `decknix--agent-session-model-for-conv-key' with the
buffer-local `decknix--agent-conv-key'."
  (cl-letf (((symbol-function 'decknix--agent-session-model-for-conv-key)
             (lambda (k)
               (should (equal k "ck-42"))
               "sonnet-4-5")))
    (let ((decknix--agent-conv-key "ck-42"))
      (should (equal (decknix--header-model-short) "sonnet-4-5")))))

(ert-deftest decknix-header-model-short--nil-when-no-conv-key ()
  "Returns nil when conv-key is not set."
  (let ((decknix--agent-conv-key nil))
    (should (null (decknix--header-model-short)))))

;; -- Essentials --------------------------------------------------

(ert-deftest decknix-header-essentials--glyph-model-workspace ()
  "Composes the full \"<glyph> ▶ <model> @ <ws>\" string."
  (cl-letf (((symbol-function 'decknix--header-agent-glyph)
             (lambda () "A"))
            ((symbol-function 'decknix--header-model-short)
             (lambda () "sonnet-4-5"))
            ((symbol-function 'decknix--header-workspace-basename)
             (lambda () "decknix")))
    (should (equal (substring-no-properties (decknix--header-essentials))
                   "A ▶ sonnet-4-5 @ decknix"))))

(ert-deftest decknix-header-essentials--model-only ()
  "Omits workspace segment when ws is nil."
  (cl-letf (((symbol-function 'decknix--header-agent-glyph)
             (lambda () "A"))
            ((symbol-function 'decknix--header-model-short)
             (lambda () "sonnet-4-5"))
            ((symbol-function 'decknix--header-workspace-basename)
             (lambda () nil)))
    (should (equal (substring-no-properties (decknix--header-essentials))
                   "A ▶ sonnet-4-5"))))

(ert-deftest decknix-header-essentials--workspace-only ()
  "Omits model segment when model is nil."
  (cl-letf (((symbol-function 'decknix--header-agent-glyph)
             (lambda () "A"))
            ((symbol-function 'decknix--header-model-short)
             (lambda () nil))
            ((symbol-function 'decknix--header-workspace-basename)
             (lambda () "decknix")))
    (should (equal (substring-no-properties (decknix--header-essentials))
                   "A @ decknix"))))

(ert-deftest decknix-header-essentials--nil-when-no-model-or-ws ()
  "Returns nil when both model and ws are nil."
  (cl-letf (((symbol-function 'decknix--header-agent-glyph)
             (lambda () "A"))
            ((symbol-function 'decknix--header-model-short)
             (lambda () nil))
            ((symbol-function 'decknix--header-workspace-basename)
             (lambda () nil)))
    (should (null (decknix--header-essentials)))))

;; -- Header build ------------------------------------------------

(ert-deftest decknix-header-build--includes-status-and-tags ()
  "Build string includes the status word + tag tokens."
  (cl-letf (((symbol-function 'decknix--header-detect-status)
             (lambda () "ready"))
            ((symbol-function 'decknix--header-upstream)
             (lambda () nil))
            ((symbol-function 'decknix--header-tags)
             (lambda () '("foo" "bar")))
            ((symbol-function 'decknix--header-essentials)
             (lambda () nil)))
    (let ((out (decknix--header-build)))
      (should (string-match-p "ready" out))
      (should (string-match-p "#foo" out))
      (should (string-match-p "#bar" out)))))

(ert-deftest decknix-header-build--includes-essentials-after-tags ()
  "Essentials substring appears after the tags substring in the joined header."
  (cl-letf (((symbol-function 'decknix--header-detect-status)
             (lambda () "ready"))
            ((symbol-function 'decknix--header-upstream)
             (lambda () nil))
            ((symbol-function 'decknix--header-tags)
             (lambda () '("foo")))
            ((symbol-function 'decknix--header-agent-glyph)
             (lambda () "A"))
            ((symbol-function 'decknix--header-model-short)
             (lambda () "sonnet-4-5"))
            ((symbol-function 'decknix--header-workspace-basename)
             (lambda () "decknix")))
    (let* ((out (substring-no-properties (decknix--header-build)))
           (tags-pos (string-match "#foo" out))
           (essentials-pos (string-match "A ▶ sonnet-4-5 @ decknix" out)))
      (should tags-pos)
      (should essentials-pos)
      (should (< tags-pos essentials-pos)))))

(ert-deftest decknix-header-build--working-then-ready-renders-finished ()
  "After `working' the next `ready' tick renders as `finished'
until the user views the buffer.  This is the entire reason the
prev-status memo exists."
  (cl-letf (((symbol-function 'decknix--header-detect-status)
             (lambda () "ready"))
            ((symbol-function 'decknix--header-upstream)
             (lambda () nil))
            ((symbol-function 'decknix--header-tags)
             (lambda () nil)))
    (with-temp-buffer
      (setq-local decknix--header-prev-status "working")
      ;; Buffer is not the selected-window's buffer, so the
      ;; "clear finished on view" branch does NOT fire.
      (let ((out (decknix--header-build)))
        (should (string-match-p "finished" out))))))

;; -- Timer plumbing ----------------------------------------------

(ert-deftest decknix-header-stop-timer--clears-buffer-local-timer ()
  "Stop cancels the timer and nils the buffer-local var."
  (let ((cancel-called nil))
    (cl-letf (((symbol-function 'cancel-timer)
               (lambda (_) (setq cancel-called t))))
      (with-temp-buffer
        (setq-local decknix--header-timer 'fake-timer)
        (decknix--header-stop-timer)
        (should cancel-called)
        (should (null decknix--header-timer))))))

(ert-deftest decknix-header-stop-timer--noop-when-no-timer ()
  "Stop is a no-op when no timer is set."
  (cl-letf (((symbol-function 'cancel-timer)
             (lambda (_) (error "Should not be called"))))
    (with-temp-buffer
      (setq-local decknix--header-timer nil)
      (decknix--header-stop-timer)
      (should (null decknix--header-timer)))))

(provide 'decknix-agent-header-test)
;;; decknix-agent-header-test.el ends here
