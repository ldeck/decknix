;;; decknix-webkit-fetch-test.el --- Tests for the xwidget-webkit fetch bridge -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-webkit-fetch "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; Every xwidget entry point and `run-at-time' is stubbed, so these run
;; on builds without xwidget support and never wait on a timer: a test
;; fires the captured poll or deadline function itself.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'decknix-webkit-fetch)

(defvar xwidget-webkit-last-session-buffer nil)
(defvar decknix-webkit-fetch-test--scripts nil)
(defvar decknix-webkit-fetch-test--timers nil)

(defmacro decknix-webkit-fetch-test--with-page (uri responder &rest body)
  "Run BODY with one fake session on URI.
RESPONDER is called with each executed script and returns the value
the page hands to the script's callback (or `:no-callback')."
  (declare (indent 2))
  `(let ((decknix-webkit-fetch-test--scripts nil)
         (decknix-webkit-fetch-test--timers nil)
         (decknix-webkit-fetch--pending (make-hash-table :test #'equal)))
     (cl-letf (((symbol-function 'decknix-webkit-fetch-supported-p) (lambda () t))
               ((symbol-function 'decknix-webkit-fetch--session-xwidgets) (lambda () (list 'xw)))
               ((symbol-function 'xwidget-webkit-uri) (lambda (_xw) ,uri))
               ((symbol-function 'xwidget-webkit-execute-script)
                (lambda (_xw script &optional callback)
                  (push script decknix-webkit-fetch-test--scripts)
                  (let ((value (funcall ,responder script)))
                    (when (and callback (not (eq value :no-callback)))
                      (funcall callback value)))))
               ((symbol-function 'run-at-time)
                (lambda (secs repeat fn &rest args)
                  (let ((timer (timer-create)))
                    (push (list :secs secs :repeat repeat :fn fn :args args)
                          decknix-webkit-fetch-test--timers)
                    timer))))
       ,@body)))

(defun decknix-webkit-fetch-test--fire (pred)
  "Call the first captured timer whose plist satisfies PRED."
  (let ((timer (cl-find-if pred decknix-webkit-fetch-test--timers)))
    (should timer)
    (apply (plist-get timer :fn) (plist-get timer :args))))

(defun decknix-webkit-fetch-test--fire-poll ()
  (decknix-webkit-fetch-test--fire (lambda (tm) (plist-get tm :repeat))))

(defun decknix-webkit-fetch-test--fire-deadline ()
  (decknix-webkit-fetch-test--fire (lambda (tm) (null (plist-get tm :repeat)))))

(defun decknix-webkit-fetch-test--request (dir &rest fields)
  "Write a request file in DIR with FIELDS merged over a GET default."
  (let ((file (expand-file-name "request.json" dir))
        (request (append fields
                         `((url . "https://svc.example.com/api/x?y=1")
                           (method . "GET")
                           (headers . ((X-Requested-With . "XMLHttpRequest")))
                           (body . nil)
                           (timeout_ms . 5000)
                           (result . ,(expand-file-name "result.json" dir)))))
        (json-null nil))
    (with-temp-file file (insert (json-encode request)))
    file))

(defun decknix-webkit-fetch-test--read (dir)
  (let ((file (expand-file-name "result.json" dir)))
    (and (file-exists-p file)
         (with-temp-buffer (insert-file-contents file) (buffer-string)))))

(defmacro decknix-webkit-fetch-test--in-dir (var &rest body)
  (declare (indent 1))
  `(let ((,var (make-temp-file "webkit-fetch-test" t)))
     (unwind-protect (progn ,@body) (delete-directory ,var t))))

(defun decknix-webkit-fetch-test--page (result)
  "A responder that starts any fetch and then answers polls with RESULT."
  (lambda (script)
    (if (string-match-p "fetch(" script) "started" result)))

;;; Pure helpers

(ert-deftest decknix-webkit-fetch-test-origin-and-path ()
  (should (equal (decknix-webkit-fetch-origin "https://Svc.Example.com/a?b=1") "https://svc.example.com"))
  (should (equal (decknix-webkit-fetch-origin "https://svc.example.com:8443/") "https://svc.example.com:8443"))
  (should (null (decknix-webkit-fetch-origin nil)))
  (should (null (decknix-webkit-fetch-origin "not a url")))
  (should (equal (decknix-webkit-fetch-path "https://svc.example.com/a/b?c=1") "/a/b?c=1"))
  (should (equal (decknix-webkit-fetch-path "https://svc.example.com") "/")))

(ert-deftest decknix-webkit-fetch-test-script-escapes-and-never-follows-redirects ()
  (let* ((body "{\"a\":\"q\\\"uote\nline</script>\"}")
         (script (decknix-webkit-fetch-script "f1-1" "post" "/p?x='1'" '(("X-A" . "v\"1")) body 5000)))
    (should (string-match-p (regexp-quote (json-encode-string body)) script))
    (should (string-match-p (regexp-quote "fetch(\"/p?x='1'\",o)") script))
    (should (string-match-p (regexp-quote "method:\"POST\"") script))
    (should (string-match-p (regexp-quote "{\"X-A\":\"v\\\"1\"}") script))
    (should (string-match-p (regexp-quote "redirect:'manual'") script))
    (should (string-match-p (regexp-quote "credentials:'include'") script))
    (should (string-match-p (regexp-quote "setTimeout(function(){c.abort();},5000)") script))
    (should-not (string-match-p "\n" script))))

(ert-deftest decknix-webkit-fetch-test-script-null-body-and-empty-headers ()
  (let ((script (decknix-webkit-fetch-script "f1-2" "GET" "/" nil nil 1000)))
    (should (string-match-p (regexp-quote "var b=null;") script))
    (should (string-match-p (regexp-quote "headers:{}") script))))

(ert-deftest decknix-webkit-fetch-test-poll-script ()
  (let ((script (decknix-webkit-fetch-poll-script "f9-3")))
    (should (string-match-p (regexp-quote "var id=\"f9-3\"") script))
    (should (string-match-p "return 'missing'" script))
    (should (string-match-p "delete s\\[id\\]" script))))

;;; Request-file entry point

(ert-deftest decknix-webkit-fetch-test-callback-writes-the-result-file ()
  (decknix-webkit-fetch-test--in-dir dir
    (let ((result "{\"ok\":true,\"status\":200,\"type\":\"basic\",\"body\":\"UP\"}"))
      (decknix-webkit-fetch-test--with-page "https://svc.example.com/home"
          (decknix-webkit-fetch-test--page result)
        (should (eq (decknix-webkit-fetch-request-file (decknix-webkit-fetch-test--request dir)) 'queued))
        (should (null (decknix-webkit-fetch-test--read dir)))
        (decknix-webkit-fetch-test--fire-poll)
        (should (equal (decknix-webkit-fetch-test--read dir) result))
        (should (zerop (hash-table-count decknix-webkit-fetch--pending)))
        (let ((start (car (last decknix-webkit-fetch-test--scripts))))
          (should (string-match-p (regexp-quote "fetch(\"/api/x?y=1\",o)") start))
          (should (string-match-p (regexp-quote "\"X-Requested-With\":\"XMLHttpRequest\"") start)))))))

(ert-deftest decknix-webkit-fetch-test-pending-poll-writes-nothing ()
  (decknix-webkit-fetch-test--in-dir dir
    (decknix-webkit-fetch-test--with-page "https://svc.example.com/"
        (decknix-webkit-fetch-test--page nil)
      (decknix-webkit-fetch-request-file (decknix-webkit-fetch-test--request dir))
      (decknix-webkit-fetch-test--fire-poll)
      (should (null (decknix-webkit-fetch-test--read dir)))
      (should (= 1 (hash-table-count decknix-webkit-fetch--pending))))))

(ert-deftest decknix-webkit-fetch-test-opaque-redirect-is-passed-through ()
  (decknix-webkit-fetch-test--in-dir dir
    (let ((result "{\"ok\":true,\"status\":0,\"type\":\"opaqueredirect\",\"body\":\"\"}"))
      (decknix-webkit-fetch-test--with-page "https://svc.example.com/"
          (decknix-webkit-fetch-test--page result)
        (decknix-webkit-fetch-request-file (decknix-webkit-fetch-test--request dir))
        (decknix-webkit-fetch-test--fire-poll)
        (should (equal (alist-get 'type (json-read-from-string (decknix-webkit-fetch-test--read dir)))
                       "opaqueredirect"))))))

(ert-deftest decknix-webkit-fetch-test-no-session-on-another-origin ()
  (decknix-webkit-fetch-test--in-dir dir
    (decknix-webkit-fetch-test--with-page "https://accounts.google.com/v3/signin"
        (lambda (_) (error "must not run a script"))
      (should (eq (decknix-webkit-fetch-request-file (decknix-webkit-fetch-test--request dir)) 'no-session))
      (should (null decknix-webkit-fetch-test--scripts))
      (should (equal (alist-get 'error (json-read-from-string (decknix-webkit-fetch-test--read dir)))
                     "no-session")))))

(ert-deftest decknix-webkit-fetch-test-unsupported-build ()
  (decknix-webkit-fetch-test--in-dir dir
    (decknix-webkit-fetch-test--with-page "https://svc.example.com/" (lambda (_) "started")
      (cl-letf (((symbol-function 'decknix-webkit-fetch-supported-p) (lambda () nil)))
        (should (eq (decknix-webkit-fetch-request-file (decknix-webkit-fetch-test--request dir)) 'unsupported))
        (should (equal (alist-get 'error (json-read-from-string (decknix-webkit-fetch-test--read dir)))
                       "unsupported"))))))

(ert-deftest decknix-webkit-fetch-test-navigation-loses-the-fetch ()
  (decknix-webkit-fetch-test--in-dir dir
    (decknix-webkit-fetch-test--with-page "https://svc.example.com/"
        (decknix-webkit-fetch-test--page "missing")
      (decknix-webkit-fetch-request-file (decknix-webkit-fetch-test--request dir))
      (decknix-webkit-fetch-test--fire-poll)
      (should (equal (alist-get 'error (json-read-from-string (decknix-webkit-fetch-test--read dir)))
                     "navigated")))))

(ert-deftest decknix-webkit-fetch-test-deadline-writes-timeout-once ()
  (decknix-webkit-fetch-test--in-dir dir
    (decknix-webkit-fetch-test--with-page "https://svc.example.com/"
        (decknix-webkit-fetch-test--page "{\"ok\":true,\"status\":200}")
      (decknix-webkit-fetch-request-file (decknix-webkit-fetch-test--request dir))
      (let ((deadline (cl-find-if (lambda (tm) (null (plist-get tm :repeat)))
                                  decknix-webkit-fetch-test--timers)))
        (should (= (plist-get deadline :secs) 7.0)))
      (decknix-webkit-fetch-test--fire-deadline)
      (should (equal (alist-get 'error (json-read-from-string (decknix-webkit-fetch-test--read dir)))
                     "timeout"))
      (decknix-webkit-fetch-test--fire-poll)
      (should (equal (alist-get 'error (json-read-from-string (decknix-webkit-fetch-test--read dir)))
                     "timeout")))))

(ert-deftest decknix-webkit-fetch-test-start-not-acknowledged ()
  (decknix-webkit-fetch-test--in-dir dir
    (decknix-webkit-fetch-test--with-page "https://svc.example.com/" (lambda (_) nil)
      (decknix-webkit-fetch-request-file (decknix-webkit-fetch-test--request dir))
      (should (equal (alist-get 'error (json-read-from-string (decknix-webkit-fetch-test--read dir)))
                     "fetch-failed"))
      (should (zerop (hash-table-count decknix-webkit-fetch--pending))))))

(ert-deftest decknix-webkit-fetch-test-script-error-is-reported-not-signalled ()
  (decknix-webkit-fetch-test--in-dir dir
    (decknix-webkit-fetch-test--with-page "https://svc.example.com/" (lambda (_) (error "xwidget gone"))
      (should (eq (decknix-webkit-fetch-request-file (decknix-webkit-fetch-test--request dir)) 'queued))
      (let ((result (json-read-from-string (decknix-webkit-fetch-test--read dir))))
        (should (equal (alist-get 'error result) "fetch-failed"))
        (should (string-match-p "xwidget gone" (alist-get 'message result)))))))

(ert-deftest decknix-webkit-fetch-test-refuses-cross-origin ()
  (decknix-webkit-fetch-test--with-page "https://svc.example.com/" (lambda (_) "started")
    (should-error (decknix-webkit-fetch 'xw "https://other.example.com/x" :callback #'ignore))
    (should (null decknix-webkit-fetch-test--scripts))))

(ert-deftest decknix-webkit-fetch-test-late-result-is-dropped-when-dir-is-gone ()
  (let ((dir (make-temp-file "webkit-fetch-test" t)))
    (delete-directory dir t)
    (decknix-webkit-fetch--write-result (expand-file-name "result.json" dir) "{}")
    (should-not (file-exists-p dir))))

;;; Session open

(ert-deftest decknix-webkit-fetch-test-open-keeps-the-session-out-of-link-reuse ()
  (let ((other (generate-new-buffer " other-webkit"))
        (session (generate-new-buffer " sso-session")))
    (unwind-protect
        (let ((xwidget-webkit-last-session-buffer other)
              opened)
          (cl-letf (((symbol-function 'decknix-webkit-fetch-supported-p) (lambda () t))
                    ((symbol-function 'require)
                     (let ((real (symbol-function 'require)))
                       (lambda (feature &rest args)
                         (or (eq feature 'xwidget) (apply real feature args)))))
                    ((symbol-function 'decknix-webkit-fetch--session-xwidgets) (lambda () nil))
                    ((symbol-function 'xwidget-webkit-new-session)
                     (lambda (url)
                       (setq opened url)
                       (setq xwidget-webkit-last-session-buffer session)
                       (set-buffer session))))
            (with-current-buffer (get-buffer-create " caller")
              (decknix-webkit-session-open "https://svc.example.com/"))
            (should (equal opened "https://svc.example.com/"))
            (should (eq xwidget-webkit-last-session-buffer other))))
      (kill-buffer other)
      (kill-buffer session)
      (kill-buffer " caller"))))

(ert-deftest decknix-webkit-fetch-test-open-refuses-without-xwidgets ()
  (cl-letf (((symbol-function 'decknix-webkit-fetch-supported-p) (lambda () nil)))
    (should-error (decknix-webkit-session-open "https://svc.example.com/") :type 'user-error)))

(provide 'decknix-webkit-fetch-test)
;;; decknix-webkit-fetch-test.el ends here
