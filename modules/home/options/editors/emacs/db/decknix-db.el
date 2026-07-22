;;; decknix-db.el --- Magit-style DB connect over jumpbox tunnels -*- lexical-binding: t -*-

;; Author: decknix
;; Keywords: decknix, sql, tools

;;; Commentary:
;;
;; A `transient' menu to connect to decknix-managed databases reached through
;; IAP jumpbox SSH tunnels (see the `*-listing-perf-*' / `*-monolith-*' host
;; aliases in ~/.ssh/config).
;;
;; Design:
;;   - Defaults to the LEAST-privileged role of a service.
;;   - More privileged roles (and breakglass-gated environments) are an
;;     explicit, deliberate selection.  This file NEVER requests a PAM grant on
;;     your behalf — for a breakglass env it only asks you to confirm a grant is
;;     already active, per the Breakglass runbook.
;;
;; Populate `decknix-db-services' with your targets (NurtureCloud definitions
;; live in decknix-config, not here).  The SQL path needs `psql' (postgresql)
;; on PATH; the pgcli path needs `pgcli' + vterm.

;;; Code:

(require 'transient)
(require 'sql)
(require 'seq)
(require 'subr-x)

(declare-function vterm "ext:vterm" (&optional buffer-name))
(defvar vterm-shell)

(defgroup decknix-db nil
  "Jumpbox-tunnelled database connections."
  :group 'tools)

(defvar decknix-db-services nil
  "List of database service plists.
Each entry:
  (:name STRING          ; label shown in the menu
   :dbname STRING
   :host STRING          ; local tunnel endpoint, usually \"127.0.0.1\"
   :port INTEGER
   :project STRING       ; GCP project for `gcloud secrets'
   :read-tunnel STRING   ; ssh host alias holding the read LocalForward
   :write-tunnel STRING  ; ssh host alias for the write LocalForward (optional)
   :breakglass BOOL      ; non-nil if the env needs a PAM grant first
   :roles ((ROLE . (:secret SECRET-NAME :write BOOL)) ...))  ; least priv FIRST")

(defvar decknix-db--service nil "Currently selected service plist.")
(defvar decknix-db--role nil "Currently selected role name (string).")
(defvar decknix-db--tunnels (make-hash-table :test 'equal)
  "Map of ssh-host-alias -> tunnel process.")

;; -- pure helpers --------------------------------------------------

(defun decknix-db--service-by-name (name)
  (seq-find (lambda (s) (equal (plist-get s :name) name)) decknix-db-services))

(defun decknix-db--role-plist (service role)
  (cdr (assoc role (plist-get service :roles))))

(defun decknix-db--default-role (service)
  (car (car (plist-get service :roles))))

(defun decknix-db--tunnel-for (service role)
  "Return the ssh host alias for ROLE of SERVICE.
Write roles use `:write-tunnel' when defined, else the read tunnel."
  (let ((rp (decknix-db--role-plist service role)))
    (or (and (plist-get rp :write) (plist-get service :write-tunnel))
        (plist-get service :read-tunnel))))

(defun decknix-db--psql-command (service role)
  "Return the psql command string for ROLE of SERVICE (password omitted)."
  (format "psql \"host=%s port=%s dbname=%s user=%s sslmode=disable\""
          (plist-get service :host) (plist-get service :port)
          (plist-get service :dbname) role))

;; -- tunnel lifecycle ----------------------------------------------

(defun decknix-db--tunnel-live-p (host)
  (let ((p (and host (gethash host decknix-db--tunnels))))
    (and p (process-live-p p))))

(defun decknix-db--tunnel-start (host)
  (unless (decknix-db--tunnel-live-p host)
    (let ((p (start-process (format "decknix-db-tunnel:%s" host)
                            (format "*decknix-db-tunnel:%s*" host)
                            "ssh" "-N" host)))
      (puthash host p decknix-db--tunnels)
      (message "decknix-db: opening tunnel %s ..." host)))
  (gethash host decknix-db--tunnels))

(defun decknix-db--tunnel-stop (host)
  (let ((p (gethash host decknix-db--tunnels)))
    (when (and p (process-live-p p)) (delete-process p))
    (remhash host decknix-db--tunnels)
    (message "decknix-db: closed tunnel %s" host)))

(defun decknix-db--ensure-tunnel (service role)
  (decknix-db--tunnel-start (decknix-db--tunnel-for service role)))

;; -- credentials ---------------------------------------------------

(defun decknix-db--password (service secret)
  "Fetch SECRET's latest value from Secret Manager for SERVICE's project.
Runs `gcloud secrets versions access' synchronously (your action)."
  (let* ((project (plist-get service :project))
         (out (string-trim
               (shell-command-to-string
                (format "gcloud secrets versions access latest --secret=%s --project=%s 2>/dev/null"
                        (shell-quote-argument secret)
                        (shell-quote-argument project))))))
    (when (string-empty-p out)
      (user-error "Could not fetch secret %s (project %s) — auth expired, or a breakglass grant is needed"
                  secret project))
    out))

(defun decknix-db--preflight (service role)
  "Guard breakglass envs; return the role's secret plist or error."
  (let ((rp (decknix-db--role-plist service role)))
    (unless (and service role rp)
      (user-error "Pick a service and role first (s / r)"))
    (when (plist-get service :breakglass)
      (unless (yes-or-no-p
               (format "%s is breakglass-gated — is your PAM grant active? "
                       (plist-get service :name)))
        (user-error "Aborted — request the grant in the GCP console first")))
    rp))

;; -- connect actions -----------------------------------------------

(defun decknix-db-connect-sql ()
  "Open a `sql-postgres' SQLi buffer for the selected service/role."
  (interactive)
  (let* ((svc decknix-db--service) (role decknix-db--role)
         (rp (decknix-db--preflight svc role)))
    (decknix-db--ensure-tunnel svc role)
    (let* ((pw (decknix-db--password svc (plist-get rp :secret)))
           (process-environment (cons (concat "PGPASSWORD=" pw) process-environment))
           (sql-connection-alist
            `((decknix-db (sql-product 'postgres)
                          (sql-user ,role)
                          (sql-password ,pw)
                          (sql-server ,(plist-get svc :host))
                          (sql-port ,(plist-get svc :port))
                          (sql-database ,(plist-get svc :dbname))))))
      (sql-connect 'decknix-db (format "%s [%s]" (plist-get svc :name) role)))))

(defun decknix-db-connect-pgcli ()
  "Open pgcli in a vterm for the selected service/role."
  (interactive)
  (let* ((svc decknix-db--service) (role decknix-db--role)
         (rp (decknix-db--preflight svc role)))
    (unless (fboundp 'vterm)
      (user-error "vterm not available; use `c' (psql) or `w' (copy the command)"))
    (decknix-db--ensure-tunnel svc role)
    (let* ((pw (decknix-db--password svc (plist-get rp :secret)))
           (process-environment (cons (concat "PGPASSWORD=" pw) process-environment))
           (vterm-shell (format "pgcli -h %s -p %s -U %s %s"
                                (plist-get svc :host) (plist-get svc :port)
                                role (plist-get svc :dbname))))
      (vterm (format "*pgcli %s [%s]*" (plist-get svc :name) role)))))

(defun decknix-db-copy-command ()
  "Copy the psql command (password omitted) to the kill ring."
  (interactive)
  (unless (and decknix-db--service decknix-db--role)
    (user-error "Pick a service and role first (s / r)"))
  (let ((cmd (decknix-db--psql-command decknix-db--service decknix-db--role)))
    (kill-new cmd)
    (message "Copied: %s" cmd)))

;; -- selection (transient suffixes) --------------------------------

(defun decknix-db-set-service (name)
  "Select a service by NAME and reset the role to its least-privileged."
  (interactive
   (list (completing-read "Service: "
                          (mapcar (lambda (s) (plist-get s :name)) decknix-db-services)
                          nil t)))
  (setq decknix-db--service (decknix-db--service-by-name name)
        decknix-db--role (decknix-db--default-role decknix-db--service)))

(defun decknix-db-set-role (role)
  "Select ROLE within the current service."
  (interactive
   (list (completing-read "Role: "
                          (mapcar #'car (plist-get decknix-db--service :roles))
                          nil t)))
  (setq decknix-db--role role))

(defun decknix-db-toggle-tunnel ()
  "Start or stop the tunnel for the current service/role."
  (interactive)
  (let ((host (decknix-db--tunnel-for decknix-db--service decknix-db--role)))
    (if (decknix-db--tunnel-live-p host)
        (decknix-db--tunnel-stop host)
      (decknix-db--tunnel-start host))))

;; -- transient -----------------------------------------------------

(defun decknix-db--heading ()
  (let* ((svc decknix-db--service) (role decknix-db--role)
         (host (and svc role (decknix-db--tunnel-for svc role))))
    (if (null svc)
        "No service selected — press s"
      (format "%s  ·  role %s%s  ·  tunnel %s [%s]"
              (plist-get svc :name) (or role "?")
              (if (plist-get svc :breakglass) " (breakglass)" "")
              (or host "?")
              (if (decknix-db--tunnel-live-p host) "UP" "down")))))

(transient-define-prefix decknix-db ()
  "Connect to a decknix-managed database over its jumpbox tunnel."
  [:description decknix-db--heading
   ["Target"
    ("s" "service" decknix-db-set-service :transient t)
    ("r" "role"    decknix-db-set-role    :transient t)]
   ["Tunnel"
    ("t" "toggle tunnel" decknix-db-toggle-tunnel :transient t)]
   ["Connect"
    ("c" "psql (SQLi)"    decknix-db-connect-sql)
    ("p" "pgcli (vterm)"  decknix-db-connect-pgcli)
    ("w" "copy psql cmd"  decknix-db-copy-command :transient t)]]
  [("q" "quit" transient-quit-one)]
  (interactive)
  (unless decknix-db--service
    (setq decknix-db--service (car decknix-db-services)
          decknix-db--role (and decknix-db--service
                                (decknix-db--default-role decknix-db--service))))
  (transient-setup 'decknix-db))

(provide 'decknix-db)
;;; decknix-db.el ends here
