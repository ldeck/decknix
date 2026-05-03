;;; decknix-sidebar-footer-keys.el --- Sidebar footer Navigate / Quick key alists -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, sidebar

;;; Commentary:
;;
;; Pure builders for the two simple sections of the sidebar footer
;; (Navigate + Quick).  The third section (Toggles) is much larger
;; and pulls in many free vars from hub-bulk; it stays in
;; workspace-bulk for now.
;;
;; Two entry points:
;;
;;   `decknix--sidebar-footer-nav-keys'
;;       Returns the Navigate alist `((KEY . LABEL) ...)' for the
;;       footer.  Includes the `p' / `P' restore entries only when
;;       `decknix--sidebar-previous-sessions' is non-nil so the
;;       footer doesn't advertise restore verbs that would no-op.
;;
;;   `decknix--sidebar-footer-quick-keys'
;;       Returns the Quick alist `((KEY . LABEL) ...)' for the
;;       footer.  A constant -- the keys are sorted alphabetically
;;       by label and review launching is merged into the `r'
;;       (requests) picker via its `M-r' toggle.
;;
;; AGENTS.md Rule 2 keeps the rendering side-effect (the
;; `decknix--sidebar-render-key-group{,-inline}' calls that consume
;; these alists) in workspace-bulk -- this module only owns the
;; pure data builders.  The single call site at workspace-bulk
;; line ~1006 reaches both symbols through the heredoc's
;; `(require ...)' chain.

;;; Code:

;; Forward declaration for the one free var consulted by
;; `decknix--sidebar-footer-nav-keys'.  Defined and mutated by the
;; sidebar refresh path in workspace-bulk; declared here as a
;; defvar-without-value so the byte-compiler does not warn about
;; the reference.
(defvar decknix--sidebar-previous-sessions)

(defun decknix--sidebar-footer-nav-keys ()
  "Build the Navigate key alist for the footer."
  (append
   '(("r"   . "requests")
     ("w"   . "wip")
     ("l"   . "live"))
   (when decknix--sidebar-previous-sessions
     '(("p"   . "restore…")
       ("P"   . "restore all")))
   '(("s"   . "sessions…"))))

(defun decknix--sidebar-footer-quick-keys ()
  "Build the Quick key alist for the footer.
Sorted alphabetically by label; review launching is merged into
the `r' (requests) picker via its `M-r' toggle."
  '(("a"   . "actions…")
    ("c"   . "new")
    ("RET" . "open")
    ("q"   . "quit")
    ("g"   . "refresh")
    ("T"   . "toggles")))

(provide 'decknix-sidebar-footer-keys)
;;; decknix-sidebar-footer-keys.el ends here
