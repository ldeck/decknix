;;; decknix-ghub-gh-token.el --- Resolve ghub/Forge GitHub tokens via gh -*- lexical-binding: t; -*-

;;; Commentary:

;; ghub (and so Forge) only finds tokens through auth-source, which in
;; practice meant a plaintext ~/.authinfo.  Generating that file from Nix
;; puts the token in the world-readable /nix/store.  The GitHub CLI already
;; holds a token in the macOS keychain, so when auth-source has nothing for
;; a GitHub host we ask `gh auth token' instead and keep the answer only in
;; memory.  An explicit auth-source entry still wins.

;;; Code:

(require 'subr-x)

(defgroup decknix-ghub-gh-token nil
  "Resolve ghub GitHub tokens with the GitHub CLI."
  :group 'tools)

(defcustom decknix-ghub-gh-token-command '("gh")
  "Program and leading arguments used to run the GitHub CLI."
  :type '(repeat string))

(defvar decknix-ghub-gh-token--cache (make-hash-table :test #'equal)
  "Map of \"HOSTNAME USER\" to token, filled by successful gh lookups.")

(defun decknix-ghub-gh-token--hostname (host)
  "Return the gh hostname for ghub API HOST, or nil."
  (when host
    (let ((name (car (split-string host "/"))))
      (if (equal name "api.github.com") "github.com" name))))

(defun decknix-ghub-gh-token-fetch (hostname user)
  "Return USER's token for HOSTNAME from gh, or nil.
Stderr is discarded so nothing gh prints reaches a buffer or log."
  (with-temp-buffer
    (let ((status
           (condition-case nil
               (apply #'call-process (car decknix-ghub-gh-token-command)
                      nil (list t nil) nil
                      (append (cdr decknix-ghub-gh-token-command)
                              (list "auth" "token" "--hostname" hostname
                                    "--user" user)))
             (file-missing nil))))
      (when (eql status 0)
        (let ((token (string-trim (buffer-string))))
          (unless (string-empty-p token) token))))))

(defun decknix-ghub-gh-token-get (host user)
  "Return the cached or freshly fetched gh token for USER on HOST."
  (when-let ((hostname (decknix-ghub-gh-token--hostname host)))
    (let ((key (concat hostname " " user)))
      (or (gethash key decknix-ghub-gh-token--cache)
          (when-let ((token (decknix-ghub-gh-token-fetch hostname user)))
            (puthash key token decknix-ghub-gh-token--cache))))))

(defun decknix-ghub-gh-token-clear-cache ()
  "Forget tokens obtained from gh, e.g. after `gh auth refresh'."
  (interactive)
  (clrhash decknix-ghub-gh-token--cache))

(defun decknix-ghub-gh-token--around (orig host username package
                                           &optional nocreate forge)
  "Advice for `ghub--token': fall back to gh for GitHub hosts.
ORIG, HOST, USERNAME, PACKAGE, NOCREATE and FORGE are as for
`ghub--token'.  When neither source has a token, ORIG runs again
with the caller's NOCREATE so ghub's own error explains the gap."
  (or (funcall orig host username package t forge)
      (and username
           (memq forge '(nil github))
           (decknix-ghub-gh-token-get host username))
      (funcall orig host username package nocreate forge)))

(defun decknix-ghub-gh-token-install (&optional symbol)
  "Advise SYMBOL (default `ghub--token') to fall back to gh."
  (advice-add (or symbol 'ghub--token) :around #'decknix-ghub-gh-token--around))

(defun decknix-ghub-gh-token-uninstall (&optional symbol)
  "Remove the gh fallback from SYMBOL (default `ghub--token')."
  (advice-remove (or symbol 'ghub--token) #'decknix-ghub-gh-token--around))

(provide 'decknix-ghub-gh-token)
;;; decknix-ghub-gh-token.el ends here
