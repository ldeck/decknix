;;; decknix-sidebar-nav-cmd.el --- Sidebar nav transient item-command factory -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, sidebar, transient

;;; Commentary:
;;
;; Tiny factory extracted from the agent-shell workspace heredoc
;; (workspace-bulk).  Builds an interned-on-the-fly named symbol
;; that carries an interactive command closing over a single
;; ITEM-DATA value, suitable for installation as a transient
;; suffix slot.
;;
;; The factory exists so the section transients
;; (`decknix-sidebar-nav-requests-consult' /
;; `decknix-sidebar-nav-wip-consult' / `-live-consult' /
;; `-previous-consult') can wire one suffix per visible item
;; without paying the cost of defining a top-level command per
;; row.  Each call mints a fresh uninterned symbol so transient's
;; key/symbol cache doesn't collide between paints.
;;
;; Single entry point:
;;
;;   `decknix--nav-make-item-cmd'
;;       Returns a symbol whose function-cell calls ACTION-FN with
;;       ITEM-DATA.  Both arguments are captured as compile-time
;;       backquote splices via `eval ... t' so the resulting
;;       lambda is a true lexical closure (the heredoc is
;;       dynamically scoped, so the original carving site needed
;;       this trick; here under `lexical-binding: t' it is kept
;;       verbatim because the four call-sites in workspace-bulk
;;       still rely on the exact closure semantics).
;;
;; AGENTS.md Rule 2 keeps the four `transient-define-prefix'
;; / `transient-define-suffix' forms that *call* this factory in
;; workspace-bulk -- transient UI is heredoc-side.  This module
;; only owns the pure factory itself.

;;; Code:

(defun decknix--nav-make-item-cmd (item-data action-fn)
  "Create a named command that calls ACTION-FN with ITEM-DATA."
  (let ((sym (make-symbol "decknix--nav-item")))
    (fset sym (eval `(lambda ()
                       (interactive)
                       (funcall ',action-fn ',item-data)) t))
    sym))

(provide 'decknix-sidebar-nav-cmd)
;;; decknix-sidebar-nav-cmd.el ends here
