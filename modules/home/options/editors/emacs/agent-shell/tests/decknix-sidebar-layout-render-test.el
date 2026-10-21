;;; decknix-sidebar-layout-render-test.el --- Tests for the layout render -*- lexical-binding: t -*-

;;; Commentary:
;;
;; The render is mostly `insert', so what is worth pinning is the part that
;; can silently change meaning: the feed items the Reviews section folds in.
;;
;; Requests used to be its own section behind four visibility filters.
;; Folding it into Reviews without reapplying them would re-show every
;; draft, conflicted and already-reviewed PR those filters exist to hide --
;; a regression that looks like a feature ("more rows!") and would be hard
;; to attribute later.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-sidebar-layout-render)

;; The hub bulk module owns the real special variable, but the isolated
;; layout-render package tests do not load it. A value is required here:
;; a bare `(defvar decknix--hub-reviews)' is only a compiler hint, so the
;; lexical `let' fixtures would never reach the renderer's dynamic read.
(defvar decknix--hub-reviews nil)
;; Upstream agent-shell-attention's pending table, special for the same reason.
(defvar agent-shell-attention--pending nil)

(ert-deftest decknix-layout-render--feed-items-obey-the-request-filters ()
  "Every item passes through all five filters, not none of them."
  (let ((decknix--hub-reviews
         '((items . (((repo . "o/a") (number . 1))
                     ((repo . "o/b") (number . 2))
                     ((repo . "o/c") (number . 3)))))))
    (cl-letf (((symbol-function 'decknix--hub-requests-attention-visible-p)
               (lambda (i) (not (equal 1 (alist-get 'number i)))))
              ((symbol-function 'decknix--hub-requests-reviewed-visible-p)
               (lambda (i) (not (equal 2 (alist-get 'number i)))))
              ((symbol-function 'decknix--hub-requests-draft-visible-p)
               (lambda (_i) t))
              ((symbol-function 'decknix--hub-requests-conflict-visible-p)
               (lambda (_i) t))
              ((symbol-function 'decknix--hub-requests-not-mine-visible-p)
               (lambda (_i) t)))
      (should (equal '(3) (mapcar (lambda (i) (alist-get 'number i))
                                  (decknix--layout-feed-items)))))))

(ert-deftest decknix-layout-render--every-filter-is-consulted ()
  "A filter left out of the conjunction is a silent regression; assert each
one can veto on its own."
  (dolist (vetoer '(decknix--hub-requests-attention-visible-p
                    decknix--hub-requests-reviewed-visible-p
                    decknix--hub-requests-draft-visible-p
                    decknix--hub-requests-conflict-visible-p
                    decknix--hub-requests-not-mine-visible-p))
    (let ((decknix--hub-reviews '((items . (((repo . "o/a") (number . 1)))))))
      (cl-letf (((symbol-function 'decknix--hub-requests-attention-visible-p)
                 (lambda (_i) t))
                ((symbol-function 'decknix--hub-requests-reviewed-visible-p)
                 (lambda (_i) t))
                ((symbol-function 'decknix--hub-requests-draft-visible-p)
                 (lambda (_i) t))
                ((symbol-function 'decknix--hub-requests-conflict-visible-p)
                 (lambda (_i) t))
                ((symbol-function 'decknix--hub-requests-not-mine-visible-p)
                 (lambda (_i) t)))
        (should (= 1 (length (decknix--layout-feed-items))))
        (cl-letf (((symbol-function vetoer) (lambda (_i) nil)))
          (should-not (decknix--layout-feed-items)))))))

(ert-deftest decknix-layout-render--no-feed-is-empty-not-an-error ()
  "The sidebar renders before the first hub poll returns."
  (let ((decknix--hub-reviews nil))
    (should-not (decknix--layout-feed-items))))

;; --- expansion state --------------------------------------------------

(ert-deftest decknix-layout-render--expansion-round-trips-through-a-file ()
  "Expansion has to survive a restart, like the other sidebar toggles."
  (let* ((tmp (make-temp-file "decknix-layout" nil ".el"))
         (decknix--layout-state-file tmp)
         (decknix--layout-expanded (make-hash-table :test 'equal)))
    (unwind-protect
        (progn
          (puthash "upside" t decknix--layout-expanded)
          (puthash "metabase" t decknix--layout-expanded)
          (decknix--layout-save-state)
          (clrhash decknix--layout-expanded)
          (should-not (decknix--layout-expanded-p "upside"))
          (decknix--layout-load-state)
          (should (decknix--layout-expanded-p "upside"))
          (should (decknix--layout-expanded-p "metabase"))
          (should-not (decknix--layout-expanded-p "never-expanded")))
      (delete-file tmp))))

(ert-deftest decknix-layout-render--collapsed-repos-are-not-persisted ()
  "Only the expanded set is written, so a collapse actually sticks."
  (let* ((tmp (make-temp-file "decknix-layout" nil ".el"))
         (decknix--layout-state-file tmp)
         (decknix--layout-expanded (make-hash-table :test 'equal)))
    (unwind-protect
        (progn
          (puthash "upside" t decknix--layout-expanded)
          (remhash "upside" decknix--layout-expanded)
          (decknix--layout-save-state)
          (decknix--layout-load-state)
          (should-not (decknix--layout-expanded-p "upside")))
      (delete-file tmp))))

(ert-deftest decknix-layout-render--missing-state-file-is-harmless ()
  (let ((decknix--layout-state-file "/nonexistent/dir/state.el")
        (decknix--layout-expanded (make-hash-table :test 'equal)))
    (should-not (decknix--layout-load-state))
    (should-not (decknix--layout-expanded-p "upside"))))

;; --- session name shortening ------------------------------------------

(ert-deftest decknix-layout-render--strips-the-agent-wrapper ()
  "Row width is 48 columns; `*Claude: ' is nine of them spent on nothing."
  (should (equal "decknix/nurturecloud"
                 (decknix--layout-short-name "*Claude: decknix/nurturecloud*")))
  (should (equal "pilot/us" (decknix--layout-short-name "*Pi: pilot/us*")))
  (should (equal "" (decknix--layout-short-name nil))))


;; --- row width and colour --------------------------------------------

(ert-deftest decknix-layout-render--width-comes-from-the-sidebar-window ()
  "`window-width' with no argument answers for whichever window is selected
when the render runs.  Measured 95 against the sidebar's 48, which padded
every row 47 columns too wide and pushed its right-hand value out of view."
  (let ((buf (generate-new-buffer " sb")))
    (unwind-protect
        (with-current-buffer buf
          (let ((win (display-buffer-in-side-window buf '((side . left)))))
            (should (window-live-p win))
            (with-selected-window win
              (ignore-errors (window-resize win (- 40 (window-width win)) t t)))
            ;; Selected window is NOT the sidebar here, which is the case
            ;; that broke: the bare call would answer for the other one.
            (should (= (window-width win) (decknix--layout-sidebar-width)))))
      (ignore-errors (delete-window (get-buffer-window buf)))
      (kill-buffer buf))))

(ert-deftest decknix-layout-render--width-falls-back-when-undisplayed ()
  "A render into a buffer no window is showing must not error."
  (with-temp-buffer
    (should (integerp (decknix--layout-sidebar-width)))))

(ert-deftest decknix-layout-render--pr-row-is-not-one-uniform-face ()
  "The whole row used to be painted a single severity face, which is what
made draft-versus-conflicting and human-versus-bot unreadable without
decoding the glyph shapes."
  (let* ((pr (list :number 240 :repo "upside" :branch "b"
                   :pr '((title . "ship scenario spec") (draft . t)
                         (author_kind . "human")
                         (ci . ((status . "pass"))))))
         (row (decknix--layout-pr-row pr 48))
         (faces (let (acc (i 0))
                  (while (< i (length row))
                    (push (get-text-property i 'face row) acc)
                    (setq i (1+ i)))
                  (delete-dups acc))))
    (should (> (length faces) 1))))

(ert-deftest decknix-layout-render--pr-row-prefers-the-title-over-the-branch ()
  (let ((pr (list :number 240 :branch "enhancement/HX-1039-envelope"
                  :pr '((title . "ship scenario spec")))))
    (should (string-match-p "ship scenario spec"
                            (decknix--layout-pr-row pr 60)))))

(ert-deftest decknix-layout-render--pr-row-falls-back-to-the-branch ()
  "A feed item with no title must still identify its row."
  (let ((pr (list :number 240 :branch "my-branch" :pr nil)))
    (should (string-match-p "my-branch" (decknix--layout-pr-row pr 60)))))

(ert-deftest decknix-layout-render--pr-row-never-exceeds-its-width ()
  "The glyphs are the part worth keeping when space runs out, so the title
truncates rather than pushing them off the end."
  (let ((pr (list :number 12345 :branch "b"
                  :pr (list (cons 'title (make-string 300 ?x))))))
    (dolist (w '(24 32 48 80))
      (should (<= (string-width (decknix--layout-pr-row pr w)) w)))))

(ert-deftest decknix-layout-render--a-worktree-is-a-hollow-shape ()
  "Hollow, because a worktree is the stage before a PR.  Dotted while
nothing is known about its build -- which is every worktree today, since
the audit records no build status at all."
  (should (equal "◌" (substring-no-properties
                      (decknix--layout-wt-glyph '(:branch "b"))))))

(ert-deftest decknix-layout-render--a-worktree-is-grey-until-a-build-is-known ()
  "Grey means nothing reported, which is honest: nothing runs or records
a per-worktree build."
  (should (eq 'shadow (get-text-property
                       0 'face (decknix--layout-wt-glyph '(:branch "b"))))))

(ert-deftest decknix-layout-render--a-merged-worktree-is-a-square ()
  (should (equal "■" (substring-no-properties
                      (decknix--layout-wt-glyph '(:merged t))))))

(ert-deftest decknix-layout-render--dirty-and-orphan-are-markers-not-the-shape ()
  "Both can be true at once.  As a single glyph one hid the other, and
uncommitted work is the state here that can actually be lost; as separate
markers both are visible."
  (let ((m (substring-no-properties
            (decknix--layout-wt-markers '(:dirty t :orphan t)))))
    (should (string-match-p "✎" m))
    (should (string-match-p "⑂" m))))

(ert-deftest decknix-layout-render--a-clean-worktree-has-no-markers ()
  (should (equal "" (substring-no-properties
                     (decknix--layout-wt-markers '(:branch "b"))))))

(ert-deftest decknix-layout-render--dirty-is-amber-and-orphan-is-red ()
  "They mean different things and must not read alike."
  (let ((d (decknix--layout-wt-markers '(:dirty t)))
        (o (decknix--layout-wt-markers '(:orphan t))))
    (should (eq 'warning (get-text-property 0 'face d)))
    (should (eq 'error (get-text-property 0 'face o)))))

;; --- the unattended section's summary rows ---------------------------
;;
;; The repo rows this section replaced carried NO text property, so RET on
;; one did nothing.  A count row that cannot reach its own remedy repeats
;; that in a smaller space, which is why the property is pinned here.

(defun decknix-lr-test--render-dormant (dormant)
  "Return the rendered unattended WIP group for DORMANT."
  (with-temp-buffer
    (decknix--layout-render-dormant 0 48 dormant)
    (buffer-string)))

(ert-deftest decknix-layout-render--orphan-count-can-reach-its-remedy ()
  (let* ((out (decknix-lr-test--render-dormant
               (list :worktrees (list (list :branch "a" :orphan t)))))
         (pos (string-match "orphaned" out)))
    (should pos)
    (should (get-text-property pos 'decknix-layout-orphan-prune out))))

(ert-deftest decknix-layout-render--a-clean-worktree-gets-no-row ()
  "Only the counted summary, so the section cannot fill up with rows that
hold no decision."
  (let ((out (decknix-lr-test--render-dormant
              (list :worktrees (list (list :branch "quiet-branch"))))))
    (should-not (string-match-p "quiet-branch" out))
    (should (string-match-p "1 quiet" out))))

(ert-deftest decknix-layout-render--a-dirty-worktree-is-named ()
  "Uncommitted work is the one thing here that can be lost, so it is never
reduced to a count."
  (let ((out (decknix-lr-test--render-dormant
              (list :worktrees (list (list :branch "has-work" :dirty t))))))
    (should (string-match-p "has-work" out))))

(ert-deftest decknix-layout-render--nothing-unattended-renders-nothing ()
  (should (equal "" (decknix-lr-test--render-dormant nil))))

(ert-deftest decknix-layout-render--the-limit-bounds-rows-and-names-the-tail ()
  (let* ((decknix-sidebar-layout-dormant-limit 2)
         (out (decknix-lr-test--render-dormant
               (list :worktrees (list (list :branch "w1" :dirty t)
                                      (list :branch "w2" :dirty t)
                                      (list :branch "w3" :dirty t))))))
    (should (string-match-p "w1" out))
    (should-not (string-match-p "w3" out))
    (should (string-match-p "1 more over the limit" out))))

(ert-deftest decknix-layout-render--unattended-items-sit-under-their-repo ()
  "Unattended rows used to name a PR or branch with no repo beside it."
  (let ((out (decknix-lr-test--render-dormant
              (list :worktrees (list (list :branch "has-work" :dirty t
                                           :repo "upsiderealty/attom-integration"))))))
    (should (string-match-p "no session" out))
    (should (string-match-p "⇡ attom-integration" out))
    (should (< (string-match "attom-integration" out) (string-match "has-work" out)))))

(ert-deftest decknix-layout-render--a-review-worktree-row-names-its-pr ()
  (let ((out (decknix-lr-test--render-dormant
              (list :worktrees (list (list :branch "dfebdad" :dirty t :repo "o/r"
                                           :path "/r/x-worktrees/pr-301"))))))
    (should (string-match-p "review #301" out))
    (should-not (string-match-p "dfebdad" out))))

(ert-deftest decknix-layout-render--review-title-matches-repo-case-insensitively ()
  (let ((decknix--hub-reviews
         '((items . (((repo . "UpsideRealty/upside") (number . 20742) (title . "Tidy")))))))
    (should (equal "Tidy" (decknix--layout-review-title "upsiderealty/upside" 20742)))
    (should-not (decknix--layout-review-title "upsiderealty/upside" 1))))

;; --- sub-agent rows ----------------------------------------------------

(defun decknix-lr-test--render-subagents (pairs &optional expanded hide-finished)
  "Render PAIRS, listing finished sub-agents unless HIDE-FINISHED."
  (let ((decknix-sidebar-show-finished-subagents (not hide-finished)))
    (cl-letf (((symbol-function 'decknix--layout-subagents-of) (lambda (_b) pairs))
              ((symbol-function 'decknix--layout-expanded-p) (lambda (_k) expanded)))
      (with-temp-buffer
        (decknix--layout-render-subagents 0 "*parent*" 48)
        (buffer-string)))))

(defconst decknix-lr-test--subs
  (list (cons '((agentType . "pr-implementer") (description . "Contacts 01.2 to ready")) 'running)
        (cons '((agentType . "pr-shepherd") (description . "dry draft-to-ready #1051")) 'done)
        (cons '((agentType . "Explore") (description . "find the enqueuer")) 'stopped)))

;; --- finished sub-agents hidden by default --------------------------------

(ert-deftest decknix-layout-render--finished-subagents-are-hidden-by-default ()
  (should-not (eval (car (get 'decknix-sidebar-show-finished-subagents 'standard-value)) t)))

(ert-deftest decknix-layout-render--all-finished-subagents-take-no-row ()
  (let ((out (decknix-lr-test--render-subagents (cdr decknix-lr-test--subs) t t)))
    (should (equal "" out))))

(ert-deftest decknix-layout-render--hidden-finished-leaves-a-lone-live-child-as-itself ()
  (let ((out (decknix-lr-test--render-subagents decknix-lr-test--subs nil t)))
    (should (= 1 (length (split-string out "\n" t))))
    (should (string-match-p "pr-implementer: Contacts" out))
    (should-not (string-match-p "agents" out))))

(ert-deftest decknix-layout-render--hidden-finished-counts-and-lists-only-live-ones ()
  (let* ((subs (cons (cons '((agentType . "Explore") (description . "map callers")) 'active)
                     decknix-lr-test--subs))
         (collapsed (decknix-lr-test--render-subagents subs nil t))
         (expanded (decknix-lr-test--render-subagents subs t t)))
    (should (string-match-p "2 agents ◐1 ◐1" collapsed))
    (should-not (string-match-p "[●■]" collapsed))
    (should (= 3 (length (split-string expanded "\n" t))))
    (should (string-match-p "Explore: map callers" expanded))
    (should-not (string-match-p "pr-shepherd\\|find the enqueuer" expanded))))

(ert-deftest decknix-layout-render--shown-finished-subagents-are-counted-and-listed ()
  (let ((out (decknix-lr-test--render-subagents (cdr decknix-lr-test--subs) t)))
    (should (string-match-p "2 agents ■1 ●1" out))
    (should (string-match-p "pr-shepherd: dry draft-to-ready" out))))

(ert-deftest decknix-layout-render--several-subagents-take-one-row ()
  (let ((out (decknix-lr-test--render-subagents decknix-lr-test--subs)))
    (should (= 1 (length (split-string out "\n" t))))
    (should (string-match-p "3 agents" out))
    (should-not (string-match-p "pr-implementer" out))))

(ert-deftest decknix-layout-render--expanded-subagents-say-what-each-is-doing ()
  (let ((out (decknix-lr-test--render-subagents decknix-lr-test--subs t)))
    (should (= 4 (length (split-string out "\n" t))))
    (should (string-match-p "pr-implementer: Contacts 01.2" out))
    (should (string-match-p "pr-shepherd: dry draft-to-ready" out))
    (should (string-match-p "Explore: find the enqueuer" out))
    (should-not (string-match-p "?" out))))

(ert-deftest decknix-layout-render--one-subagent-is-shown-as-itself ()
  (let ((out (decknix-lr-test--render-subagents (list (car decknix-lr-test--subs)))))
    (should (= 1 (length (split-string out "\n" t))))
    (should (string-match-p "pr-implementer: Contacts" out))))

(ert-deftest decknix-layout-render--subagent-rows-never-exceed-the-width ()
  (let ((out (decknix-lr-test--render-subagents
              (list (cons '((agentType . "pr-implementer")
                            (description . "an extremely long task description that cannot possibly fit"))
                          'running)))))
    (dolist (l (split-string out "\n" t)) (should (<= (string-width l) 48)))))

(ert-deftest decknix-layout-render--the-last-assistant-message-is-read-from-the-tail ()
  (let ((f (make-temp-file "dk-sub-" nil ".jsonl")))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert (json-encode '((message . ((role . "user") (content . "go"))))) "\n"
                    (json-encode '((message . ((role . "assistant") (content . [((type . "text") (text . "first"))]))))) "\n"
                    (json-encode '((message . ((role . "assistant") (content . [((type . "text") (text . "PR #1051 is ready"))]))))) "\n"))
          (should (equal "PR #1051 is ready" (decknix--layout-subagent-last-text f))))
      (delete-file f))))

(ert-deftest decknix-layout-render--a-long-subagent-list-is-capped ()
  "One session had run 156."
  (let* ((decknix-sidebar-layout-subagent-limit 10)
         (many (cl-loop for i below 25
                        collect (cons `((agentType . "x") (description . ,(format "task %d" i))) 'done)))
         (out (decknix-lr-test--render-subagents many t)))
    (should (= 12 (length (split-string out "\n" t))))
    (should (string-match-p "25 agents" out))
    (should (string-match-p "15 more" out))))

;; --- RET on session-bearing rows ---------------------------------------

(defmacro decknix-lr-test--with-buffers (names &rest body)
  "Run BODY with live buffers called NAMES, killed afterwards."
  (declare (indent 1))
  `(let ((bufs (mapcar #'get-buffer-create ,names)))
     (unwind-protect (progn ,@body)
       (mapc #'kill-buffer bufs))))

(defun decknix-lr-test--render-wip (sessions)
  "Return the rendered WIP section for SESSIONS."
  (cl-letf (((symbol-function 'decknix--layout-sessions) (lambda () sessions))
            ((symbol-function 'decknix--layout-wip-repos) (lambda () nil))
            ((symbol-function 'decknix--layout-worktrees) (lambda () nil))
            ((symbol-function 'decknix--layout-subagents-of) (lambda (_b) nil))
            ((symbol-function 'decknix--sidebar-render-section-header)
             (lambda (title &optional _id) (insert " " title "\n"))))
    (decknix-layout-invalidate-wip)
    (with-temp-buffer
      (decknix--layout-render-wip 0 48)
      (buffer-string))))

(ert-deftest decknix-layout-render--a-wip-row-carries-the-upstream-buffer-property ()
  "Upstream goto reads `agent-shell-workspace-buffer'; a WIP row without it
answered \"No live agent buffer at point\"."
  (decknix-lr-test--with-buffers '("*Claude: dk-wip*")
    (let* ((out (decknix-lr-test--render-wip
                 '(("*Claude: dk-wip*" nil nil "asking" nil nil))))
           (pos (string-match "dk-wip" out)))
      (should pos)
      (should (eq (get-buffer "*Claude: dk-wip*")
                  (get-text-property pos 'agent-shell-workspace-buffer out))))))

(ert-deftest decknix-layout-render--buffer-at-falls-back-to-the-layout-name ()
  (decknix-lr-test--with-buffers '("*Claude: dk-a*")
    (with-temp-buffer
      (insert (propertize "row" 'decknix-layout-buffer "*Claude: dk-a*") "\n"
              (propertize "row" 'decknix-layout-session '("*Claude: dk-a*")) "\n"
              (propertize "row" 'decknix-layout-buffer "*gone*") "\n")
      (should (eq (get-buffer "*Claude: dk-a*") (decknix-layout-buffer-at 1)))
      (should (eq (get-buffer "*Claude: dk-a*") (decknix-layout-buffer-at 5)))
      (should-not (decknix-layout-buffer-at 9)))))

(defun decknix-lr-test--ret-on-pr (key sessions)
  "Return `decknix-layout-ret-action' on a PR row for KEY given SESSIONS."
  (cl-letf (((symbol-function 'decknix--layout-sessions) (lambda () sessions)))
    (with-temp-buffer
      (insert (propertize "pr" 'decknix-layout-pr (list :key key)
                          'decknix-hub-type 'request))
      (decknix-layout-ret-action 1))))

(ert-deftest decknix-layout-render--ret-on-a-covered-pr-goes-to-its-session ()
  (decknix-lr-test--with-buffers '("*Claude: pr-upside-1*")
    (should (equal (list 'goto (get-buffer "*Claude: pr-upside-1*"))
                   (decknix-lr-test--ret-on-pr
                    "upside#1" '(("*Claude: pr-upside-1*" nil ("upside#1") "asking")))))))

(ert-deftest decknix-layout-render--ret-on-a-doubly-covered-pr-offers-a-choice ()
  (decknix-lr-test--with-buffers '("*Claude: a*" "*Claude: b*")
    (let ((action (decknix-lr-test--ret-on-pr
                   "upside#1" '(("*Claude: a*" nil ("upside#1") "asking")
                                ("*Claude: b*" nil ("upside#1") "ready")))))
      (should (eq 'choose (car action)))
      (should (= 2 (length (cadr action)))))))

(ert-deftest decknix-layout-render--ret-on-an-uncovered-pr-is-the-default ()
  "No session: nil, so the caller opens the request menu."
  (should-not (decknix-lr-test--ret-on-pr "upside#1" nil))
  (should-not (decknix-lr-test--ret-on-pr
               "upside#1" '(("*Claude: not-live*" nil ("upside#1") "asking")))))

;; --- row motion and the next session needing you ---------------------

(defun decknix-lr-test--rows ()
  "Insert a sidebar-like buffer: header, session rows, a tail, a PR row."
  (insert " Needs you\n"
          (propertize " ⚑  a" 'decknix-layout-buffer "*Claude: a*") "\n"
          "\n"
          (propertize " ·  3 quiet" 'face 'shadow) "\n"
          (propertize " ⚑  b" 'decknix-layout-buffer "*Claude: b*") "\n"
          (propertize "    #9" 'decknix-layout-pr '(:key "r#9")) "\n")
  (goto-char (point-min)))

(ert-deftest decknix-layout-render--n-and-p-skip-rows-without-an-action ()
  (with-temp-buffer
    (decknix-lr-test--rows)
    (decknix-layout-next-row)
    (should (looking-at " ⚑  a"))
    (decknix-layout-next-row)
    (should (looking-at " ⚑  b"))
    (decknix-layout-next-row)
    (should (looking-at "    #9"))
    ;; At the last actionable row, n stays put rather than running off.
    (decknix-layout-next-row)
    (should (looking-at "    #9"))
    (decknix-layout-prev-row)
    (should (looking-at " ⚑  b"))
    (decknix-layout-prev-row 2)
    (should (looking-at " ⚑  a"))))

(ert-deftest decknix-layout-render--j-walks-sessions-in-jump-order ()
  (decknix-lr-test--with-buffers '("*Claude: a*" "*Claude: b*")
    (let ((decknix-attention--seen (make-hash-table :test 'eq :weakness 'key)))
      (cl-letf (((symbol-function 'decknix--hub-review-session-snapshot)
                 (lambda () '(("*Claude: a*" nil nil "asking")
                              ("*Claude: b*" nil nil "netfail")))))
        (with-temp-buffer
          (decknix-lr-test--rows)
          ;; netfail outranks asking, so b first, then a, then round again.
          (decknix-layout-goto-next-attention)
          (should (looking-at " ⚑  b"))
          (decknix-layout-goto-next-attention)
          (should (looking-at " ⚑  a"))
          (decknix-layout-goto-next-attention)
          (should (looking-at " ⚑  b")))))))

(ert-deftest decknix-layout-render--j-finds-a-session-through-its-pr-row ()
  "A review session with no row of its own is reached through its PR."
  (decknix-lr-test--with-buffers '("*Claude: pr-r-9*")
    (let ((decknix-attention--seen (make-hash-table :test 'eq :weakness 'key))
          (sessions '(("*Claude: pr-r-9*" nil ("r#9") "asking"))))
      (cl-letf (((symbol-function 'decknix--hub-review-session-snapshot)
                 (lambda () sessions))
                ((symbol-function 'decknix--layout-sessions) (lambda () sessions)))
        (with-temp-buffer
          (decknix-lr-test--rows)
          (decknix-layout-goto-next-attention)
          (should (looking-at "    #9")))))))

;; --- Needs you ----------------------------------------------------------

(defun decknix-lr-test--render-needs-you (sessions &optional feed)
  "Return the rendered Needs-you block for SESSIONS with review FEED items."
  (let ((decknix--hub-reviews (and feed (list (cons 'items feed))))
        (decknix-attention--seen (make-hash-table :test 'eq :weakness 'key)))
    (cl-letf (((symbol-function 'decknix--layout-sessions) (lambda () sessions))
              ((symbol-function 'decknix--sidebar-render-section-header)
               (lambda (title &optional _id) (insert " " title "\n"))))
      (with-temp-buffer
        (decknix--layout-render-needs-you 0 48)
        (buffer-string)))))

(ert-deftest decknix-layout-render--needs-you-lists-every-blocked-session-first-ranked ()
  (decknix-lr-test--with-buffers '("*Claude: mine*" "*Claude: pr-upside-1*" "*Claude: idle*")
    (let ((out (decknix-lr-test--render-needs-you
                '(("*Claude: mine*" nil nil "asking")
                  ("*Claude: pr-upside-1*" nil ("upside#1") "waiting")
                  ("*Claude: idle*" nil nil "ready")))))
      (should (string-match-p "Needs you (2)" out))
      (should (< (string-match "pr-upside-1" out) (string-match "mine" out)))
      (should-not (string-match-p "idle" out)))))

(ert-deftest decknix-layout-render--a-blocked-review-on-a-merged-pr-is-not-hidden ()
  "The bug: pr-upside-21531 and friends asked for a decision, their PRs had
left the feed, and nothing anywhere showed them."
  (decknix-lr-test--with-buffers '("*Claude: pr-upside-21531*")
    (let* ((out (decknix-lr-test--render-needs-you
                 '(("*Claude: pr-upside-21531*" nil ("upside#21531") "asking"))
                 '(((repo . "UpsideRealty/upside") (number . 21556)))))
           (pos (string-match "pr-upside-21531" out)))
      (should pos)
      (should (string-match-p "PR gone" out))
      (should (eq (get-buffer "*Claude: pr-upside-21531*")
                  (get-text-property pos 'agent-shell-workspace-buffer out))))))

(ert-deftest decknix-layout-render--no-feed-does-not-call-a-pr-gone ()
  (decknix-lr-test--with-buffers '("*Claude: pr-upside-1*")
    (should-not (string-match-p
                 "PR gone"
                 (decknix-lr-test--render-needs-you
                  '(("*Claude: pr-upside-1*" nil ("upside#1") "asking")))))))

(ert-deftest decknix-layout-render--needs-you-is-absent-when-nothing-is-blocked ()
  (decknix-lr-test--with-buffers '("*Claude: a*")
    (should (equal "" (decknix-lr-test--render-needs-you
                       '(("*Claude: a*" nil nil "working")))))))

(ert-deftest decknix-layout-render--needs-you-rows-fit-the-width ()
  (decknix-lr-test--with-buffers '("*Claude: a-very-long-session-name/with/many/tags/indeed*")
    (dolist (l (split-string (decknix-lr-test--render-needs-you
                              '(("*Claude: a-very-long-session-name/with/many/tags/indeed*"
                                 nil nil "netfail")))
                             "\n" t))
      (should (<= (string-width l) 48)))))

(ert-deftest decknix-layout-render--wip-heading-counts-who-needs-you ()
  (decknix-lr-test--with-buffers '("*Claude: a*" "*Claude: b*")
    (let ((out (decknix-lr-test--render-wip
                '(("*Claude: a*" nil nil "asking" nil nil)
                  ("*Claude: b*" nil nil "working" nil nil)))))
      (should (string-match-p "WIP (2 — 1 need you" out)))))

;; --- what each session is asking --------------------------------------

(ert-deftest decknix-layout-render--needs-you-shows-what-it-asks ()
  (decknix-lr-test--with-buffers '("*Claude: q*")
    (cl-letf (((symbol-function 'decknix-agent-turn-closing-text)
               (lambda (&optional _b) "Rebased.\nForce-push or open a fresh PR?"))
              ((symbol-function 'decknix-agent-turn-question-excerpt)
               (lambda (text) (car (last (split-string text "\n" t))))))
      (let* ((out (decknix-lr-test--render-needs-you '(("*Claude: q*" nil nil "asking"))))
             (pos (string-match "↳ Force-push" out)))
        (should pos)
        (should (eq 'font-lock-comment-face (get-text-property pos 'face out)))
        ;; RET and `i' reach the session from the question line...
        (with-temp-buffer
          (insert out)
          (should (eq (get-buffer "*Claude: q*") (decknix-layout-buffer-at (1+ pos))))
          ;; ...but `n'/`p' pass over it.
          (should-not (decknix-layout-actionable-p (1+ pos))))))))

(ert-deftest decknix-layout-render--a-permission-prompt-names-what-it-wants ()
  (decknix-lr-test--with-buffers '("*Claude: w*")
    (let ((agent-shell-attention--pending (make-hash-table :test 'eq)))
      (puthash (get-buffer "*Claude: w*") (cons "Permission: Run gh pr merge (execute)" 1.0)
               agent-shell-attention--pending)
      (should (equal "Permission: Run gh pr merge (execute)"
                     (decknix-layout-session-ask (get-buffer "*Claude: w*") "waiting"))))))

(ert-deftest decknix-layout-render--the-ask-line-fits-the-width ()
  (let ((row (decknix--layout-ask-row '("x") (make-string 200 ?a) 48)))
    (should (<= (string-width row) 48))
    (should (string-suffix-p "…" row))))

(ert-deftest decknix-layout-render--nothing-to-say-means-no-ask-line ()
  (decknix-lr-test--with-buffers '("*Claude: q*")
    (cl-letf (((symbol-function 'decknix-agent-turn-closing-text) (lambda (&optional _b) nil))
              ((symbol-function 'decknix-agent-turn-question-excerpt) (lambda (_t) nil)))
      (should-not (string-match-p
                   "↳" (decknix-lr-test--render-needs-you '(("*Claude: q*" nil nil "asking"))))))))

(ert-deftest decknix-layout-render--inspect-shows-the-question-and-the-tail ()
  (decknix-lr-test--with-buffers '("*Claude: q*")
    (let ((decknix-attention--seen (make-hash-table :test 'eq :weakness 'key))
          (buf (get-buffer "*Claude: q*")))
      (with-current-buffer buf (insert "earlier output\nthe last line\n"))
      (decknix-attention-observe buf "asking" (- (float-time) 600))
      (cl-letf (((symbol-function 'decknix-agent-turn-closing-text)
                 (lambda (&optional _b) "Merge it?"))
                ((symbol-function 'decknix-agent-turn-question-excerpt)
                 (lambda (text) text)))
        (let ((text (decknix-layout-inspect-text buf)))
          (should (string-match-p "state: asking   for 10m" text))
          (should (string-match-p "asks:  Merge it?" text))
          (should (string-match-p "the last line" text)))))))

;; --- board focus ---------------------------------------------------------
;;
;; The focus package is not on this package's load path; its interface is
;; stubbed so these pin only what the sidebar does with the answers.

(defvar decknix--hub-wip nil)

(declare-function decknix-board-focus-sessions "decknix-board-focus" (sessions))

(defmacro decknix-lr-test--focused (in-repos in-sessions &rest body)
  "Run BODY focused on a board covering IN-REPOS and the IN-SESSIONS names."
  (declare (indent 2))
  `(let ((repos ,in-repos) (names ,in-sessions))
     (cl-letf (((symbol-function 'decknix-board-focus-active-p) (lambda () t))
               ((symbol-function 'decknix-board-focus-title) (lambda () "US Pilot"))
               ((symbol-function 'decknix-board-focus-repo-p)
                (lambda (r) (member (downcase r) repos)))
               ((symbol-function 'decknix-board-focus-path-p)
                (lambda (p) (string-match-p "upside" p)))
               ((symbol-function 'decknix-board-focus-sessions)
                (lambda (ss) (seq-filter (lambda (s) (member (car s) names)) ss)))
               ((symbol-function 'decknix-board-focus-elsewhere-count)
                (lambda (ss) (seq-count (lambda (s) (and (decknix-attention-state-p (nth 3 s))
                                                         (not (member (car s) names))))
                                        ss))))
       ,@body)))

(ert-deftest decknix-layout-render--focus-narrows-sessions-feed-wip-and-worktrees ()
  (let ((decknix--hub-reviews '((items . (((repo . "UpsideRealty/upside") (number . 1))
                                          ((repo . "UpsideRealty/other") (number . 2))))))
        (decknix--hub-wip '((repos . (((repo . "UpsideRealty/upside") (prs . nil))
                                      ((repo . "UpsideRealty/other") (prs . nil)))))))
    (cl-letf (((symbol-function 'decknix--hub-review-session-snapshot)
               (lambda () '(("in" nil nil "idle") ("out" nil nil "idle"))))
              ((symbol-function 'decknix-hub-wt-rows)
               (lambda () (list '(:repo "upside" :path "/c/upside-worktrees/a")
                                '(:repo "other" :path "/c/other-worktrees/b")
                                '(:path "/c/upside-worktrees/c")))))
      (decknix-lr-test--focused '("upsiderealty/upside" "upside") '("in")
        (should (equal (mapcar #'car (decknix--layout-sessions)) '("in")))
        (should (equal (mapcar (lambda (i) (alist-get 'number i)) (decknix--layout-raw-feed-items))
                       '(1)))
        (should (equal (mapcar (lambda (r) (alist-get 'repo r)) (decknix--layout-wip-repos))
                       '("UpsideRealty/upside")))
        (should (equal (mapcar (lambda (w) (plist-get w :path)) (decknix--layout-worktrees))
                       '("/c/upside-worktrees/a" "/c/upside-worktrees/c"))))
      ;; Unfocused, everything shows.
      (should (= 2 (length (decknix--layout-sessions))))
      (should (= 2 (length (decknix--layout-raw-feed-items))))
      (should (= 3 (length (decknix--layout-worktrees)))))))

(ert-deftest decknix-layout-render--focus-banner-names-the-board-and-the-keys ()
  (with-temp-buffer
    (should (= 0 (decknix--layout-render-focus 0 48)))
    (should (equal "" (buffer-string))))
  (decknix-lr-test--focused nil nil
    (with-temp-buffer
      (should (= 2 (decknix--layout-render-focus 0 48)))
      (should (string-match-p "\\` Focus: US Pilot +F clear · C-u F switch\n\n\\'"
                              (buffer-string))))))

(ert-deftest decknix-layout-render--focus-counts-who-needs-you-elsewhere ()
  "Focused Needs-you lists only the board's sessions, and says how many
outside it are blocked, so a focus never hides one silently."
  (decknix-lr-test--with-buffers '("*Claude: in*" "*Claude: out*" "*Claude: out2*")
    (let ((all '(("*Claude: in*" nil nil "asking")
                 ("*Claude: out*" nil nil "waiting")
                 ("*Claude: out2*" nil nil "asking"))))
      (cl-letf (((symbol-function 'decknix--hub-review-session-snapshot) (lambda () all)))
        (decknix-lr-test--focused nil '("*Claude: in*")
          (let ((out (decknix-lr-test--render-needs-you
                      (decknix-board-focus-sessions all))))
            (should (string-match-p "Needs you (1)" out))
            (should-not (string-match-p "Claude: out\\|  out" out))
            (should (string-match-p "^ \\+2 need you elsewhere$" out)))
          ;; Nothing blocked inside the focus: the count still shows.
          (let ((out (decknix-lr-test--render-needs-you nil)))
            (should-not (string-match-p "Needs you" out))
            (should (string-match-p "\\+2 need you elsewhere" out))))))))

(ert-deftest decknix-layout-render--j-stays-inside-the-focus ()
  (decknix-lr-test--with-buffers '("*Claude: in*" "*Claude: out*")
    (let ((all '(("*Claude: in*" nil nil "asking") ("*Claude: out*" nil nil "netfail")))
          (decknix-attention--seen (make-hash-table :test 'eq :weakness 'key))
          (decknix-attention-focus-function
           (lambda (ss) (seq-filter (lambda (s) (equal (car s) "*Claude: in*")) ss))))
      (cl-letf (((symbol-function 'decknix--hub-review-session-snapshot) (lambda () all)))
        (with-temp-buffer
          (should (eq (decknix-layout--next-attention-target)
                      (get-buffer "*Claude: in*"))))))))

(provide 'decknix-sidebar-layout-render-test)
;;; decknix-sidebar-layout-render-test.el ends here
