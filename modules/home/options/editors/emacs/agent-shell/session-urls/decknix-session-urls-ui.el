;;; decknix-session-urls-ui.el --- Pick, cycle and act on a session's URLs; review-session mode -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-session-urls "0.1"))
;; Keywords: agent, url, review

;;; Commentary:
;;
;; The keyboard way to the links a session is handling, instead of
;; scrolling up to find them.
;;
;; In every agent-shell buffer, under the session prefix:
;;
;;   C-c s O   pick a URL (identity PRs first, then most recent) and open it
;;   C-c s U   act on the URL at point, or on a picked one (transient)
;;   C-c s <   move to the previous URL in the buffer and highlight it
;;   C-c s >   move to the next one
;;
;; After a move, `n'/`p' (or `<'/`>') keep cycling and `RET'/`o' open,
;; `w' copy, `m' copy as Markdown, `a' act; any other key ends the cycle
;; and does what it normally does.
;;
;; `decknix-review-session-mode' is switched on in review sessions and
;; adds review-shaped keys in two tiers:
;;
;;   - `C-c C-<key>' chords, free in comint and agent-shell, which work
;;     anywhere, including while typing a prompt;
;;   - single letters that act only when point is in the transcript.  At
;;     the prompt they insert themselves, the same contract agent-shell's
;;     own `n'/`p' follow, so typing is never broken.  The letters avoid
;;     every key agent-shell binds (`n' `p' `r' `+' `-' `0' TAB).
;;
;; Nothing here runs at load time: the key installation, the hooks and
;; the embark integration are functions the configuration calls.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'transient)
(require 'decknix-session-urls)

(declare-function decknix--agent-review-prs-for-conv-key "decknix-agent-session-broker" (conv-key))
(declare-function decknix--agent-linked-prs "decknix-agent-link-store" (conv-key))
(declare-function decknix--agent-pr-url-accessor "decknix-agent-url-parse" (pr field))
(declare-function decknix-session-assoc-created "decknix-session-assoc" (key))
(declare-function decknix-review-board-row-url "decknix-review-board" (row))
(declare-function decknix-review-board "decknix-review-board")
(declare-function decknix-agent-turn-quick-reply "decknix-agent-turn-signals" (buffer key))
(declare-function decknix-agent-turn-reply-key "decknix-agent-turn-signals" (event))
(declare-function decknix--compose-get-or-create "decknix-agent-shell-main-compose" (target))
(declare-function decknix--open-url "decknix-agent-shell-workspace" (url &optional new-session))
(declare-function xwidget-webkit-browse-url "xwidget" (url &optional new-session))
(declare-function which-key-add-keymap-based-replacements "which-key" (keymap key replacement &rest more))
(declare-function eww "eww" (url &optional arg buffer))
(defvar decknix--agent-conv-key)
(defvar decknix--agent-broker-key)
(defvar embark-keymap-alist)
(defvar decknix--use-xwidget-webkit)
(defvar embark-url-map)

(defface decknix-session-url-highlight
  '((t :inherit highlight :weight bold))
  "Face for the URL the cycling commands landed on."
  :group 'decknix-session-urls)

;; ── identity + cache ─────────────────────────────────────────────────

(defun decknix-session-urls--review-keys ()
  "Return the `repo#N' keys the current session reviews, or nil.
Recorded coordinates first; the buffer-name convention only as a
fallback for a session that predates recording."
  (or (let ((ck (bound-and-true-p decknix--agent-conv-key)))
        (and ck (fboundp 'decknix--agent-review-prs-for-conv-key)
             (ignore-errors (decknix--agent-review-prs-for-conv-key ck))))
      (when-let* ((k (decknix-session-urls-review-key-from-name (buffer-name))))
        (list k))))

(defun decknix-session-urls--review-key-url (key)
  "Return the PR URL for review KEY (`repo#N' or `owner/repo#N'), or nil."
  (or (decknix-session-urls-pr-key-url key)
      (and (fboundp 'decknix-review-board-row-url)
           (ignore-errors (decknix-review-board-row-url (list :prs (list key)))))))

(defun decknix-session-urls--identity ()
  "Return the current session's identity URLs, as `collect' expects them."
  (let ((ck (bound-and-true-p decknix--agent-conv-key))
        (bk (and (local-variable-p 'decknix--agent-broker-key)
                 (bound-and-true-p decknix--agent-broker-key)))
        out)
    (dolist (key (decknix-session-urls--review-keys))
      (when-let* ((url (decknix-session-urls--review-key-url key)))
        (push (list :url url :source 'reviewing) out)))
    (when (and ck (fboundp 'decknix--agent-linked-prs) (fboundp 'decknix--agent-pr-url-accessor))
      (dolist (rec (ignore-errors (decknix--agent-linked-prs ck)))
        (let ((url (decknix--agent-pr-url-accessor rec "url")))
          (when (stringp url)
            (push (list :url url :source 'linked
                        :detail (decknix--agent-pr-url-accessor rec "type"))
                  out)))))
    (when (and bk (fboundp 'decknix-session-assoc-created))
      (dolist (pr (ignore-errors (decknix-session-assoc-created bk)))
        (when-let* ((url (decknix-session-urls-pr-key-url pr)))
          (push (list :url url :source 'created) out))))
    (nreverse out)))

(defvar-local decknix-session-urls--cache nil
  "(TICK IDENTITY . ENTRIES) from the last collection in this buffer.")

(defun decknix-session-urls-entries (&optional buffer)
  "Return BUFFER's session URLs (see `decknix-session-urls-collect').
Cached until the buffer text or the session's identity changes, so a
repeat press costs a tick comparison, not a rescan."
  (with-current-buffer (or buffer (current-buffer))
    (let ((tick (buffer-chars-modified-tick))
          (ident (decknix-session-urls--identity))
          (c decknix-session-urls--cache))
      (if (and c (eql (car c) tick) (equal (cadr c) ident))
          (cddr c)
        (let* ((start (max (point-min) (- (point-max) decknix-session-urls-scan-limit)))
               (entries (decknix-session-urls-collect
                         ident (buffer-substring-no-properties start (point-max))
                         start decknix-session-urls-jira-base-url)))
          (setq decknix-session-urls--cache (cons tick (cons ident entries)))
          entries)))))

(defun decknix-session-urls-entry-for (url)
  "Return the collected entry for URL, else a fresh classification."
  (or (seq-find (lambda (e) (equal (plist-get e :url) url))
                (ignore-errors (decknix-session-urls-entries)))
      (decknix-session-urls-classify url)))

;; ── picking ──────────────────────────────────────────────────────────

(defun decknix-session-urls-read (prompt &optional entries)
  "Read one of ENTRIES (default: this session's) with PROMPT; return its plist.
Candidates are the URLs themselves, in collection order, under the
`decknix-session-url' category so embark acts on them."
  (let* ((entries (or entries (decknix-session-urls-entries)))
         (table (mapcar (lambda (e) (cons (plist-get e :url) e)) entries)))
    (unless table (user-error "No URLs in this session"))
    (let* ((annotate (lambda (url)
                       (decknix-session-urls-annotation (cdr (assoc url table)))))
           (coll (lambda (str pred action)
                   (if (eq action 'metadata)
                       `(metadata (category . decknix-session-url)
                                  (annotation-function . ,annotate)
                                  (display-sort-function . identity)
                                  (cycle-sort-function . identity))
                     (complete-with-action action table str pred))))
           (url (completing-read prompt coll nil t nil nil (caar table))))
      (or (cdr (assoc url table)) (decknix-session-urls-classify url)))))

;; ── actions ──────────────────────────────────────────────────────────

(defun decknix-session-urls--xwidget-p ()
  "Non-nil when this Emacs can show a page in xwidget-webkit."
  (and (featurep 'xwidget-internal) (fboundp 'xwidget-webkit-browse-url)))

(defun decknix-session-urls--board-key (entry)
  "Return ENTRY's Review Board key (`repo#N'), when it is a PR."
  (and (plist-get entry :pr-url) (plist-get entry :key)))

(defun decknix-session-urls-board-goto (key)
  "Open the Review Board and put point on the row for PR KEY.
Returns non-nil when the row was found."
  (unless (fboundp 'decknix-review-board) (user-error "Review Board is not available"))
  (decknix-review-board)
  (let ((pos (point-min)) found)
    (while (and (not found) pos)
      (let ((row (get-text-property pos 'decknix-review-board-row)))
        (if (and row (member key (plist-get row :prs)))
            (setq found pos)
          (setq pos (next-single-property-change pos 'decknix-review-board-row)))))
    (if found
        (progn (goto-char found) t)
      (message "%s is not on the board" key)
      nil)))

(defun decknix-session-urls--jira-entries ()
  "Return this session's ticket entries."
  (seq-filter (lambda (e) (eq (plist-get e :kind) 'jira))
              (ignore-errors (decknix-session-urls-entries))))

(defun decknix-session-urls-dispatch (action entry)
  "Perform ACTION on session URL ENTRY.

ACTION is one of `browse', `copy', `markdown', `files', `checks',
`board', `compose', `eww', `xwidget' or `jira'.  One entry point so
the transient, embark and the review-session keys cannot drift apart."
  (let ((url (plist-get entry :url)))
    (pcase action
      ('browse (browse-url url) (message "Opened %s" url))
      ('copy (kill-new url) (message "Copied %s" url))
      ('markdown
       (let ((md (format "[%s](%s)" (or (plist-get entry :title) (plist-get entry :label) url) url)))
         (kill-new md) (message "Copied %s" md)))
      ((or 'files 'checks)
       (let ((view (cdr (assoc (symbol-name action) (decknix-session-urls-pr-views entry)))))
         (unless view (user-error "Not a pull request: %s" url))
         (browse-url view) (message "Opened %s" view)))
      ('board
       (let ((key (decknix-session-urls--board-key entry)))
         (unless key (user-error "Not a pull request: %s" url))
         (decknix-session-urls-board-goto key)))
      ('compose
       (unless (fboundp 'decknix--compose-get-or-create) (user-error "Compose is not available"))
       (with-current-buffer (decknix--compose-get-or-create (current-buffer))
         (insert url)))
      ('eww (eww url))
      ('xwidget
       (cond ((fboundp 'decknix--open-url) (let ((decknix--use-xwidget-webkit t)) (decknix--open-url url)))
             ((decknix-session-urls--xwidget-p) (xwidget-webkit-browse-url url))
             (t (user-error "xwidget-webkit is not available in this Emacs"))))
      ('jira
       (let* ((tickets (if (eq (plist-get entry :kind) 'jira)
                           (list entry)
                         (decknix-session-urls--jira-entries)))
              (pick (if (cdr tickets)
                        (decknix-session-urls-read "Ticket: " tickets)
                      (car tickets))))
         (unless pick (user-error "No tickets in this session"))
         (browse-url (plist-get pick :url))
         (message "Opened %s" (plist-get pick :url))))
      (_ (error "Unknown session URL action: %S" action)))))


;; ── transient ────────────────────────────────────────────────────────

(defvar decknix-session-urls--target nil
  "The entry the action menu acts on.")

(defun decknix-session-urls--menu-title ()
  "Heading for the action menu: the target's label and URL."
  (let ((e decknix-session-urls--target))
    (format "%s  %s" (propertize (or (plist-get e :label) "") 'face 'bold)
            (propertize (or (plist-get e :url) "") 'face 'font-lock-comment-face))))

(defun decknix-session-urls--target-pr-p ()
  "Non-nil when the menu's target is a pull request."
  (plist-get decknix-session-urls--target :pr-url))

(defun decknix-session-urls--target-board-p ()
  "Non-nil when the target is a PR and the Review Board is loaded."
  (and (decknix-session-urls--target-pr-p) (fboundp 'decknix-review-board)))

(defun decknix-session-urls--has-jira-p ()
  "Non-nil when the target is a ticket or the session mentions one."
  (or (eq (plist-get decknix-session-urls--target :kind) 'jira)
      (decknix-session-urls--jira-entries)))

(defmacro decknix-session-urls--define-suffix (action doc)
  "Define `decknix-session-url-do-ACTION' running ACTION on the target, with DOC."
  `(defun ,(intern (format "decknix-session-url-do-%s" action)) ()
     ,doc
     (interactive)
     (decknix-session-urls-dispatch ',action decknix-session-urls--target)))

(decknix-session-urls--define-suffix browse "Open the target URL in the browser.")
(decknix-session-urls--define-suffix copy "Copy the target URL.")
(decknix-session-urls--define-suffix markdown "Copy the target as a Markdown link.")
(decknix-session-urls--define-suffix files "Open the target PR's files-changed view.")
(decknix-session-urls--define-suffix checks "Open the target PR's checks view.")
(decknix-session-urls--define-suffix board "Show the target PR's Review Board row.")
(decknix-session-urls--define-suffix compose "Insert the target URL into the compose buffer.")
(decknix-session-urls--define-suffix eww "Show the target URL in eww.")
(decknix-session-urls--define-suffix xwidget "Show the target URL in xwidget-webkit.")
(decknix-session-urls--define-suffix jira "Open the target ticket, or one this session mentions.")

(transient-define-prefix decknix-session-url-menu ()
  "Act on a URL from this session."
  [:description decknix-session-urls--menu-title
   ["Open"
    ("o" "in browser" decknix-session-url-do-browse)
    ("e" "in eww" decknix-session-url-do-eww)
    ("x" "in xwidget" decknix-session-url-do-xwidget :if decknix-session-urls--xwidget-p)]
   ["Copy"
    ("w" "URL" decknix-session-url-do-copy)
    ("m" "as Markdown link" decknix-session-url-do-markdown)
    ("i" "insert into compose" decknix-session-url-do-compose)]
   ["Pull request" :if decknix-session-urls--target-pr-p
    ("f" "files changed" decknix-session-url-do-files)
    ("c" "checks" decknix-session-url-do-checks)
    ("b" "Review Board row" decknix-session-url-do-board :if decknix-session-urls--target-board-p)]
   ["Ticket" :if decknix-session-urls--has-jira-p
    ("j" "open ticket" decknix-session-url-do-jira)]]
  ["" ("q" "Quit" transient-quit-all)])

(defun decknix-session-urls-menu-for (entry)
  "Open the action menu on ENTRY."
  (setq decknix-session-urls--target entry)
  (transient-setup 'decknix-session-url-menu))

;; ── cycling ──────────────────────────────────────────────────────────

(defvar-local decknix-session-urls--current nil
  "Where the last cycle landed: (SHOWN-START URL-START URL-END URL).
SHOWN-START differs from URL-START when the URL is hidden behind a
Markdown link title and point was put on the title instead.")

(defvar-local decknix-session-urls--overlay nil
  "Highlight overlay on the URL the cycle landed on.")

(defun decknix-session-urls--current-at-point ()
  "Return `decknix-session-urls--current' when point is still on it."
  (let ((c decknix-session-urls--current))
    (when (and c (or (= (point) (nth 0 c))
                     (and (>= (point) (nth 1 c)) (< (point) (nth 2 c)))))
      c)))

(defun decknix-session-urls--title-span (url-start)
  "Return (TITLE-START . TITLE-END) of the `[title](' just before URL-START."
  (save-excursion
    (goto-char url-start)
    (when (and (eq (char-before) ?\() (eq (char-before (1- (point))) ?\]))
      (let ((title-end (- (point) 2)))
        (goto-char title-end)
        (when (search-backward "[" (line-beginning-position) t)
          (cons (1+ (point)) title-end))))))

(defun decknix-session-urls--search (dir)
  "Search from point in direction DIR (1 or -1) for a URL.
Returns (URL-START URL-END URL) for the trimmed match, or nil."
  (when (if (> dir 0)
            (re-search-forward decknix-session-urls-url-regexp nil t)
          (re-search-backward decknix-session-urls-url-regexp nil t))
    (let* ((beg (match-beginning 0))
           (url (decknix-session-urls-trim (match-string-no-properties 0))))
      (when (< dir 0)
        ;; A backward search lands on the LAST position the regexp can
        ;; start; walk back to the start of the URL that contains it.
        (save-excursion
          (goto-char beg)
          (when (looking-back "https?://[^][ \t\n\r\"'<>(){}`|\\]*" (line-beginning-position))
            (setq beg (match-beginning 0))
            (goto-char beg)
            (when (looking-at decknix-session-urls-url-regexp)
              (setq url (decknix-session-urls-trim (match-string-no-properties 0)))))))
      (list beg (+ beg (length url)) url))))

(defun decknix-session-urls--start-for (dir)
  "Return where a DIR search should start so it skips the URL at point."
  (let ((c (decknix-session-urls--current-at-point)))
    (cond
     (c (if (> dir 0) (nth 2 c) (min (nth 0 c) (nth 1 c))))
     ((save-excursion
        (skip-chars-backward "^ \t\n\r\"'<>(){}`|[]\\\\")
        (looking-at decknix-session-urls-url-regexp))
      (save-excursion
        (skip-chars-backward "^ \t\n\r\"'<>(){}`|[]\\\\")
        (if (> dir 0) (match-end 0) (point))))
     (t (point)))))

(defun decknix-session-urls--highlight (start end)
  "Highlight START..END as the current URL."
  (if (overlayp decknix-session-urls--overlay)
      (move-overlay decknix-session-urls--overlay start end)
    (setq decknix-session-urls--overlay (make-overlay start end))
    (overlay-put decknix-session-urls--overlay 'face 'decknix-session-url-highlight)
    (overlay-put decknix-session-urls--overlay 'priority 100)))

(defun decknix-session-urls-unhighlight ()
  "Remove the cycle highlight in the current buffer."
  (when (overlayp decknix-session-urls--overlay)
    (delete-overlay decknix-session-urls--overlay)
    (setq decknix-session-urls--overlay nil)))

(defun decknix-session-urls-step (dir)
  "Move point to the next (DIR 1) or previous (DIR -1) URL, wrapping.
Returns the URL, or nil when the buffer has none."
  (let* ((from (decknix-session-urls--start-for dir))
         (hit (save-excursion (goto-char from) (decknix-session-urls--search dir)))
         (wrapped nil))
    (unless hit
      (setq hit (save-excursion
                  (goto-char (if (> dir 0) (point-min) (point-max)))
                  (decknix-session-urls--search dir))
            wrapped t))
    (when hit
      (pcase-let* ((`(,beg ,end ,url) hit)
                   (title (and (invisible-p beg) (decknix-session-urls--title-span beg)))
                   (shown-start (if title (car title) beg))
                   (shown-end (if title (cdr title) end)))
        (goto-char shown-start)
        (setq decknix-session-urls--current (list shown-start beg end url))
        (decknix-session-urls--highlight shown-start shown-end)
        (when (and (get-buffer-window) (not (pos-visible-in-window-p)))
          (recenter))
        (let ((e (decknix-session-urls-classify url)))
          (message "%s%s  %s" (if wrapped "[wrapped] " "")
                   (plist-get e :label) url))
        url))))

(defvar decknix-session-urls-cycle-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n") #'decknix-session-url-next)
    (define-key map (kbd ">") #'decknix-session-url-next)
    (define-key map (kbd "p") #'decknix-session-url-previous)
    (define-key map (kbd "<") #'decknix-session-url-previous)
    (define-key map (kbd "RET") #'decknix-session-url-open-current)
    (define-key map (kbd "o") #'decknix-session-url-open-current)
    (define-key map (kbd "w") #'decknix-session-url-copy-current)
    (define-key map (kbd "m") #'decknix-session-url-markdown-current)
    (define-key map (kbd "a") #'decknix-session-url-act)
    map)
  "Keys live straight after a cycling command; any other key ends the cycle.")

(defun decknix-session-urls--arm-cycle-map ()
  "Keep `decknix-session-urls-cycle-map' live until a key outside it."
  (let ((buf (current-buffer)))
    (set-transient-map decknix-session-urls-cycle-map t
                       (lambda ()
                         (when (buffer-live-p buf)
                           (with-current-buffer buf (decknix-session-urls-unhighlight)))))))

(defun decknix-session-url-next ()
  "Move to the next URL in this buffer and highlight it."
  (interactive)
  (if (decknix-session-urls-step 1)
      (decknix-session-urls--arm-cycle-map)
    (user-error "No URLs in this buffer")))

(defun decknix-session-url-previous ()
  "Move to the previous URL in this buffer and highlight it.
From the prompt this is the most recent URL, the usual first press."
  (interactive)
  (if (decknix-session-urls-step -1)
      (decknix-session-urls--arm-cycle-map)
    (user-error "No URLs in this buffer")))

(defun decknix-session-urls-at-point ()
  "Return the URL at point: the cycle's landing spot, else one under point."
  (or (nth 3 (decknix-session-urls--current-at-point))
      (decknix-session-urls-url-around
       (buffer-substring-no-properties (line-beginning-position) (line-end-position))
       (- (point) (line-beginning-position)))))

(defun decknix-session-urls--current-entry ()
  "Return the entry for the URL at point, or signal."
  (let ((url (decknix-session-urls-at-point)))
    (unless url (user-error "No URL at point"))
    (decknix-session-urls-entry-for url)))

(defun decknix-session-url-open-current ()
  "Open the URL at point in the browser."
  (interactive)
  (decknix-session-urls-dispatch 'browse (decknix-session-urls--current-entry)))

(defun decknix-session-url-copy-current ()
  "Copy the URL at point."
  (interactive)
  (decknix-session-urls-dispatch 'copy (decknix-session-urls--current-entry)))

(defun decknix-session-url-markdown-current ()
  "Copy the URL at point as a Markdown link."
  (interactive)
  (decknix-session-urls-dispatch 'markdown (decknix-session-urls--current-entry)))

;; ── session commands ─────────────────────────────────────────────────

(defun decknix-session-url-open (&optional act)
  "Pick a URL this session is handling and open it in the browser.
With prefix ACT, open the action menu on it instead."
  (interactive "P")
  (let ((entry (decknix-session-urls-read "Open URL: ")))
    (if act
        (decknix-session-urls-menu-for entry)
      (decknix-session-urls-dispatch 'browse entry))))

(defun decknix-session-url-act ()
  "Act on the URL at point, or on one picked from this session."
  (interactive)
  (let ((url (decknix-session-urls-at-point)))
    (decknix-session-urls-menu-for
     (if url (decknix-session-urls-entry-for url)
       (decknix-session-urls-read "Act on URL: ")))))

(defun decknix-session-urls-bind-session-keys (map)
  "Bind the session-URL commands into MAP, a buffer's `C-c s' keymap.
`O', `U', `<' and `>' are free in both the buffer-local and the global
`C-c s' maps; `o' is not (it toggles the requests order globally)."
  (define-key map (kbd "O") #'decknix-session-url-open)
  (define-key map (kbd "U") #'decknix-session-url-act)
  (define-key map (kbd "<") #'decknix-session-url-previous)
  (define-key map (kbd ">") #'decknix-session-url-next)
  map)

;; ── embark ───────────────────────────────────────────────────────────

(defun decknix-session-url--embark (action url)
  "Run ACTION on URL for embark."
  (decknix-session-urls-dispatch action (decknix-session-urls-entry-for url)))

(defun decknix-session-url-embark-files (url)
  "Open URL's PR files-changed view."
  (interactive "sURL: ")
  (decknix-session-url--embark 'files url))

(defun decknix-session-url-embark-checks (url)
  "Open URL's PR checks view."
  (interactive "sURL: ")
  (decknix-session-url--embark 'checks url))

(defun decknix-session-url-embark-board (url)
  "Show URL's PR on the Review Board."
  (interactive "sURL: ")
  (decknix-session-url--embark 'board url))

(defun decknix-session-url-embark-markdown (url)
  "Copy URL as a Markdown link."
  (interactive "sURL: ")
  (decknix-session-url--embark 'markdown url))

(defun decknix-session-url-embark-compose (url)
  "Insert URL into the compose buffer."
  (interactive "sURL: ")
  (decknix-session-url--embark 'compose url))

(defvar decknix-session-url-embark-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "f") #'decknix-session-url-embark-files)
    (define-key map (kbd "c") #'decknix-session-url-embark-checks)
    (define-key map (kbd "B") #'decknix-session-url-embark-board)
    (define-key map (kbd "m") #'decknix-session-url-embark-markdown)
    (define-key map (kbd "i") #'decknix-session-url-embark-compose)
    map)
  "Embark actions on a session URL; embark's URL actions are its parent.")

(defun decknix-session-urls-embark-setup ()
  "Register the session-URL completion category with embark, once loaded."
  (with-eval-after-load 'embark
    (when (boundp 'embark-url-map)
      (set-keymap-parent decknix-session-url-embark-map embark-url-map))
    (add-to-list 'embark-keymap-alist
                 '(decknix-session-url . decknix-session-url-embark-map))))

;; ── review-session mode ──────────────────────────────────────────────

(defcustom decknix-review-session-auto-enable t
  "Whether review sessions switch on `decknix-review-session-mode' by themselves."
  :type 'boolean
  :group 'decknix-session-urls)

(defcustom decknix-review-session-mode-line-hint t
  "Whether the mode-line lighter spells out the main keys, not just the PR."
  :type 'boolean
  :group 'decknix-session-urls)

(defvar-local decknix-review-session--lighter " Review"
  "Mode-line lighter for `decknix-review-session-mode' in this buffer.")
(put 'decknix-review-session--lighter 'risky-local-variable t)

(defconst decknix-review-session-letters
  '((?o . decknix-review-session-open-pr)
    (?f . decknix-review-session-files)
    (?k . decknix-review-session-checks)
    (?b . decknix-review-session-board)
    (?w . decknix-review-session-copy-pr)
    (?y . decknix-review-session-reply)
    (?1 . decknix-review-session-reply) (?2 . decknix-review-session-reply)
    (?3 . decknix-review-session-reply) (?4 . decknix-review-session-reply)
    (?5 . decknix-review-session-reply) (?6 . decknix-review-session-reply)
    (?7 . decknix-review-session-reply) (?8 . decknix-review-session-reply)
    (?9 . decknix-review-session-reply)
    (?< . decknix-session-url-previous)
    (?> . decknix-session-url-next)
    (?u . decknix-session-url-open)
    (?a . decknix-session-url-act)
    (?? . decknix-review-session-menu))
  "Transcript-only single-key commands of `decknix-review-session-mode'.")

(declare-function shell-maker-point-at-last-prompt-p "shell-maker")

(defun decknix-review-session--typing-p ()
  "Non-nil when point is in the input area, where letters must insert."
  (let ((proc (get-buffer-process (current-buffer))))
    (if proc
        (>= (point) (marker-position (process-mark proc)))
      (and (fboundp 'shell-maker-point-at-last-prompt-p)
           (shell-maker-point-at-last-prompt-p)))))

(defun decknix-review-session-key ()
  "Run the review key just typed, or insert it when typing a prompt."
  (interactive)
  (let ((cmd (alist-get last-command-event decknix-review-session-letters)))
    (if (or (null cmd) (decknix-review-session--typing-p))
        (call-interactively #'self-insert-command)
      (setq this-command cmd)
      (call-interactively cmd))))

(defun decknix-review-session--pr-entry ()
  "Return the entry for the PR this session reviews; pick when several."
  (let* ((entries (decknix-session-urls-entries))
         (prs (or (seq-filter (lambda (e) (eq (plist-get e :source) 'reviewing)) entries)
                  (seq-filter (lambda (e) (and (memq (plist-get e :source) '(linked created))
                                               (plist-get e :pr-url)))
                              entries))))
    (cond ((null prs) (user-error "No PR recorded for this session"))
          ((cdr prs) (decknix-session-urls-read "PR: " prs))
          (t (car prs)))))

(defun decknix-review-session-open-pr ()
  "Open the PR this session reviews in the browser."
  (interactive)
  (decknix-session-urls-dispatch 'browse (decknix-review-session--pr-entry)))

(defun decknix-review-session-files ()
  "Open the reviewed PR's files-changed view."
  (interactive)
  (decknix-session-urls-dispatch 'files (decknix-review-session--pr-entry)))

(defun decknix-review-session-checks ()
  "Open the reviewed PR's checks view."
  (interactive)
  (decknix-session-urls-dispatch 'checks (decknix-review-session--pr-entry)))

(defun decknix-review-session-board ()
  "Show the reviewed PR's row on the Review Board."
  (interactive)
  (decknix-session-urls-dispatch 'board (decknix-review-session--pr-entry)))

(defun decknix-review-session-copy-pr ()
  "Copy the reviewed PR's URL."
  (interactive)
  (decknix-session-urls-dispatch 'copy (decknix-review-session--pr-entry)))

(defun decknix-review-session-reply (&optional key)
  "Answer this session's question like the Review Board's `y' / `1'-`9'.
KEY is `yes' or a digit; by default it comes from the key just typed, or
is read when the command was reached through a chord.  Always confirms
first (see `decknix-agent-turn-quick-reply')."
  (interactive)
  (unless (fboundp 'decknix-agent-turn-quick-reply)
    (user-error "Quick reply is not available"))
  (let ((key (or key
                 (decknix-agent-turn-reply-key last-command-event)
                 (decknix-agent-turn-reply-key
                  (read-key "Reply: y (yes) or 1-9 (option): ")))))
    (unless key (user-error "Not a reply key"))
    (decknix-agent-turn-quick-reply (current-buffer) key)))

(transient-define-prefix decknix-review-session-menu ()
  "Review-session keys: the PR, its views, the board, replies and URLs."
  [:description decknix-review-session--menu-title
   ["Pull request"
    ("o" "open" decknix-review-session-open-pr)
    ("f" "files changed" decknix-review-session-files)
    ("k" "checks" decknix-review-session-checks)
    ("b" "Review Board row" decknix-review-session-board)
    ("w" "copy URL" decknix-review-session-copy-pr)]
   ["Answer (asks first)"
    ("y" "yes / option…" decknix-review-session-reply)]
   ["URLs in this session"
    ("u" "pick and open" decknix-session-url-open)
    ("a" "act on one" decknix-session-url-act)
    ("<" "previous" decknix-session-url-previous)
    (">" "next" decknix-session-url-next)]]
  ["Chords work anywhere: C-c C-j open  C-c C-f files  C-c C-k checks  C-c C-b board  C-c C-y copy  C-c C-q reply.  Letters act only in the transcript."
   ("q" "Quit" transient-quit-all)])

(defun decknix-review-session--menu-title ()
  "Heading for the review-session menu."
  (format "Review %s" (string-join (decknix-session-urls--review-keys) ", ")))

(defvar decknix-review-session-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-j") #'decknix-review-session-open-pr)
    (define-key map (kbd "C-c C-f") #'decknix-review-session-files)
    (define-key map (kbd "C-c C-k") #'decknix-review-session-checks)
    (define-key map (kbd "C-c C-b") #'decknix-review-session-board)
    (define-key map (kbd "C-c C-y") #'decknix-review-session-copy-pr)
    (define-key map (kbd "C-c C-q") #'decknix-review-session-reply)
    (dolist (cell decknix-review-session-letters)
      (define-key map (vector (car cell)) #'decknix-review-session-key))
    map)
  "Keymap for `decknix-review-session-mode'.

Chords are `C-c C-<key>' combinations comint, agent-shell and the
decknix agent-shell bindings leave free (`C-c C-p' is comint's previous
prompt, hence `C-c C-j' to open).  Letters go through
`decknix-review-session-key', which inserts them at the prompt.")

(defun decknix-review-session--update-lighter ()
  "Recompute this buffer's lighter from its review keys."
  (let ((keys (string-join (decknix-session-urls--review-keys) " ")))
    (setq decknix-review-session--lighter
          (propertize
           (if decknix-review-session-mode-line-hint
               (format " [review %s  C-c C-j open  C-c s </> urls  ? help]" keys)
             (format " Review %s" keys))
           'help-echo
           "C-c C-j open PR  C-c C-f files  C-c C-k checks  C-c C-b board  C-c C-y copy  C-c C-q reply
In the transcript: o f k b w, y / 1-9 reply, < > cycle URLs, u pick, a act, ? menu"))))

;;;###autoload
(define-minor-mode decknix-review-session-mode
  "Keyboard access to the PR a review session is on, and its URLs.

\\{decknix-review-session-mode-map}"
  :lighter (:eval decknix-review-session--lighter)
  :keymap decknix-review-session-mode-map
  (if decknix-review-session-mode
      (decknix-review-session--update-lighter)
    (decknix-session-urls-unhighlight)))

(defun decknix-review-session-maybe-enable (&optional buffer)
  "Switch on `decknix-review-session-mode' in BUFFER when it is a review.
A review is a session with recorded review coordinates (or, failing
that, a review-convention buffer name).  Cheap: the identity read is
cached, so this is safe on every turn boundary."
  (let ((buffer (or buffer (current-buffer))))
    (when (and decknix-review-session-auto-enable (buffer-live-p buffer))
      (with-current-buffer buffer
        (when (and (derived-mode-p 'agent-shell-mode)
                   (decknix-session-urls--review-keys))
          (if decknix-review-session-mode
              (decknix-review-session--update-lighter)
            (decknix-review-session-mode 1)))))))

(defun decknix-review-session-on-mode-entry ()
  "For `agent-shell-mode-hook': check now, and again once metadata settles.
The conversation key arrives asynchronously after mode entry, so the
first check can be too early for a recorded review."
  (decknix-review-session-maybe-enable)
  (run-at-time 3.0 nil #'decknix-review-session-maybe-enable (current-buffer)))

(provide 'decknix-session-urls-ui)
;;; decknix-session-urls-ui.el ends here
