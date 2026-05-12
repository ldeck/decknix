;;; decknix-agent-prompt-search-cache-test.el --- Tests for prompt search cache -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Characterisation tests for `decknix-agent-prompt-search-cache'
;; (PR B.72).  Stubs the carved jq command + parser so the cache
;; layer is exercised without touching the user's session
;; directory, and uses `cl-letf' to substitute
;; `shell-command-to-string' / `start-process-shell-command'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ring)
(require 'decknix-agent-prompt-search-cache)

(defvar decknix--compose-target-buffer nil)

(defmacro decknix-test--with-fresh-cache (&rest body)
  "Reset cache state then run BODY."
  `(let ((decknix--prompt-search-cache nil)
         (decknix--prompt-search-cache-time 0)
         (decknix--prompt-search-refresh-proc nil)
         (decknix--compose-target-buffer nil))
     (cl-letf (((symbol-function 'decknix--prompt-search-jq-cmd)
                (lambda () "echo ignored"))
               ((symbol-function 'decknix--prompt-search-parse)
                (lambda (_raw) '("p1" "p2" "p3"))))
       ,@body)))

(ert-deftest decknix-prompt-search-cache--refresh-sync-populates ()
  "Sync refresh stores parser output and stamps the time."
  (decknix-test--with-fresh-cache
   (cl-letf (((symbol-function 'shell-command-to-string)
              (lambda (_cmd) "{}")))
     (let ((result (decknix--prompt-search-refresh-sync)))
       (should (equal result '("p1" "p2" "p3")))
       (should (equal decknix--prompt-search-cache '("p1" "p2" "p3")))
       (should (> decknix--prompt-search-cache-time 0))))))

(ert-deftest decknix-prompt-search-cache--get-bootstraps-when-empty ()
  "First `-get' triggers a sync refresh because cache is unset."
  (decknix-test--with-fresh-cache
   (cl-letf (((symbol-function 'shell-command-to-string)
              (lambda (_cmd) "{}")))
     (let ((result (decknix--prompt-search-get)))
       (should (member "p1" result))
       (should (> decknix--prompt-search-cache-time 0))))))

(ert-deftest decknix-prompt-search-cache--get-skips-refresh-when-warm ()
  "When cache is warm and time is fresh, no shell call is made."
  (decknix-test--with-fresh-cache
   (setq decknix--prompt-search-cache '("warm")
         decknix--prompt-search-cache-time (float-time))
   (let ((shell-called nil))
     (cl-letf (((symbol-function 'shell-command-to-string)
                (lambda (_cmd) (setq shell-called t) "{}"))
               ((symbol-function 'start-process-shell-command)
                (lambda (&rest _) (setq shell-called t) nil)))
       (let ((result (decknix--prompt-search-get)))
         (should (equal result '("warm")))
         (should-not shell-called))))))

(ert-deftest decknix-prompt-search-cache--get-spawns-async-when-stale ()
  "Stale cache triggers async refresh but still returns current data."
  (decknix-test--with-fresh-cache
   (setq decknix--prompt-search-cache '("old")
         decknix--prompt-search-cache-time
         (- (float-time) (1+ decknix--prompt-search-cache-ttl)))
   (let ((spawn-args nil))
     (cl-letf (((symbol-function 'start-process-shell-command)
                (lambda (&rest args)
                  (setq spawn-args args)
                  ;; Return a fake process object the impl can sentinel
                  (let ((b (generate-new-buffer " *fake*")))
                    (start-process "fake" b "true"))))
               ((symbol-function 'set-process-sentinel)
                (lambda (&rest _) nil)))
       (let ((result (decknix--prompt-search-get)))
         (should spawn-args)
         (should (equal result '("old"))))))))

(ert-deftest decknix-prompt-search-cache--get-merges-ring-and-cache ()
  "Ring entries are prepended; cache entries follow; duplicates drop."
  (decknix-test--with-fresh-cache
   (setq decknix--prompt-search-cache '("cached1" "shared")
         decknix--prompt-search-cache-time (float-time))
   (let ((target-buf (generate-new-buffer " *fake-target*")))
     (with-current-buffer target-buf
       (setq-local comint-input-ring (make-ring 5))
       (ring-insert comint-input-ring "shared")  ; dup with cache
       (ring-insert comint-input-ring "ring-only")
       ;; Most recently inserted is at index 0 -- "ring-only" then "shared"
       )
     (setq decknix--compose-target-buffer target-buf)
     (let ((result (decknix--prompt-search-get)))
       (kill-buffer target-buf)
       ;; Ring items first (in ring order), then cache items minus dups.
       (should (member "ring-only" result))
       (should (member "shared" result))
       (should (member "cached1" result))
       ;; "shared" appears once
       (should (= 1 (cl-count "shared" result :test #'equal)))))))

(ert-deftest decknix-prompt-search-cache--refresh-async-noop-if-live ()
  "Async refresh is a no-op when proc is already alive."
  (decknix-test--with-fresh-cache
   (let ((spawn-count 0))
     (cl-letf (((symbol-function 'process-live-p) (lambda (_p) t))
               ((symbol-function 'start-process-shell-command)
                (lambda (&rest _) (cl-incf spawn-count) nil)))
       (setq decknix--prompt-search-refresh-proc 'fake-live)
       (decknix--prompt-search-refresh-async)
       (should (zerop spawn-count))))))

(provide 'decknix-agent-prompt-search-cache-test)

;;; decknix-agent-prompt-search-cache-test.el ends here
