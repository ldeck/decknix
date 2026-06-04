;;; decknix-sidebar-toggles-key-uniqueness-test.el --- Check for key collisions in sidebar transient -*- lexical-binding: t -*-

(require 'ert)
(require 'transient)
(require 'decknix-agent-shell-hub)
(require 'decknix-agent-shell-workspace)
(require 'decknix-sidebar-toggles)
(require 'decknix-progress-sidebar)
(require 'decknix-hub-attention-filter)

(ert-deftest decknix-sidebar-toggles/transient-keys-are-unique ()
  "Verify that no two suffixes in the flat sidebar transient share the same key."
  (let* ((prefix 'decknix-sidebar-toggles-transient)
         (layout (get prefix 'transient--layout))
         (keys (make-hash-table :test 'equal))
         (collisions nil))
    (unless layout
      (ert-fail "Transient layout not found. Is decknix-agent-shell-workspace loaded?"))
    (cl-labels ((walk (item)
                  (cond
                   ((vectorp item) (mapc #'walk item))
                   ((listp item)
                    (if (eq (car item) 'transient-suffix)
                        (let* ((plist (cdr item))
                               (cmd (plist-get plist :command))
                               (key (plist-get plist :key))
                               (suffix-obj (get cmd 'transient--suffix))
                               (effective-key (or key (and suffix-obj (oref suffix-obj key)))))
                          (when effective-key
                            (if (gethash effective-key keys)
                                (push (format "Key '%s' collision: %s vs %s"
                                              effective-key (gethash effective-key keys) cmd)
                                      collisions)
                              (puthash effective-key cmd keys))))
                      (mapc #'walk item))))))
      (walk layout))
    (let (all-keys)
      (maphash (lambda (k v) (push (format "%s:%s" k v) all-keys)) keys)
      (message "All keys: %s" (mapconcat #'identity (sort all-keys #'string<) ", ")))
    (when collisions
      (ert-fail (mapconcat #'identity (nreverse collisions) "\n")))))

(ert-deftest decknix-sidebar-toggles/worktree-subtransient-keys-are-unique ()
  "Verify that no two suffixes in the worktree sub-transient share the same key."
  (let* ((prefix 'decknix-sidebar-transient--worktrees)
         (layout (get prefix 'transient--layout))
         (keys (make-hash-table :test 'equal))
         (collisions nil))
    (unless layout
      (ert-fail "Worktree transient layout not found."))
    (cl-labels ((walk (item)
                  (cond
                   ((vectorp item) (mapc #'walk item))
                   ((listp item)
                    (if (eq (car item) 'transient-suffix)
                        (let* ((plist (cdr item))
                               (cmd (plist-get plist :command))
                               (key (plist-get plist :key))
                               (suffix-obj (get cmd 'transient--suffix))
                               (effective-key (or key (and suffix-obj (oref suffix-obj key)))))
                          (when effective-key
                            (if (gethash effective-key keys)
                                (push (format "Key '%s' collision: %s vs %s"
                                              effective-key (gethash effective-key keys) cmd)
                                      collisions)
                              (puthash effective-key cmd keys))))
                      (mapc #'walk item))))))
      (walk layout))
    (let (all-keys)
      (maphash (lambda (k v) (push (format "%s:%s" k v) all-keys)) keys)
      (message "Worktree keys: %s" (mapconcat #'identity (sort all-keys #'string<) ", ")))
    (when collisions
      (ert-fail (mapconcat #'identity (nreverse collisions) "\n")))))

(provide 'decknix-sidebar-toggles-key-uniqueness-test)
