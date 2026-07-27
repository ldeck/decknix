;;; decknix-dos-board.el --- Live, actionable TechOps DoS priority board -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: techops, dos, support, agent, decknix

;;; Commentary:
;;
;; The "living playbook": a read-only, auto-refreshing Emacs board that turns
;; the TechOps Developer-on-Support (DoS) runbook decision tree into an ordered,
;; single-key-actionable worklist.
;;
;; It does NOT recompute anything: the terminal `nc-dos-sidebar' CLI
;; (decknix-config pkgs/nc-dos) is the single engine that reads Jira/Confluence
;; and flattens the Playbook priority order (production incidents -> alerts ->
;; DoS tasks) into a typed item list.  This board renders `nc-dos-sidebar --json'
;; as magit-like lanes and delegates every action back to that one CLI, so the
;; emacs and terminal experiences stay in perfect parity and share one state
;; file.  Emacs contributes what a terminal can't: constant-attention lanes, a
;; cursor, and one-keystroke actions on the row at point.
;;
;; Single-key actions on the item at point:
;;
;;   RET / o  browse the ticket
;;   i        spawn a FOREGROUND agent (emacs agent-shell) on it, runbook-primed
;;   x        spawn a BACKGROUND `claude -p' agent (logged to the nc-dos runs dir)
;;   c        copy the exact fg/bg spawn commands to the kill-ring
;;   n / p    next / previous item      (TAB / S-TAB also move)
;;   g        refresh                    ? or .  action menu (magit-style)
;;   r        open the current Weekly Techops Report
;;   W        export today's support worksheet (live counts) into Emacs
;;   q        bury the board
;;
;; The header is the "constant attention" surface: date, weekday, deploy/freeze
;; posture, Weekly-Report freshness, and the live open-work counts.
;;
;; Pure (ERT-tested) surface: `decknix-dos-board--parse',
;; `decknix-dos-board--lane-items', `decknix-dos-board--item-line',
;; `decknix-dos-board--report-status', `decknix-dos-board--header-lines',
;; `decknix-dos-board--truncate'.  The async CLI run, render, timer, and actions
;; are the impure shell.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup decknix-dos-board nil
  "Live TechOps DoS priority board."
  :group 'decknix)

(defcustom decknix-dos-board-cli "nc-dos-sidebar"
  "The nc-dos priority-console CLI that computes the board and owns spawns."
  :type 'string :group 'decknix-dos-board)

(defcustom decknix-dos-board-worksheet-cli "nc-dos-worksheet"
  "The nc-dos CLI that writes a per-day support worksheet seeded with live counts."
  :type 'string :group 'decknix-dos-board)

(defcustom decknix-dos-board-refresh-interval 90
  "Seconds between background refreshes while the board is visible."
  :type 'integer :group 'decknix-dos-board)

(defconst decknix-dos-board-buffer-name "*DoS Board*"
  "Name of the DoS priority board buffer.")

(defvar decknix-dos-board--model nil
  "The most recently parsed board model (an alist), or nil.")

(defvar decknix-dos-board--timer nil
  "Repeating visibility-gated refresh timer, or nil.")

;; Text properties stamped on each actionable item row.
;; `decknix-dos-key' is the row's Jira key; its presence marks an item row.

;; ── Pure layer ─────────────────────────────────────────────────────────

(defun decknix-dos-board--parse (json-string)
  "Parse JSON-STRING (nc-dos --json output) into an alist model, or nil.
Keys are symbols; JSON arrays become lists; null/false become nil."
  (when (and json-string (stringp json-string)
             (not (string-empty-p (string-trim json-string))))
    (ignore-errors
      (json-parse-string json-string
                         :object-type 'alist :array-type 'list
                         :null-object nil :false-object nil))))

(defun decknix-dos-board--lane-items (model kind)
  "Return MODEL's `items' whose `kind' equals KIND (a string), in order."
  (seq-filter (lambda (it) (equal (alist-get 'kind it) kind))
              (alist-get 'items model)))

(defun decknix-dos-board--truncate (s n)
  "Return S (nil -> \"\") collapsed to one line and clipped to N chars."
  (let* ((s (or s ""))
         (s (replace-regexp-in-string "[\n\r\t ]+" " " s))
         (s (string-trim s)))
    (if (<= (length s) n) s (concat (substring s 0 (max 0 (1- n))) "…"))))

(defun decknix-dos-board--item-line (item &optional width)
  "Format ITEM as a single scannable line (no text properties).
WIDTH bounds the summary (default 64).  Shape:
  KEY  STATUS  summary…  [ai]  @assignee"
  (let* ((key (or (alist-get 'key item) "?"))
         (status (decknix-dos-board--truncate (alist-get 'status item) 16))
         (ai (and (alist-get 'ai_able item) " [ai]"))
         (assignee (alist-get 'assignee item))
         (assignee (if (and assignee (not (string-empty-p assignee))
                            (not (equal (downcase assignee) "unassigned")))
                       (concat "  @" assignee) ""))
         (summary (decknix-dos-board--truncate
                   (alist-get 'summary item) (or width 64))))
    (format "%-9s %-16s %s%s%s" key status summary (or ai "") assignee)))

(defun decknix-dos-board--report-status (report today-str)
  "Classify REPORT freshness against TODAY-STR (\"YYYY-MM-DD\").
Returns (SYMBOL . TITLE): `current' when REPORT's title starts with TODAY-STR,
`stale' when a report exists but is older, `missing' when REPORT is nil."
  (let ((title (alist-get 'title report)))
    (cond
     ((null report) (cons 'missing nil))
     ((and title (string-prefix-p today-str title)) (cons 'current title))
     (t (cons 'stale title)))))

(defun decknix-dos-board--header-lines (model &optional today-str)
  "Return the board's context header as a list of plain strings.
TODAY-STR defaults to today; passed in so tests pin the clock."
  (let* ((today (or today-str (format-time-string "%Y-%m-%d")))
         (weekday (or (alist-get 'weekday model) ""))
         (generated (or (alist-get 'generated model) ""))
         (freeze (alist-get 'freeze model))
         (deploy (alist-get 'deploy_day model))
         (incidents (length (decknix-dos-board--lane-items model "incident")))
         (alerts (or (length (alist-get 'alr_untriaged model)) 0))
         (alr-todo (or (alist-get 'alr_triaged_todo_count model) 0))
         (dos-open (or (alist-get 'dos_open_count model) 0))
         (dos-mine (length (alist-get 'dos_mine_in_progress model)))
         (hot-other (length (alist-get 'hot_other model)))
         (rs (decknix-dos-board--report-status (alist-get 'report model) today))
         (posture (cond
                   (freeze "Deploy FREEZE (Fri–Sun) — no scheduled deploys.")
                   (deploy "DEPLOY DAY (Tue/Thu) — promote shared services to prod by noon.")
                   (t "No scheduled deploy today.")))
         (report-line (pcase (car rs)
                        ('current (format "Report: %s  ✓ current" (cdr rs)))
                        ('stale   (format "Report: %s  ⚠ not today — draft today's entry"
                                          (cdr rs)))
                        ('missing "Report: ⚠ none found for this week"))))
    (list
     (format "%s · %s" (if (string-empty-p weekday) "DoS Board" weekday) generated)
     posture
     report-line
     (format "Open: %d incident%s · %d untriaged alert%s (+%d ToDo) · %d DoS (%d mine) · %d HOT"
             incidents (if (= incidents 1) "" "s")
             alerts (if (= alerts 1) "" "s") alr-todo
             dos-open dos-mine hot-other))))

(defconst decknix-dos-board--lanes
  '(("incident" . "PRODUCTION INCIDENTS  (preempt all other work)")
    ("alert"    . "ALERTS  (top work priority — Playbook §6.1)")
    ("dos"      . "DoS TASKS & FIXES  (mine in-progress, then unassigned ToDo)"))
  "Ordered (KIND . HEADING) lanes rendered top-to-bottom.")

;; ── Impure shell: async CLI run ────────────────────────────────────────

(defun decknix-dos-board--run (args on-done)
  "Run the nc-dos CLI with ARGS (a list) async; call ON-DONE with trimmed stdout.
No-ops with a message when the CLI is absent (e.g. before `decknix switch')."
  (if (not (executable-find decknix-dos-board-cli))
      (message "%s not on PATH (run decknix switch)" decknix-dos-board-cli)
    (let ((buf (generate-new-buffer " *decknix-dos-board-cli*")))
      (make-process
       :name "decknix-dos-board-cli"
       :buffer buf
       :noquery t
       :connection-type 'pipe
       :command (cons decknix-dos-board-cli args)
       :sentinel
       (lambda (proc _e)
         (when (memq (process-status proc) '(exit signal))
           (let ((out (and (buffer-live-p buf)
                           (with-current-buffer buf (buffer-string)))))
             (when (buffer-live-p buf) (kill-buffer buf))
             (funcall on-done (string-trim (or out ""))))))))))

;; ── Render ─────────────────────────────────────────────────────────────

(defface decknix-dos-board-incident '((t :inherit error :weight bold))
  "Face for the production-incident lane." :group 'decknix-dos-board)
(defface decknix-dos-board-alert '((t :inherit warning))
  "Face for the alerts lane." :group 'decknix-dos-board)
(defface decknix-dos-board-heading '((t :inherit font-lock-keyword-face :weight bold))
  "Face for lane headings." :group 'decknix-dos-board)
(defface decknix-dos-board-context '((t :inherit shadow))
  "Face for the header context." :group 'decknix-dos-board)
(defface decknix-dos-board-ai '((t :inherit success))
  "Face highlighting ai-able items." :group 'decknix-dos-board)

(defun decknix-dos-board--insert-item (item kind)
  "Insert one propertized, actionable ITEM row for lane KIND."
  (let* ((beg (point))
         (face (pcase kind
                 ("incident" 'decknix-dos-board-incident)
                 ("alert" 'decknix-dos-board-alert)
                 (_ nil)))
         (line (decknix-dos-board--item-line item)))
    (insert "  " (if face (propertize line 'face face) line) "\n")
    (add-text-properties
     beg (point)
     (list 'decknix-dos-key (alist-get 'key item)
           'decknix-dos-kind kind
           'decknix-dos-url (alist-get 'url item)
           'decknix-dos-ai (and (alist-get 'ai_able item) t)))))

(defun decknix-dos-board--render (model)
  "Render MODEL into the current (writable) board buffer."
  (erase-buffer)
  (insert (propertize "DoS Priority Board — the living playbook\n"
                      'face 'decknix-dos-board-heading))
  (dolist (l (decknix-dos-board--header-lines model))
    (insert (propertize (concat l "\n") 'face 'decknix-dos-board-context)))
  (insert (propertize
           "\n  Actions: RET open · i agent · x bg-agent · c copy-cmd · n/p move · g refresh · ? help\n\n"
           'face 'decknix-dos-board-context))
  (dolist (lane decknix-dos-board--lanes)
    (let* ((kind (car lane))
           (items (decknix-dos-board--lane-items model kind)))
      (insert (propertize (format "▐ %s" (cdr lane))
                          'face 'decknix-dos-board-heading))
      (insert (propertize (format "  (%d)\n" (length items))
                          'face 'decknix-dos-board-context))
      (if items
          (dolist (it items) (decknix-dos-board--insert-item it kind))
        (insert (propertize "  — none —\n" 'face 'decknix-dos-board-context)))
      (insert "\n")))
  (goto-char (point-min))
  (decknix-dos-board-next-item))

;; ── Navigation ─────────────────────────────────────────────────────────

(defun decknix-dos-board--on-item-p ()
  "Non-nil when point is on an actionable item row."
  (get-text-property (line-beginning-position) 'decknix-dos-key))

(defun decknix-dos-board-next-item ()
  "Move point to the next actionable item row (wrap to first)."
  (interactive)
  (let ((start (point)) (found nil))
    (save-excursion
      (forward-line 1)
      (while (and (not found) (not (eobp)))
        (when (get-text-property (point) 'decknix-dos-key)
          (setq found (point)))
        (forward-line 1)))
    (unless found
      (save-excursion
        (goto-char (point-min))
        (while (and (not found) (< (point) start))
          (when (get-text-property (point) 'decknix-dos-key)
            (setq found (point)))
          (forward-line 1))))
    (when found (goto-char found) (beginning-of-line))))

(defun decknix-dos-board-prev-item ()
  "Move point to the previous actionable item row (wrap to last)."
  (interactive)
  (let ((start (point)) (found nil))
    (save-excursion
      (forward-line -1)
      (while (and (not found) (not (bobp)))
        (when (get-text-property (point) 'decknix-dos-key)
          (setq found (point)))
        (forward-line -1))
      (when (and (not found) (bobp)
                 (get-text-property (point) 'decknix-dos-key))
        (setq found (point))))
    (unless found
      (save-excursion
        (goto-char (point-max))
        (while (and (not found) (> (point) start))
          (when (get-text-property (line-beginning-position) 'decknix-dos-key)
            (setq found (line-beginning-position)))
          (forward-line -1))))
    (when found (goto-char found) (beginning-of-line))))

;; ── Actions (delegate to the one CLI) ──────────────────────────────────

(defun decknix-dos-board-key-at-point ()
  "Return the Jira key of the item row at point, or nil."
  (get-text-property (line-beginning-position) 'decknix-dos-key))

(defun decknix-dos-board-browse ()
  "Open the ticket for the item at point in a browser."
  (interactive)
  (let ((url (get-text-property (line-beginning-position) 'decknix-dos-url)))
    (if url (browse-url url) (user-error "No item on this row"))))

(defun decknix-dos-board-spawn-foreground ()
  "Spawn a FOREGROUND, runbook-primed agent on the item at point.
Delegates to `nc-dos-sidebar --spawn-fg', which auto-targets emacs agent-shell."
  (interactive)
  (let ((key (decknix-dos-board-key-at-point)))
    (unless key (user-error "No item on this row"))
    (message "Spawning foreground agent on %s…" key)
    (decknix-dos-board--run
     (list "--spawn-fg" key)
     (lambda (out) (message "%s" (if (string-empty-p out) "agent spawned" out))))))

(defun decknix-dos-board-spawn-background ()
  "Spawn a BACKGROUND `claude -p' agent on the item at point (logged; async)."
  (interactive)
  (let ((key (decknix-dos-board-key-at-point)))
    (unless key (user-error "No item on this row"))
    (message "Spawning background agent on %s…" key)
    (decknix-dos-board--run
     (list "--spawn-bg" key)
     (lambda (out)
       (message "%s" (if (string-empty-p out) "background agent spawned" out))))))

(defun decknix-dos-board-copy-command ()
  "Copy the exact fg/bg spawn commands for the item at point to the kill-ring."
  (interactive)
  (let ((key (decknix-dos-board-key-at-point)))
    (unless key (user-error "No item on this row"))
    (decknix-dos-board--run
     (list "--print-cmd" key)
     (lambda (out)
       (kill-new out)
       (with-output-to-temp-buffer "*decknix-dos-command*" (princ out))
       (message "Spawn commands for %s copied to kill-ring" key)))))

(defun decknix-dos-board-open-report ()
  "Open the current Weekly Techops Report from the board model."
  (interactive)
  (let ((url (alist-get 'url (alist-get 'report decknix-dos-board--model))))
    (if url (browse-url url)
      (message "No Weekly Techops Report resolved yet"))))

(defun decknix-dos-board-worksheet ()
  "Write today's support worksheet (live counts) and open it in Emacs.
The report is an export surface for the audits — this seeds today's entry from
the same live board state, ready to review and paste into the Weekly Report."
  (interactive)
  (if (not (executable-find decknix-dos-board-worksheet-cli))
      (message "%s not on PATH (run decknix switch)"
               decknix-dos-board-worksheet-cli)
    (message "Writing today's DoS worksheet…")
    (let ((buf (generate-new-buffer " *decknix-dos-worksheet*")))
      (make-process
       :name "decknix-dos-worksheet"
       :buffer buf
       :noquery t
       :connection-type 'pipe
       :command (list decknix-dos-board-worksheet-cli)
       :sentinel
       (lambda (proc _e)
         (when (memq (process-status proc) '(exit signal))
           (let ((path (and (buffer-live-p buf)
                            (string-trim
                             (with-current-buffer buf (buffer-string))))))
             (when (buffer-live-p buf) (kill-buffer buf))
             (if (and path (file-exists-p path))
                 (progn (find-file-other-window path)
                        (message "DoS worksheet: %s" path))
               (message "worksheet CLI produced no file (%s)"
                        (or path "no output"))))))))))

;; ── Refresh + lifecycle ────────────────────────────────────────────────

(defun decknix-dos-board-refresh (&optional quiet)
  "Recompute the board via `nc-dos-sidebar --json' and redraw (async).
With QUIET non-nil (the visibility-gated tick), skip the progress message."
  (interactive)
  (let ((buf (get-buffer decknix-dos-board-buffer-name)))
    (when buf
      (decknix-dos-board--run
       '("--json")
       (lambda (out)
         (let ((model (decknix-dos-board--parse out)))
           (when (buffer-live-p buf)
             (with-current-buffer buf
               (let ((inhibit-read-only t)
                     (line (line-number-at-pos)))
                 (if model
                     (progn (setq decknix-dos-board--model model)
                            (decknix-dos-board--render model)
                            (goto-char (point-min))
                            (forward-line (1- line))
                            (beginning-of-line))
                   (erase-buffer)
                   (insert "Could not compute the DoS board.\n\n"
                           "`" decknix-dos-board-cli "' produced no parseable JSON.\n"
                           "Check `atlassian-cli auth status' and try `g' to refresh."))))))))))
  (unless quiet (message "Computing DoS priority board…")))

(defun decknix-dos-board--visible-p ()
  "Non-nil when the board buffer is showing in some window."
  (let ((buf (get-buffer decknix-dos-board-buffer-name)))
    (and buf (get-buffer-window buf 'visible))))

(defun decknix-dos-board--tick ()
  "Timer callback: refresh only while the board is visible (never blocks)."
  (when (decknix-dos-board--visible-p)
    (decknix-dos-board-refresh t)))

(defvar decknix-dos-board-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'decknix-dos-board-browse)
    (define-key map (kbd "o")   #'decknix-dos-board-browse)
    (define-key map (kbd "i")   #'decknix-dos-board-spawn-foreground)
    (define-key map (kbd "x")   #'decknix-dos-board-spawn-background)
    (define-key map (kbd "c")   #'decknix-dos-board-copy-command)
    (define-key map (kbd "n")   #'decknix-dos-board-next-item)
    (define-key map (kbd "p")   #'decknix-dos-board-prev-item)
    (define-key map (kbd "TAB") #'decknix-dos-board-next-item)
    (define-key map (kbd "<backtab>") #'decknix-dos-board-prev-item)
    (define-key map (kbd "r")   #'decknix-dos-board-open-report)
    (define-key map (kbd "W")   #'decknix-dos-board-worksheet)
    (define-key map (kbd "g")   #'decknix-dos-board-refresh)
    (define-key map (kbd "?")   #'decknix-dos-board-transient)
    (define-key map (kbd ".")   #'decknix-dos-board-transient)
    (define-key map (kbd "q")   #'quit-window)
    map)
  "Keymap for `decknix-dos-board-mode'.")

(require 'transient)

(transient-define-prefix decknix-dos-board-transient ()
  "TechOps DoS priority board actions (the item at point)."
  ["Item at point"
   ("RET" "Browse ticket"                  decknix-dos-board-browse)
   ("i"   "Foreground agent (agent-shell)" decknix-dos-board-spawn-foreground)
   ("x"   "Background agent (claude -p)"    decknix-dos-board-spawn-background)
   ("c"   "Copy spawn commands"            decknix-dos-board-copy-command)]
  ["Move"
   ("n" "Next item"     decknix-dos-board-next-item :transient t)
   ("p" "Previous item" decknix-dos-board-prev-item :transient t)]
  ["Board"
   ("r" "Open Weekly Report"        decknix-dos-board-open-report)
   ("W" "Export today's worksheet"  decknix-dos-board-worksheet)
   ("g" "Refresh"                   decknix-dos-board-refresh)
   ("q" "Bury"                      quit-window)])

(define-derived-mode decknix-dos-board-mode special-mode "DoS-Board"
  "Major mode for the live TechOps DoS priority board.

The board renders the runbook priority order (production incidents -> alerts ->
DoS tasks) computed by `nc-dos-sidebar', with single-key actions on the row at
point.  Press `?' for the action menu.

\\{decknix-dos-board-mode-map}"
  (setq-local revert-buffer-function
              (lambda (&rest _) (decknix-dos-board-refresh)))
  (setq-local cursor-type 'box))

;;;###autoload
(defun decknix-dos-board ()
  "Open the live TechOps DoS priority board and refresh it.
Read-only; press `?' for the action menu.  Every action is delegated to the
`nc-dos-sidebar' CLI so the emacs and terminal experiences stay in parity."
  (interactive)
  (let ((buf (get-buffer-create decknix-dos-board-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'decknix-dos-board-mode)
        (decknix-dos-board-mode))
      (when decknix-dos-board--model
        (let ((inhibit-read-only t))
          (decknix-dos-board--render decknix-dos-board--model)))
      (unless decknix-dos-board--model
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert "Computing the DoS priority board…\n"))))
    (pop-to-buffer buf)
    (decknix-dos-board-refresh)))

(provide 'decknix-dos-board)
;;; decknix-dos-board.el ends here
