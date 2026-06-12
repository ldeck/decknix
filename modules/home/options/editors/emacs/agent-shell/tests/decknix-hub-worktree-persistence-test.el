;;; decknix-hub-worktree-persistence-test.el --- Worktree clone map persistence -*- lexical-binding: t -*-

;; Package-Requires: ((emacs "29.1") (decknix-agent-shell-hub "0.1"))

;;; Code:

(require 'ert)
(require 'decknix-agent-shell-hub)

(defmacro decknix-hub-test--with-tmp (&rest body)
  "Run BODY with `decknix--hub-worktree-clone-map-file' redirected to a tmp file."
  (declare (indent 0))
  `(let* ((tmp-file (make-temp-file "decknix-hub-test-worktree-clones.el"))
          (decknix--hub-worktree-clone-map-file tmp-file)
          (decknix--hub-worktree-clone-map (make-hash-table :test 'equal)))
     (unwind-protect
         (progn ,@body)
       (when (file-exists-p tmp-file)
         (delete-file tmp-file)))))

(ert-deftest decknix-hub-worktree--clone-map-persistence ()
  "The worktree clone map survives a save/restore cycle."
  (decknix-hub-test--with-tmp
    ;; Initially empty
    (should (= 0 (hash-table-count decknix--hub-worktree-clone-map)))
    
    ;; Populate
    (puthash "/Users/ldeck/Code/decknix/" "decknix/decknix" decknix--hub-worktree-clone-map)
    (puthash "/Users/ldeck/tools/decknix/" "decknix/decknix" decknix--hub-worktree-clone-map)
    (puthash "/Users/ldeck/Code/org/repo/" "org/repo" decknix--hub-worktree-clone-map)
    
    ;; Save
    (decknix--hub-worktree-clone-map-save)
    (should (file-exists-p decknix--hub-worktree-clone-map-file))
    
    ;; Reset and restore
    (setq decknix--hub-worktree-clone-map (make-hash-table :test 'equal))
    (decknix--hub-worktree-clone-map-restore)
    
    ;; Verify
    (should (= 3 (hash-table-count decknix--hub-worktree-clone-map)))
    (should (equal "decknix/decknix" (gethash "/Users/ldeck/Code/decknix/" decknix--hub-worktree-clone-map)))
    (should (equal "org/repo" (gethash "/Users/ldeck/Code/org/repo/" decknix--hub-worktree-clone-map)))))

(provide 'decknix-hub-worktree-persistence-test)
;;; decknix-hub-worktree-persistence-test.el ends here
