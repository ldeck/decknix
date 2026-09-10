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

;; The code under test now resolves tags by conv-key AND session id.
;; Stub the resolver so these isolated runs (which stub only the
;; conv-key lookup) still exercise the real call path.
(unless (fboundp 'decknix--agent-tags-resolve)
  (defun decknix--agent-tags-resolve (conv-key session-id)
    (let ((a (and conv-key (fboundp 'decknix--agent-tags-for-conv-key)
                  (decknix--agent-tags-for-conv-key conv-key)))
          (b (and session-id (fboundp 'decknix--agent-tags-for-session)
                  (decknix--agent-tags-for-session session-id))))
      (cond ((and a b) (delete-dups (append a b))) (a) (b)))))

(unless (fboundp 'decknix--agent-tags-for-buffer)
  (defun decknix--agent-tags-for-buffer (buffer)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (decknix--agent-tags-resolve
         (and (boundp 'decknix--agent-conv-key) decknix--agent-conv-key)
         (and (boundp 'decknix--agent-auggie-session-id)
              decknix--agent-auggie-session-id))))))


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

;; -- Update gating (redisplay perf) ------------------------------

(ert-deftest decknix-header-update--skips-when-not-displayed ()
  "No window for the buffer -> no build, no force, header untouched."
  (let ((forced nil) (built nil))
    (cl-letf (((symbol-function 'input-pending-p) (lambda () nil))
              ((symbol-function 'derived-mode-p) (lambda (&rest _) t))
              ((symbol-function 'get-buffer-window) (lambda (&rest _) nil))
              ((symbol-function 'decknix--header-build)
               (lambda () (setq built t) "x"))
              ((symbol-function 'force-mode-line-update)
               (lambda (&rest _) (setq forced t))))
      (with-temp-buffer
        (setq-local header-line-format nil)
        (decknix--header-update)
        (should-not forced)
        (should-not built)
        (should (null header-line-format))))))

(ert-deftest decknix-header-update--skips-force-when-unchanged ()
  "Visible but freshly built header is identical -> no force-mode-line-update."
  (let ((forced nil))
    (cl-letf (((symbol-function 'input-pending-p) (lambda () nil))
              ((symbol-function 'derived-mode-p) (lambda (&rest _) t))
              ((symbol-function 'get-buffer-window) (lambda (&rest _) (selected-window)))
              ((symbol-function 'decknix--header-build) (lambda () "same"))
              ((symbol-function 'force-mode-line-update)
               (lambda (&rest _) (setq forced t))))
      (with-temp-buffer
        (setq-local header-line-format (list "same"))
        (decknix--header-update)
        (should-not forced)))))

(ert-deftest decknix-header-update--forces-when-changed ()
  "Visible and header differs -> updates format and forces redisplay once."
  (let ((forced nil))
    (cl-letf (((symbol-function 'input-pending-p) (lambda () nil))
              ((symbol-function 'derived-mode-p) (lambda (&rest _) t))
              ((symbol-function 'get-buffer-window) (lambda (&rest _) (selected-window)))
              ((symbol-function 'decknix--header-build) (lambda () "new"))
              ((symbol-function 'force-mode-line-update)
               (lambda (&rest _) (setq forced t))))
      (with-temp-buffer
        (setq-local header-line-format (list "old"))
        (decknix--header-update)
        (should forced)
        (should (equal header-line-format (list "new")))))))

(ert-deftest decknix-header-update--skips-when-input-pending ()
  "Pending input -> skip entirely so typing is never blocked."
  (let ((forced nil))
    (cl-letf (((symbol-function 'input-pending-p) (lambda () t))
              ((symbol-function 'derived-mode-p) (lambda (&rest _) t))
              ((symbol-function 'get-buffer-window) (lambda (&rest _) (selected-window)))
              ((symbol-function 'decknix--header-build) (lambda () "new"))
              ((symbol-function 'force-mode-line-update)
               (lambda (&rest _) (setq forced t))))
      (with-temp-buffer
        (setq-local header-line-format (list "old"))
        (decknix--header-update)
        (should-not forced)
        (should (equal header-line-format (list "old")))))))

;; -- project-name cache (hitch profiler: ~6% CPU in filesystem walks) --
;;
;; `agent-shell--project-name' calls `project-current', which walks the
;; filesystem (`locate-dominating-file' / `directory-files' /
;; `vc-file-getprop').  It sits on the header render path, so it ran for
;; every visible agent buffer every 2 seconds -- CPU sampling showed
;; ~6% of the daemon spent recomputing a project name that cannot change
;; unless `default-directory' does.

(ert-deftest decknix-header--project-name-cached-per-directory ()
  "The upstream lookup runs once per directory, not once per header tick."
  (let ((calls 0))
    (cl-letf (((symbol-function 'decknix--header-project-name-orig)
               (lambda (&rest _) (setq calls (1+ calls)) "myproj")))
      (with-temp-buffer
        (setq-local default-directory "/tmp/proj-a/")
        (should (equal (decknix--header-project-name-advice
                        #'decknix--header-project-name-orig)
                       "myproj"))
        (dotimes (_ 20)
          (decknix--header-project-name-advice
           #'decknix--header-project-name-orig))
        (should (= calls 1))))))

(ert-deftest decknix-header--project-name-cache-follows-directory ()
  "Changing `default-directory' invalidates the cache.
A stale name would be worse than the cost it saves -- the header would
claim the wrong project."
  (let ((calls 0))
    (cl-letf (((symbol-function 'decknix--header-project-name-orig)
               (lambda (&rest _) (setq calls (1+ calls))
                 (format "proj-%d" calls))))
      (with-temp-buffer
        (setq-local default-directory "/tmp/proj-a/")
        (should (equal (decknix--header-project-name-advice
                        #'decknix--header-project-name-orig) "proj-1"))
        (setq-local default-directory "/tmp/proj-b/")
        (should (equal (decknix--header-project-name-advice
                        #'decknix--header-project-name-orig) "proj-2"))
        (should (= calls 2))))))

(ert-deftest decknix-header--project-name-caches-nil ()
  "A nil result is cached too -- a directory outside any project is the
case that pays the FULL filesystem walk, so re-running it every tick is
the worst version of this bug."
  (let ((calls 0))
    (cl-letf (((symbol-function 'decknix--header-project-name-orig)
               (lambda (&rest _) (setq calls (1+ calls)) nil)))
      (with-temp-buffer
        (setq-local default-directory "/tmp/not-a-project/")
        (should-not (decknix--header-project-name-advice
                     #'decknix--header-project-name-orig))
        (should-not (decknix--header-project-name-advice
                     #'decknix--header-project-name-orig))
        (should (= calls 1))))))

;; -- shared header timer (#148: 17 timers, 134s of blocking) -----------

(ert-deftest decknix-header--dedupe-visits-each-buffer-once ()
  "A buffer shown in two windows is refreshed once, not twice."
  (let ((a (generate-new-buffer "*hdr-a*"))
        (b (generate-new-buffer "*hdr-b*")))
    (unwind-protect
        (progn
          (dolist (buf (list a b))
            (with-current-buffer buf (setq-local major-mode 'agent-shell-mode)))
          (cl-letf (((symbol-function 'derived-mode-p)
                     (lambda (mode) (eq major-mode mode))))
            (should (equal (decknix--header-dedupe-agent-buffers
                            (list a b a b a))
                           (list a b)))))
      (kill-buffer a) (kill-buffer b))))

(ert-deftest decknix-header--dedupe-skips-non-agent-and-dead ()
  "Only live agent-shell buffers are refreshed."
  (let ((agent (generate-new-buffer "*hdr-agent*"))
        (other (generate-new-buffer "*hdr-other*"))
        (dead (generate-new-buffer "*hdr-dead*")))
    (kill-buffer dead)
    (unwind-protect
        (progn
          (with-current-buffer agent (setq-local major-mode 'agent-shell-mode))
          (with-current-buffer other (setq-local major-mode 'fundamental-mode))
          (cl-letf (((symbol-function 'derived-mode-p)
                     (lambda (mode) (eq major-mode mode))))
            (should (equal (decknix--header-dedupe-agent-buffers
                            (list agent other dead))
                           (list agent)))))
      (kill-buffer agent) (kill-buffer other))))

(ert-deftest decknix-header--dedupe-empty ()
  "No visible agent buffers means no work."
  (should-not (decknix--header-dedupe-agent-buffers nil)))

;; -- event-path throttle (profiler: redisplay 48%, GC 21%) -------------
;;
;; `agent-shell--update-header-and-mode-line' is overridden to build our
;; unified header, and upstream calls it from many places -- including
;; per-notification streaming updates.  CPU sampling put 246 samples
;; (~9x the shared timer's) under that path, and the override also called
;; `force-mode-line-update' UNCONDITIONALLY, defeating the "only force
;; when the header actually changed" check inside `decknix--header-update'
;; and driving a redisplay (plus an uncached tab-bar keymap rebuild) per
;; streamed chunk.

(ert-deftest decknix-header--event-throttle-first-call-passes ()
  "The first event in a quiet buffer refreshes immediately."
  (let ((n 0))
    (cl-letf (((symbol-function 'decknix--header-update)
               (lambda () (setq n (1+ n)))))
      (with-temp-buffer
        (decknix--header-update-throttled)
        (should (= n 1))))))

(ert-deftest decknix-header--event-throttle-suppresses-burst ()
  "A burst of streamed chunks collapses to one refresh.
This is the whole point: a turn streaming hundreds of chunks must not
rebuild the header hundreds of times."
  (let ((n 0))
    (cl-letf (((symbol-function 'decknix--header-update)
               (lambda () (setq n (1+ n)))))
      (with-temp-buffer
        (let ((decknix-header-event-throttle 60))
          (dotimes (_ 200) (decknix--header-update-throttled))
          (should (= n 1)))))))

(ert-deftest decknix-header--event-throttle-releases-after-interval ()
  "Once the interval has passed, the next event refreshes again."
  (let ((n 0))
    (cl-letf (((symbol-function 'decknix--header-update)
               (lambda () (setq n (1+ n)))))
      (with-temp-buffer
        (let ((decknix-header-event-throttle 0))
          (decknix--header-update-throttled)
          (decknix--header-update-throttled)
          (should (= n 2)))))))

(ert-deftest decknix-header--event-throttle-is-per-buffer ()
  "One busy session must not starve another's header.
The throttle timestamp is buffer-local, so a session streaming flat out
cannot suppress the refresh of a different session that just changed
status."
  (let ((n 0)
        (a (generate-new-buffer "*hdr-throttle-a*"))
        (b (generate-new-buffer "*hdr-throttle-b*")))
    (unwind-protect
        (cl-letf (((symbol-function 'decknix--header-update)
                   (lambda () (setq n (1+ n)))))
          (let ((decknix-header-event-throttle 60))
            (with-current-buffer a (decknix--header-update-throttled))
            (with-current-buffer a (decknix--header-update-throttled))
            (with-current-buffer b (decknix--header-update-throttled))
            (should (= n 2))))
      (kill-buffer a) (kill-buffer b))))


;; --- essentials is a FALLBACK, not a second copy of the breadcrumb ---

(ert-deftest decknix-header--essentials-dropped-when-breadcrumb-shown ()
  "With a breadcrumb that fits, the abbreviated block is redundant.
`C @ nurturecloud' beside `Claude › … › nurturecloud › …' says the same
thing twice in a line that is already fighting for width."
  (should (decknix--header-redundant-essentials-p
           "C @ ws" "Claude > Opus > ws" '("a" "b") 200)))

(ert-deftest decknix-header--essentials-kept-without-a-breadcrumb ()
  "No breadcrumb means the block is the ONLY source of agent/workspace.
An earlier version tested merely that the parts list was non-empty, and
so dropped the block when there was nothing to replace it."
  (should-not (decknix--header-redundant-essentials-p
               "C @ ws" nil '("a" "b") 200)))

(ert-deftest decknix-header--essentials-kept-when-breadcrumb-will-not-fit ()
  "Upstream EXISTING is not upstream SURVIVING the width fit.
A narrow window is the case the abbreviated block was added for."
  (should-not (decknix--header-redundant-essentials-p
               "C @ ws" "Claude > Opus > ws"
               '("a very long part indeed" "another very long part") 10)))

(ert-deftest decknix-header--nothing-to-drop-without-essentials ()
  "No block, nothing to decide."
  (should-not (decknix--header-redundant-essentials-p nil "up" '("a") 200)))

(provide 'decknix-agent-header-test)
;;; decknix-agent-header-test.el ends here
