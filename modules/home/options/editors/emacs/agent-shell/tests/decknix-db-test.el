;;; decknix-db-test.el --- Tests for decknix-db pure helpers -*- lexical-binding: t -*-

;; Author: decknix
;; Package-Requires: ((emacs "29.1") (decknix-db "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;; ERT tests for the pure service/role/tunnel helpers in `decknix-db'.
;; The interactive connect actions (psql/pgcli/tunnel) are I/O and not
;; exercised here.

;;; Code:

(require 'ert)
(require 'decknix-db)

(defconst decknix-db-test--service
  '(:name "svc" :dbname "db" :host "127.0.0.1" :port 5432 :project "proj"
    :read-tunnel "svc-read" :write-tunnel "svc-write"
    :roles (("ro" . (:secret "ro-secret"))
            ("rw" . (:secret "rw-secret" :write t))))
  "A synthetic service fixture.")

(ert-deftest decknix-db--default-role-is-first ()
  "The default role is the first (least-privileged) in :roles."
  (should (equal (decknix-db--default-role decknix-db-test--service) "ro")))

(ert-deftest decknix-db--role-plist-lookup ()
  (should (equal (decknix-db--role-plist decknix-db-test--service "rw")
                 '(:secret "rw-secret" :write t)))
  (should (equal (plist-get (decknix-db--role-plist decknix-db-test--service "ro") :secret)
                 "ro-secret")))

(ert-deftest decknix-db--tunnel-routes-by-write-flag ()
  "Read roles use the read tunnel; write roles use the write tunnel."
  (should (equal (decknix-db--tunnel-for decknix-db-test--service "ro") "svc-read"))
  (should (equal (decknix-db--tunnel-for decknix-db-test--service "rw") "svc-write")))

(ert-deftest decknix-db--tunnel-write-falls-back-to-read ()
  "A write role with no :write-tunnel falls back to the read tunnel."
  (let ((svc (append '(:name "s" :read-tunnel "only-read")
                     '(:roles (("rw" . (:secret "x" :write t)))))))
    (should (equal (decknix-db--tunnel-for svc "rw") "only-read"))))

(ert-deftest decknix-db--psql-command-shape ()
  (should (equal (decknix-db--psql-command decknix-db-test--service "ro")
                 "psql \"host=127.0.0.1 port=5432 dbname=db user=ro sslmode=disable\"")))

(ert-deftest decknix-db--service-by-name ()
  (let ((decknix-db-services (list decknix-db-test--service)))
    (should (equal (plist-get (decknix-db--service-by-name "svc") :dbname) "db"))
    (should (null (decknix-db--service-by-name "nope")))))

(provide 'decknix-db-test)
;;; decknix-db-test.el ends here
