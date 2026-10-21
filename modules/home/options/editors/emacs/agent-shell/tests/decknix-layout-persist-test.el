;;; decknix-layout-persist-test.el --- Tests for decknix-layout-persist -*- lexical-binding: t -*-

;;; Commentary:
;;
;; The layout model has to survive a print/read round trip, map agent
;; buffers to their session ids, and degrade (never delete a window,
;; never signal) when a file, directory or session has gone.  Batch
;; Emacs has a real (terminal) frame, so the window-state tests split it
;; for real rather than hand-building state trees.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tab-bar)
(require 'decknix-layout-persist)
(require 'decknix-layout-persist-fixture)

(defvar agent-shell-workspace--isolation-active)
(defvar decknix--sidebar-tile-auto-suspended)

(defmacro decknix-layout-test--with-file (&rest body)
  "Run BODY with `decknix-layout-persist-file' in a fresh temp dir."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "dk-layout-" t))
          (decknix-layout-persist-file (expand-file-name "layout.el" dir))
          (decknix-layout--last-written nil)
          (decknix-layout--rotated nil))
     (unwind-protect (progn ,@body)
       (delete-directory dir t))))

(defmacro decknix-layout-test--with-windows (&rest body)
  "Run BODY in a single-window frame, restoring the windows afterwards."
  (declare (indent 0))
  `(save-window-excursion
     (delete-other-windows)
     ,@body))

(defun decknix-layout-test--state (&rest buffers)
  "Show BUFFERS side by side and return the writable window state."
  (switch-to-buffer (car buffers))
  (dolist (b (cdr buffers))
    (select-window (split-window-right))
    (switch-to-buffer b))
  (window-state-get (frame-root-window) t))

;; -- Window-state walking ---------------------------------------------------

(ert-deftest decknix-layout/state-buffer-names-ignores-parameter-pairs ()
  "Parameter pairs such as (min-pixel-width . 1724) are not nodes."
  (decknix-layout-test--with-windows
    (let* ((a (get-buffer-create "dk-a")) (b (get-buffer-create "dk-b"))
           (state (decknix-layout-test--state a b)))
      (should (equal '("dk-a" "dk-b") (decknix-layout--state-buffer-names state))))))

(ert-deftest decknix-layout/rename-maps-names-and-falls-back ()
  (decknix-layout-test--with-windows
    (let* ((a (get-buffer-create "dk-a")) (b (get-buffer-create "dk-b"))
           (state (decknix-layout-test--state a b))
           (renamed (decknix-layout--state-rename-buffers
                     state '(("dk-a" . "dk-a-now")) "*scratch*")))
      (should (equal '("dk-a-now" "*scratch*")
                     (decknix-layout--state-buffer-names renamed)))
      (should (equal '("dk-a" "dk-b") (decknix-layout--state-buffer-names state))))))

(ert-deftest decknix-layout/rename-drops-prev-and-next-buffers ()
  (let* ((state '(((min-height . 4))
                  leaf (buffer "x" (point . 3))
                  (prev-buffers ("gone" 1 1)) (next-buffers ("gone2" 1 1))))
         (out (decknix-layout--state-rename-buffers state '(("x" . "y")) "f")))
    (should (equal '(((min-height . 4)) leaf (buffer "y" (point . 3))) out))))

(ert-deftest decknix-layout/a-missing-buffer-keeps-its-window ()
  "A buffer that cannot be recreated shows the fallback; no window is lost."
  (decknix-layout-test--with-windows
    (let* ((a (get-buffer-create "dk-a")) (b (get-buffer-create "dk-gone"))
           (state (decknix-layout-test--state a b)))
      (kill-buffer b)
      (delete-other-windows)
      (decknix-layout--put-tab state '(("dk-a" . "dk-a")) "*scratch*")
      (should (= 2 (length (window-list))))
      (should (equal '("dk-a" "*scratch*")
                     (mapcar (lambda (w) (buffer-name (window-buffer w)))
                             (window-list nil nil (frame-first-window))))))))

;; -- Buffer references ------------------------------------------------------

(ert-deftest decknix-layout/buffer-ref-file-and-missing-file-fallback ()
  (let* ((file (make-temp-file "dk-layout-file-" nil ".txt"))
         (buf (find-file-noselect file)))
    (unwind-protect
        (let ((ref (decknix-layout--buffer-ref buf)))
          (should (equal (list :kind 'file :file (expand-file-name file)) ref))
          (should (eq buf (decknix-layout--resolve-buffer "x" ref)))
          (kill-buffer buf)
          (delete-file file)
          (should-not (decknix-layout--resolve-buffer "x" ref)))
      (when (buffer-live-p buf) (kill-buffer buf))
      (when (file-exists-p file) (delete-file file)))))

(ert-deftest decknix-layout/buffer-ref-dired-and-gone-directory ()
  (let ((ref (list :kind 'dired :dir "/nonexistent/dk-layout/")))
    (should-not (decknix-layout--resolve-buffer "d" ref))))

(ert-deftest decknix-layout/other-buffers-resolve-by-name-only ()
  (let ((buf (get-buffer-create "dk-other")))
    (should (equal '(:kind other) (decknix-layout--buffer-ref buf)))
    (should (eq buf (decknix-layout--resolve-buffer "dk-other" '(:kind other))))
    (kill-buffer buf)
    (should-not (decknix-layout--resolve-buffer "dk-other" '(:kind other)))))

(ert-deftest decknix-layout/agent-buffer-maps-to-its-session ()
  (let ((buf (get-buffer-create "*Claude: glossary*"))
        (entry '((session-id . "166d3cce") (name . "*Claude: glossary*")
                 (workspace . "/ws") (conv-key . "ck") (tags "glossary"))))
    (unwind-protect
        (cl-letf (((symbol-function 'decknix-layout--agent-buffer-p) (lambda (_) t))
                  ((symbol-function 'decknix-layout--agent-entry) (lambda (_) entry)))
          (should (equal (list :kind 'agent :session entry)
                         (decknix-layout--buffer-ref buf))))
      (kill-buffer buf))))

(ert-deftest decknix-layout/agent-entry-reads-session-and-conversation ()
  (let ((buf (get-buffer-create "*Claude: t*")))
    (unwind-protect
        (cl-letf (((symbol-function 'decknix--agent-buffer-session-id) (lambda (&rest _) "sid-1"))
                  ((symbol-function 'decknix--agent-tags-for-buffer) (lambda (_) '("a" "b"))))
          (with-current-buffer buf
            (setq-local decknix--agent-conv-key "ck-1")
            (setq-local decknix--agent-session-workspace "/repo"))
          (should (equal '((session-id . "sid-1") (name . "*Claude: t*")
                           (workspace . "/repo") (conv-key . "ck-1") (tags "a" "b"))
                         (decknix-layout--agent-entry buf))))
      (kill-buffer buf))))

(ert-deftest decknix-layout/agent-ref-resolves-to-live-buffer-or-placeholder ()
  (let* ((entry '((session-id . "sid-9") (name . "*Claude: x*") (conv-key . "ck-9")))
         (live (get-buffer-create "*Claude: x live*")))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'decknix-layout--live-session-buffer) (lambda (_) live)))
            (should (eq live (decknix-layout--resolve-buffer "n" (list :kind 'agent :session entry)))))
          (cl-letf (((symbol-function 'decknix-layout--live-session-buffer) (lambda (_) nil)))
            (let ((ph (decknix-layout--resolve-buffer "n" (list :kind 'agent :session entry))))
              (should (equal "*Resume: Claude: x*" (buffer-name ph)))
              (should (equal entry (buffer-local-value 'decknix-layout--placeholder-entry ph)))
              (kill-buffer ph))))
      (kill-buffer live))))

(ert-deftest decknix-layout/resumed-placeholder-swaps-its-windows ()
  (decknix-layout-test--with-windows
    (let* ((entry '((session-id . "sid-r") (name . "*Pi: r*")))
           (target (get-buffer-create "*Pi: r live*"))
           (ph (decknix-layout--placeholder entry)))
      (unwind-protect
          (progn
            (switch-to-buffer ph)
            (cl-letf (((symbol-function 'decknix-layout--resume-entry) (lambda (_) target)))
              (should (eq target (decknix-layout--resume-placeholder ph))))
            (should (eq target (window-buffer)))
            (should (eq target (buffer-local-value 'decknix-layout--placeholder-target ph)))
            ;; A window showing it later (a background tab) follows too.
            (set-window-buffer nil ph)
            (decknix-layout--placeholder-follow (selected-window))
            (should (eq target (window-buffer))))
        (kill-buffer ph) (kill-buffer target)))))

;; -- Capture / serialise ----------------------------------------------------

(defun decknix-layout-test--layout (state buffers)
  (list :version decknix-layout--version :saved-at 100.0
        :buffers buffers
        :frames (list (list :params '((width . 80) (left . 10))
                            :selected t :current-tab 0
                            :tabs (list (list :name "Agents" :explicit t :state state))))))

(ert-deftest decknix-layout/print-and-parse-round-trip ()
  (decknix-layout-test--with-windows
    (let* ((state (decknix-layout-test--state (get-buffer-create "dk-a")))
           (layout (decknix-layout-test--layout
                    state '(("dk-a" :kind file :file "/tmp/a")
                            ("*Claude: g*" :kind agent
                             :session ((session-id . "166d3cce") (tags "glossary"))))))
           (text (decknix-layout--print layout)))
      (should text)
      (should (equal layout (decknix-layout--parse text)))
      (should (equal '(((session-id . "166d3cce") (tags "glossary")))
                     (decknix-layout--session-entries (decknix-layout--parse text)))))))

(ert-deftest decknix-layout/unreadable-objects-are-refused ()
  (should-not (decknix-layout--print (list :version 1 :frames (list (current-buffer))))))

(ert-deftest decknix-layout/parse-rejects-other-versions-and-junk ()
  (should-not (decknix-layout--parse "(:version 99 :frames (x))"))
  (should-not (decknix-layout--parse "not a layout ("))
  (should-not (decknix-layout--parse "(:version 1 :frames nil)")))

(ert-deftest decknix-layout/write-skips-unchanged-and-keeps-previous-run ()
  (decknix-layout-test--with-file
    (with-temp-file decknix-layout-persist-file (insert "previous run"))
    (let ((layout (decknix-layout-test--layout '(nil leaf) nil)))
      (should (decknix-layout--write layout))
      (should (equal "previous run"
                     (with-temp-buffer
                       (insert-file-contents (concat decknix-layout-persist-file ".prev"))
                       (buffer-string))))
      (should (equal layout (decknix-layout--read-file)))
      ;; Only the timestamp differs: nothing to write.
      (should-not (decknix-layout--write (plist-put (copy-sequence layout) :saved-at 200.0)))
      ;; A second write in the same run must not rotate again.
      (should (decknix-layout--write (plist-put (copy-sequence layout) :buffers '(("n" :kind other)))))
      (should (equal "previous run"
                     (with-temp-buffer
                       (insert-file-contents (concat decknix-layout-persist-file ".prev"))
                       (buffer-string)))))))

(ert-deftest decknix-layout/save-without-gui-frames-keeps-the-file ()
  "Batch has no GUI frame: a save must leave the last layout alone."
  (decknix-layout-test--with-file
    (with-temp-file decknix-layout-persist-file (insert "keep"))
    (decknix-layout-save t t)
    (should (equal "keep" (with-temp-buffer
                            (insert-file-contents decknix-layout-persist-file)
                            (buffer-string))))))

(ert-deftest decknix-layout/capture-records-tabs-and-buffer-kinds ()
  (decknix-layout-test--with-windows
    (let* ((file (make-temp-file "dk-layout-cap-"))
           (fbuf (find-file-noselect file))
           (other (get-buffer-create "dk-cap-other")))
      (unwind-protect
          (progn
            (decknix-layout-test--state fbuf other)
            (cl-letf (((symbol-function 'decknix-layout--gui-frames)
                       (lambda () (list (selected-frame)))))
              (let* ((layout (decknix-layout--capture t))
                     (frame (car (plist-get layout :frames))))
                (should (decknix-layout--print layout))
                (should (= 1 (length (plist-get frame :tabs))))
                (should (eq 'file (plist-get (cdr (assoc (buffer-name fbuf)
                                                         (plist-get layout :buffers)))
                                             :kind)))
                (should (eq 'other (plist-get (cdr (assoc "dk-cap-other"
                                                          (plist-get layout :buffers)))
                                              :kind))))))
        (kill-buffer fbuf) (kill-buffer other) (delete-file file)))))

;; -- Startup policy ---------------------------------------------------------

(ert-deftest decknix-layout/recent-p-honours-max-age ()
  (let ((decknix-layout-restore-max-age 60))
    (should (decknix-layout--recent-p '(:saved-at 100.0) 150.0))
    (should-not (decknix-layout--recent-p '(:saved-at 100.0) 200.0))
    (should-not (decknix-layout--recent-p '(:saved-at nil) 200.0))))

(ert-deftest decknix-layout/summary-counts-frames-tabs-sessions ()
  (should (equal "1 frame, 1 tab, 1 session"
                 (decknix-layout--summary
                  (decknix-layout-test--layout
                   nil '(("a" :kind agent :session ((session-id . "s")))
                         ("b" :kind file :file "/f")))))))

(ert-deftest decknix-layout/offscreen-positions-are-dropped ()
  (let ((wa '((0 25 1440 875))))
    (should (equal '((left . 10) (top . 30) (width . 80))
                   (decknix-layout--params-on-screen '((left . 10) (top . 30) (width . 80)) wa)))
    (should (equal '((width . 80))
                   (decknix-layout--params-on-screen '((left . 3000) (top . 30) (width . 80)) wa)))
    (should (equal '((left + -5) (top . 30))
                   (decknix-layout--params-on-screen '((left + -5) (top . 30)) '((-1920 0 1920 1080)))))))

(ert-deftest decknix-layout/enable-is-a-no-op-in-batch ()
  (let ((kill-emacs-hook nil))
    (decknix-layout-persist-enable)
    (should-not kill-emacs-hook)))

(ert-deftest decknix-layout/restore-rebuilds-tabs-and-splits ()
  "Save two tabs, collapse to one, restore: tabs, names and splits return."
  (decknix-layout-test--with-file
    (let ((tab-bar-mode-was (bound-and-true-p tab-bar-mode))
          (a (get-buffer-create "dk-r-a")) (b (get-buffer-create "dk-r-b"))
          (c (get-buffer-create "dk-r-c")))
      (unwind-protect
          (save-window-excursion
            (tab-bar-mode 1)
            (tab-bar-close-other-tabs)
            (delete-other-windows)
            (decknix-layout-test--state a b)
            (tab-bar-new-tab)
            (tab-bar-rename-tab "Agents")
            (delete-other-windows)
            (decknix-layout-test--state c)
            (cl-letf (((symbol-function 'decknix-layout--gui-frames)
                       (lambda () (list (selected-frame))))
                      ((symbol-function 'select-frame-set-input-focus) #'ignore))
              (decknix-layout-save t t)
              (tab-bar-close-other-tabs)
              (delete-other-windows)
              (switch-to-buffer "*scratch*")
              (kill-buffer b)
              (decknix-layout-restore nil nil)
              (let ((tabs (tab-bar-tabs)))
                (should (= 2 (length tabs)))
                (should (equal "Agents" (alist-get 'name (nth 1 tabs))))
                (should (eq 'current-tab (car (nth 1 tabs)))))
              (should (equal '("dk-r-c") (mapcar (lambda (w) (buffer-name (window-buffer w)))
                                                 (window-list))))
              (tab-bar-select-tab 1)
              (should (equal '("dk-r-a" "*scratch*")
                             (mapcar (lambda (w) (buffer-name (window-buffer w)))
                                     (window-list nil nil (frame-first-window)))))))
        (tab-bar-close-other-tabs)
        (unless tab-bar-mode-was (tab-bar-mode -1))
        (dolist (x (list a b c)) (when (buffer-live-p x) (kill-buffer x)))))))

;; -- Restore: the real multi-tab layout -----------------------------------

(defun decknix-layout-test--tab-buffers ()
  "Buffer names of every window in each tab of the selected frame, in order."
  (let ((tab-bar-tab-post-select-functions nil)
        (current (tab-bar--current-tab-index)))
    (prog1
        (cl-loop for i from 1 to (length (tab-bar-tabs))
                 collect (progn
                           (tab-bar-select-tab i)
                           (mapcar (lambda (w) (buffer-name (window-buffer w)))
                                   (window-list nil 'nomini (frame-first-window)))))
      (tab-bar-select-tab (1+ current)))))

(defmacro decknix-layout-test--with-fixture (&rest body)
  "Run BODY with the fixture saved, its sessions live and tab-bar-mode OFF.
Off because a fresh daemon has no tab-bar until the first tab is made,
which is exactly when the startup restore runs."
  (declare (indent 0))
  `(decknix-layout-test--with-file
     (let ((tab-bar-mode-was (bound-and-true-p tab-bar-mode))
           (sessions (cl-loop for i from 1 to 7
                              collect (get-buffer-create (format "*Claude: session-%d*" i))))
           (decknix--sidebar-tile-auto-suspended nil))
       (unwind-protect
           (save-window-excursion
             (with-temp-file decknix-layout-persist-file
               (prin1 decknix-layout-test-fixture (current-buffer)))
             (when (bound-and-true-p tab-bar-mode) (tab-bar-mode -1))
             (tab-bar-close-other-tabs)
             (delete-other-windows)
             (switch-to-buffer "*scratch*")
             (get-buffer-create "*Review Board*")
             (cl-letf (((symbol-function 'decknix-layout--gui-frames)
                        (lambda () (list (selected-frame))))
                       ((symbol-function 'select-frame-set-input-focus) #'ignore)
                       ((symbol-function 'decknix-layout--live-session-buffer)
                        (lambda (entry) (get-buffer (alist-get 'name entry)))))
               ,@body))
         (tab-bar-close-other-tabs)
         (if tab-bar-mode-was (tab-bar-mode 1) (tab-bar-mode -1))
         (dolist (b (cons (get-buffer "*Review Board*") sessions))
           (when (buffer-live-p b) (kill-buffer b)))
         (when (get-buffer "*Agent Sidebar*") (kill-buffer "*Agent Sidebar*"))))))

(ert-deftest decknix-layout/restore-rebuilds-every-tab-of-a-real-layout ()
  "The saved frame had three tabs; restore came back with only the selected one.
Restore gated tab rebuilding on `tab-bar-mode', which is still off in a
fresh daemon, and so fell back to showing the current tab alone."
  (decknix-layout-test--with-fixture
    (decknix-layout-restore nil nil)
    (let ((tabs (tab-bar-tabs)))
      (should (= 3 (length tabs)))
      (should (equal '("*Review Board*" "Agents" "*Claude: session-7*")
                     (mapcar (lambda (tab) (alist-get 'name tab)) tabs)))
      (should (equal '(nil t nil)
                     (mapcar (lambda (tab) (and (alist-get 'explicit-name tab) t)) tabs)))
      (should (= 1 (tab-bar--current-tab-index))))
    (should (equal '(("*Review Board*" "*Claude: session-1*")
                     ("*Agent Sidebar*" "*Claude: session-2*" "*Claude: session-3*"
                      "*Claude: session-4*" "*Claude: session-5*")
                     ("*Claude: session-6*" "*Claude: session-7*"))
                   (decknix-layout-test--tab-buffers)))
    (should decknix--sidebar-tile-auto-suspended)))


(ert-deftest decknix-layout/restore-keeps-tab-hooks-and-isolation-out-of-the-build ()
  "A tab-select hook must not run on half-built tabs, nor isolation redirect.
In the daemon both are the Agents tab's buffer isolation: shown a
non-agent buffer while Agents is selected, it switches tabs.  The hook
runs once, after restore, with the saved tab selected."
  (decknix-layout-test--with-fixture
    (let* ((hook-ran nil)
           (selected-at-call nil)
           (isolation-seen nil)
           (agent-shell-workspace--isolation-active t)
           (tab-bar-tab-post-select-functions
            (list (lambda (&rest _) (setq hook-ran t) (tab-bar-select-tab 1)))))
      (cl-letf (((symbol-function 'agent-shell-workspace--on-tab-selected)
                 (lambda (&rest _)
                   (push (alist-get 'name (tab-bar--current-tab)) selected-at-call)))
                ((symbol-function 'decknix-layout--live-session-buffer)
                 (lambda (entry)
                   (push agent-shell-workspace--isolation-active isolation-seen)
                   (get-buffer (alist-get 'name entry)))))
        (decknix-layout-restore nil nil)
        (should-not hook-ran)
        (should isolation-seen)
        (should-not (delq nil isolation-seen))
        (should agent-shell-workspace--isolation-active)
        (should (equal '("Agents") selected-at-call))
        (should (= 1 (tab-bar--current-tab-index)))))))

;; -- Pixel sizes ------------------------------------------------------------

(ert-deftest decknix-layout/state-without-pixels-keeps-structure-and-buffers ()
  (let* ((state (plist-get (nth 1 (plist-get (car (plist-get decknix-layout-test-fixture
                                                              :frames))
                                             :tabs))
                           :state))
         (out (decknix-layout--state-without-pixels state)))
    (should (equal (decknix-layout--state-buffer-names state)
                   (decknix-layout--state-buffer-names out)))
    (should-not (string-match-p "pixel" (prin1-to-string out)))
    (should (string-match-p "normal-width" (prin1-to-string out)))
    (should (string-match-p "window-side" (prin1-to-string out)))))

(provide 'decknix-layout-persist-test)
;;; decknix-layout-persist-test.el ends here
