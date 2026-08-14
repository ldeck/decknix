;;; decknix-agent-archived.el --- Browse & restore archived agent sessions -*- lexical-binding: t; -*-

;; Bridges the `decknix session' archive lifecycle into Emacs.  The decknix CLI
;; keeps stale sessions compressed in an archive store with a lightweight
;; `index.jsonl' (first message, tags, workspace — no decompression needed to
;; browse).  This module is a thin, well-tested `completing-read' front end over
;; that index: pick an archived session and restore it back to its provider
;; directory, from where the normal saved-session picker can resume it (when its
;; agent is the one you are currently switched to).
;;
;; All heavy lifting stays in the CLI:
;;   decknix session list --archived --json     -> the browse list
;;   decknix session restore <id> --agent A --json -> decompress + return path
;;
;; The pure helpers (`--parse', `--first-line', `--candidate-label', `--sort')
;; carry the logic and are covered by ERT; the interactive command is glue.

;;; Code:

(require 'json)
(require 'subr-x)

(defgroup decknix-agent-archived nil
  "Browse and restore archived agent sessions."
  :group 'tools)

(defcustom decknix-agent-archived-executable "decknix"
  "The decknix CLI used to list and restore archived sessions."
  :type 'string
  :group 'decknix-agent-archived)

;;; --- pure helpers (unit-tested) -----------------------------------------

(defun decknix-agent-archived--first-line (msg &optional width)
  "First non-blank line of MSG, trimmed and truncated to WIDTH (default 80).
Truncation appends a single-character ellipsis."
  (let* ((width (or width 80))
         (line (catch 'found
                 (dolist (l (split-string (or msg "") "\n"))
                   (let ((s (string-trim l)))
                     (unless (string-empty-p s) (throw 'found s))))
                 "")))
    (if (> (length line) width)
        (concat (substring line 0 (max 0 (1- width))) "…")
      line)))

(defun decknix-agent-archived--workspace-name (ws)
  "Short display name for workspace path WS (its final path segment)."
  (if (or (null ws) (string-empty-p ws))
      ""
    (let ((parts (split-string (directory-file-name ws) "/" t)))
      (or (car (last parts)) ""))))

(defun decknix-agent-archived--parse (json-string)
  "Parse JSON-STRING from `decknix session list --archived --json'.
Return a list of alists keyed: id agent first-message tags workspace
last-modified.  A malformed payload yields nil rather than signalling."
  (let ((data (ignore-errors
                (json-parse-string json-string
                                   :object-type 'alist
                                   :array-type 'list
                                   :null-object nil
                                   :false-object nil))))
    (mapcar
     (lambda (o)
       (list (cons 'id (alist-get 'id o))
             (cons 'agent (alist-get 'agent o))
             (cons 'first-message (alist-get 'firstMessage o))
             (cons 'tags (alist-get 'tags o))
             (cons 'workspace (alist-get 'workspace o))
             (cons 'last-modified (alist-get 'lastModified o))))
     data)))

(defun decknix-agent-archived--parse-restore (json-string)
  "Parse the single-object JSON from `session restore --json' into an alist
keyed: id provider restored-path workspace.  Malformed input yields nil."
  (let ((o (ignore-errors
             (json-parse-string json-string
                                 :object-type 'alist
                                 :array-type 'list
                                 :null-object nil
                                 :false-object nil))))
    (when o
      (list (cons 'id (alist-get 'id o))
            (cons 'provider (alist-get 'provider o))
            (cons 'restored-path (alist-get 'restoredPath o))
            (cons 'workspace (alist-get 'workspace o))))))

(defun decknix-agent-archived--candidate-label (entry)
  "A single-line `completing-read' label for ENTRY."
  (let* ((agent (or (alist-get 'agent entry) "?"))
         (tags (alist-get 'tags entry))
         (ws (decknix-agent-archived--workspace-name (alist-get 'workspace entry)))
         (msg (decknix-agent-archived--first-line (alist-get 'first-message entry) 70)))
    (format "%-8s %s%s%s"
            (concat "[" agent "]")
            msg
            (if (and tags (> (length tags) 0))
                (concat "  #" (string-join tags ",")) "")
            (if (string-empty-p ws) "" (concat "  " ws)))))

(defun decknix-agent-archived--sort (entries)
  "ENTRIES sorted by last-modified descending (most recent first).
Sorts a copy; ENTRIES is not mutated."
  (sort (copy-sequence entries)
        (lambda (a b)
          (string> (or (alist-get 'last-modified a) "")
                   (or (alist-get 'last-modified b) "")))))

;;; --- process glue (interactive) -----------------------------------------

(defun decknix-agent-archived--list ()
  "Shell out to list archived sessions; return parsed + sorted entries."
  (with-temp-buffer
    (let ((code (call-process decknix-agent-archived-executable nil t nil
                              "session" "list" "--archived" "--json")))
      (unless (zerop code)
        (error "`decknix session list --archived' failed (exit %s)" code))
      (decknix-agent-archived--sort
       (decknix-agent-archived--parse (buffer-string))))))

(defun decknix-agent-archived--restore (id agent)
  "Restore archived session ID for AGENT via the CLI; return the result alist."
  (with-temp-buffer
    (let ((code (call-process decknix-agent-archived-executable nil t nil
                              "session" "restore" id "--agent" agent "--json")))
      (unless (zerop code)
        (error "`decknix session restore' failed (exit %s): %s"
               code (string-trim (buffer-string))))
      (decknix-agent-archived--parse-restore (buffer-string)))))

;;;###autoload
(defun decknix-agent-archived-open ()
  "Pick an archived agent session and restore it to its provider directory.
The restored session then appears in the normal saved-session picker for
resume (when its agent matches the one you are currently switched to)."
  (interactive)
  (let ((entries (decknix-agent-archived--list)))
    (unless entries (user-error "No archived sessions"))
    (let* ((labels (mapcar (lambda (e)
                             (cons (decknix-agent-archived--candidate-label e) e))
                           entries))
           (choice (completing-read "Restore archived session: " labels nil t))
           (entry (cdr (assoc choice labels))))
      (unless entry (user-error "No selection"))
      (let* ((id (alist-get 'id entry))
             (agent (alist-get 'agent entry))
             (res (decknix-agent-archived--restore id agent))
             (path (alist-get 'restored-path res)))
        (message "Restored [%s] %s%s — resume from the saved-session picker"
                 agent
                 (substring id 0 (min 8 (length id)))
                 (if path (format " -> %s" path) ""))))))

(provide 'decknix-agent-archived)
;;; decknix-agent-archived.el ends here
