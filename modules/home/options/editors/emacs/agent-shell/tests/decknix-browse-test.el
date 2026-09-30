;;; decknix-browse-test.el --- Tests for browser resolution -*- lexical-binding: t -*-

;;; Commentary:
;;
;; `browse-url-firefox' failed because `browse-url-firefox-program' defaults
;; to "firefox" and the nixpkgs darwin build ships only an `.app' bundle.
;; These pin the resolution order and the executability check, both of which
;; exist to avoid the two ways this silently breaks: preferring a stale
;; /Applications copy over the one this config installs, and accepting a
;; symlink into a garbage-collected store path.

;;; Code:

(require 'ert)
(require 'decknix-browse)

;; --- candidate resolution ---------------------------------------------

(ert-deftest decknix-browse--picks-the-first-usable-candidate ()
  "Order is preference, not luck: Home Manager's copy must win."
  (let ((dir (make-temp-file "decknix-browse" t)))
    (unwind-protect
        (let ((a (expand-file-name "a" dir))
              (b (expand-file-name "b" dir)))
          (dolist (f (list a b))
            (write-region "" nil f)
            (set-file-modes f #o755))
          (should (equal a (decknix-browse--first-executable (list a b))))
          (should (equal b (decknix-browse--first-executable (list b a)))))
      (delete-directory dir t))))

(ert-deftest decknix-browse--skips-a-missing-candidate ()
  "A nix symlink farm that moved between home-manager releases must
degrade to the next location, not to nothing."
  (let ((dir (make-temp-file "decknix-browse" t)))
    (unwind-protect
        (let ((real (expand-file-name "real" dir)))
          (write-region "" nil real)
          (set-file-modes real #o755)
          (should (equal real (decknix-browse--first-executable
                               (list (expand-file-name "gone" dir) real)))))
      (delete-directory dir t))))

(ert-deftest decknix-browse--rejects-a-non-executable-file ()
  "An existing but non-executable path would be handed to `start-process'
and fail at call time rather than at resolution time."
  (let ((dir (make-temp-file "decknix-browse" t)))
    (unwind-protect
        (let ((f (expand-file-name "notexec" dir)))
          (write-region "" nil f)
          (set-file-modes f #o644)
          (should-not (decknix-browse--first-executable (list f))))
      (delete-directory dir t))))

(ert-deftest decknix-browse--rejects-a-directory ()
  "The bundle path one level short is a directory; `file-executable-p' is
true for directories, so the explicit directory check is load-bearing."
  (let ((dir (make-temp-file "decknix-browse" t)))
    (unwind-protect
        (should-not (decknix-browse--first-executable (list dir)))
      (delete-directory dir t))))

(ert-deftest decknix-browse--no-candidates-is-nil-not-an-error ()
  "Firefox is installed downstream, so it may genuinely be absent."
  (should-not (decknix-browse--first-executable nil))
  (should-not (decknix-browse--first-executable '("/nonexistent/firefox"))))

;; --- program selection ------------------------------------------------

(ert-deftest decknix-browse--path-firefox-wins ()
  "If the user has a `firefox' on PATH that is what they mean."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (name &rest _) (and (equal name "firefox") "/usr/bin/firefox"))))
    (should (equal "/usr/bin/firefox" (decknix-browse-firefox-program)))))

(ert-deftest decknix-browse--falls-back-to-the-bundle ()
  (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil))
            ((symbol-function 'decknix-browse--first-executable)
             (lambda (_) "~/Applications/Home Manager Apps/Firefox.app/Contents/MacOS/firefox")))
    (should (equal (expand-file-name
                    "~/Applications/Home Manager Apps/Firefox.app/Contents/MacOS/firefox")
                   (decknix-browse-firefox-program)))))

(ert-deftest decknix-browse--program-is-absolute ()
  "`start-process' resolves a relative name against `default-directory',
which for an agent buffer is a worktree, not an app bundle."
  (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil))
            ((symbol-function 'decknix-browse--first-executable)
             (lambda (_) "~/Applications/Firefox.app/Contents/MacOS/firefox")))
    (should (file-name-absolute-p (decknix-browse-firefox-program)))
    (should-not (string-prefix-p "~" (decknix-browse-firefox-program)))))

(ert-deftest decknix-browse--absent-firefox-is-nil ()
  "Nil lets the caller leave `browse-url-firefox-program' alone rather than
setting it to something that cannot run."
  (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil))
            ((symbol-function 'decknix-browse--first-executable) (lambda (_) nil)))
    (should-not (decknix-browse-firefox-program))))

;; --- safari -----------------------------------------------------------

(ert-deftest decknix-browse--safari-targets-safari-explicitly ()
  "`-a Safari' is the point: the system default is another browser, and the
URL still has to reach Safari."
  (should (equal '("-a" "Safari" "https://example.com/x")
                 (decknix-browse--safari-args "https://example.com/x"))))

(ert-deftest decknix-browse--safari-passes-the-url-last ()
  "`open' treats a leading dash as a flag, so the URL must not be reordered
ahead of `-a'."
  (let ((args (decknix-browse--safari-args "https://example.com")))
    (should (equal "https://example.com" (car (last args))))))

(ert-deftest decknix-browse--safari-is-a-browse-url-function ()
  "Must accept the (URL &optional NEW-WINDOW) calling convention so it can
be assigned to `browse-url-browser-function'."
  (should (functionp 'browse-url-safari))
  (should (member (func-arity 'browse-url-safari) '((1 . 2)))))

(provide 'decknix-browse-test)
;;; decknix-browse-test.el ends here
