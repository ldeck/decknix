;;; decknix-browse.el --- Browser resolution for browse-url -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: browse-url, darwin, firefox, safari

;;; Commentary:
;;
;; `M-x browse-url-firefox' failed outright: `browse-url-firefox-program'
;; defaults to "firefox", and the nixpkgs darwin Firefox ships an `.app'
;; bundle with no `firefox' on PATH.  The executable exists, three levels
;; down inside the bundle.
;;
;; Resolution is by SEARCH rather than a baked store path.  A store path
;; would be correct until the next `nix flake update' and then silently
;; point at a garbage-collected path, and it would also force Firefox into
;; every decknix user's closure -- it is installed downstream (in
;; decknix-config's `home.packages'), not by the editor module.  Searching
;; also covers a hand-installed /Applications copy.
;;
;; `browse-url-safari' has no upstream equivalent at all.  Safari is
;; scriptable only through `open', so it cannot reuse
;; `browse-url-generic'-style argv handling and needs its own function to be
;; selectable as a `browse-url-browser-function' or called on a URL at point
;; when Safari is not the system default.
;;
;; Pure layers here per AGENTS.md Rule 2; `browse-url-firefox-program' is set
;; and the browsers registered from the heredoc.

;;; Code:

(require 'seq)

(defconst decknix-browse-firefox-candidates
  '("~/Applications/Home Manager Apps/Firefox.app/Contents/MacOS/firefox"
    "~/.nix-profile/Applications/Firefox.app/Contents/MacOS/firefox"
    "~/Applications/Nix Apps/Firefox.app/Contents/MacOS/firefox"
    "/Applications/Firefox.app/Contents/MacOS/firefox"
    "~/Applications/Firefox.app/Contents/MacOS/firefox")
  "Where to look for the Firefox executable, in preference order.

Home Manager's app directory comes first so the version this
configuration actually installs wins over a stale hand-installed copy in
/Applications.  All three nix locations are listed because they are
symlink farms that have moved between home-manager releases, and a single
one going away should degrade to the next rather than to nothing.")

(defun decknix-browse--first-executable (candidates)
  "Return the first of CANDIDATES that exists and is executable.  Pure.

Tests executability rather than mere existence: every nix candidate is a
symlink, and one pointing into a garbage-collected store path still
satisfies `file-exists-p' on the link itself in some orders."
  (seq-find (lambda (path)
              (let ((expanded (expand-file-name path)))
                (and (file-exists-p expanded)
                     (file-executable-p expanded)
                     (not (file-directory-p expanded)))))
            candidates))

(defun decknix-browse-firefox-program ()
  "Return a usable Firefox program name, or nil.

Prefers a `firefox' already on PATH -- if one exists it is what the user
means -- and only then searches the bundle locations."
  (or (executable-find "firefox")
      (let ((found (decknix-browse--first-executable
                    decknix-browse-firefox-candidates)))
        (and found (expand-file-name found)))))

(defconst decknix-browse-safari-app "Safari"
  "Application name passed to `open -a'.
Safari has no CLI entry point, so `open' is the only supported way to
address it specifically.")

(defun decknix-browse--safari-args (url)
  "Return the argv for opening URL in Safari.  Pure.

`-a Safari' targets Safari regardless of the system default handler, which
is the whole point: the default is something else, and the URL still needs
to go to Safari sometimes (a page already authenticated in a Safari
session, for instance)."
  (list "-a" decknix-browse-safari-app url))

;;;###autoload
(defun browse-url-safari (url &optional _new-window)
  "Open URL in Safari, whatever the system default browser is.

Usable as a `browse-url-browser-function', and interactively on the URL at
point.  NEW-WINDOW is accepted for interface compatibility and ignored:
`open' gives no control over window reuse."
  (interactive (browse-url-interactive-arg "URL: "))
  (unless (eq system-type 'darwin)
    (user-error "Safari is only available on macOS"))
  (let ((url (browse-url-encode-url url)))
    (apply #'start-process (concat "safari " url) nil "open"
           (decknix-browse--safari-args url))))

(provide 'decknix-browse)
;;; decknix-browse.el ends here
