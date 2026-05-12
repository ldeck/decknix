;;; decknix-agent-compose-header-test.el --- Tests for compose header-line builder -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Characterisation tests for `decknix-agent-compose-header'
;; (PR B.74).  Pure list/string assertions; no buffer setup or
;; stubbing required.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-compose-header)

(defun decknix-test--header-text (segments)
  "Concat the text content of all SEGMENTS, dropping properties."
  (mapconcat #'substring-no-properties segments ""))

(defun decknix-test--header-faces (segments)
  "Return the list of `font-lock-face' values across SEGMENTS."
  (mapcar (lambda (s)
            (get-text-property 0 'font-lock-face s))
          segments))

(ert-deftest decknix-compose-header--shape-is-ten-segments ()
  "The header is a flat list of 10 propertized strings."
  (let ((segs (decknix--compose-build-header-line nil)))
    (should (listp segs))
    (should (= 10 (length segs)))
    (should (cl-every #'stringp segs))))

(ert-deftest decknix-compose-header--non-sticky-shows-circle ()
  "Non-sticky header opens with the open-circle glyph + comment face."
  (let* ((segs (decknix--compose-build-header-line nil))
         (first (car segs)))
    (should (string= first " ○ Compose"))
    (should (eq 'font-lock-comment-face
                (get-text-property 0 'font-lock-face first)))))

(ert-deftest decknix-compose-header--sticky-shows-filled-circle ()
  "Sticky header opens with the filled-circle glyph + constant face."
  (let* ((segs (decknix--compose-build-header-line t))
         (first (car segs)))
    (should (string= first " ● Compose [sticky]"))
    (should (eq 'font-lock-constant-face
                (get-text-property 0 'font-lock-face first)))))

(ert-deftest decknix-compose-header--advertises-c-c-and-m-keys ()
  "The header text mentions the C-c prefix and the M-p/M-n/M-r keys."
  (let ((text (decknix-test--header-text
               (decknix--compose-build-header-line nil))))
    (should (string-match-p "C-c" text))
    (should (string-match-p "M-p" text))
    (should (string-match-p "M-n" text))
    (should (string-match-p "M-r" text))
    (should (string-match-p "actions" text))
    (should (string-match-p "cycle" text))
    (should (string-match-p "search" text))))

(ert-deftest decknix-compose-header--key-segments-use-keyword-face ()
  "M-p / M-n / M-r and C-c segments are tinted with `font-lock-keyword-face'."
  (let* ((segs (decknix--compose-build-header-line nil))
         (faces (decknix-test--header-faces segs)))
    ;; Keyword segments live at indices 2, 4, 6, 8 (C-c, M-p, M-n, M-r)
    (should (eq 'font-lock-keyword-face (nth 2 faces)))
    (should (eq 'font-lock-keyword-face (nth 4 faces)))
    (should (eq 'font-lock-keyword-face (nth 6 faces)))
    (should (eq 'font-lock-keyword-face (nth 8 faces)))))

(ert-deftest decknix-compose-header--toggle-only-affects-prefix ()
  "Sticky vs non-sticky differs only in the first segment."
  (let* ((s-segs (decknix--compose-build-header-line t))
         (n-segs (decknix--compose-build-header-line nil)))
    (should-not (string= (car s-segs) (car n-segs)))
    (should (equal (cdr s-segs) (cdr n-segs)))))

(provide 'decknix-agent-compose-header-test)

;;; decknix-agent-compose-header-test.el ends here
