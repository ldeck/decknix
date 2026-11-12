;;; decknix-webkit-fetch.el --- Same-origin fetch() through an xwidget-webkit session -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: decknix, xwidget, webkit, http

;;; Commentary:
;;
;; Run an HTTP request *inside* an xwidget-webkit page, so it carries
;; whatever session that page holds (cookies set by an SSO sign-in,
;; including in-memory session cookies that never reach disk).  The
;; request is a JS `fetch' with `credentials: include' and
;; `redirect: manual', issued only from a page whose origin equals the
;; target's origin, so the session is never sent anywhere else.
;;
;; Everything is event-driven; nothing here waits:
;;
;;   `decknix-webkit-fetch'               start a fetch in a session and
;;                                        call back with the result JSON
;;   `decknix-webkit-fetch-request-file'  external entry point: read a
;;                                        request JSON file, start the
;;                                        fetch, return a symbol at once
;;                                        and write the result file later
;;   `decknix-webkit-session-open'        open (or reload) a session
;;                                        buffer for a URL so the user can
;;                                        sign in
;;
;; WKWebView's `evaluateJavaScript' does not await promises, so the
;; start script parks the result in `window.__decknixFetch[ID]' and a
;; repeating timer reads it back with an asynchronous
;; `xwidget-webkit-execute-script' callback.  A deadline timer delivers
;; a timeout result if the page never answers (navigated away, closed).
;;
;; `decknix-webkit-fetch-request-file' is meant for `emacsclient -e':
;; it reads one local file, scans buffers and schedules the fetch, then
;; returns `queued', `no-session' or `unsupported'.  The caller waits on
;; the result file outside Emacs with its own timeout, so a slow or
;; hung request can never freeze the editor.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'url-parse)

(declare-function xwidget-at "xwidget" (pos))
(declare-function xwidget-webkit-uri "xwidget" (xwidget))
(declare-function xwidget-webkit-execute-script "xwidget" (xwidget script &optional callback))
(declare-function xwidget-webkit-new-session "xwidget" (url))
(declare-function xwidget-webkit-goto-uri "xwidget" (xwidget uri))
(declare-function xwidget-buffer "xwidget" (xwidget))

(defvar xwidget-webkit-last-session-buffer)

(defgroup decknix-webkit-fetch nil
  "Same-origin HTTP requests through an xwidget-webkit session."
  :group 'decknix)

(defcustom decknix-webkit-fetch-poll-interval 0.2
  "Seconds between reads of a pending fetch result from the page."
  :type 'number)

(defcustom decknix-webkit-fetch-default-timeout-ms 60000
  "Timeout for a fetch when the request does not give one, in milliseconds."
  :type 'integer)

(defvar decknix-webkit-fetch--pending (make-hash-table :test #'equal)
  "Pending fetches: id -> plist of :poll and :deadline timers.")

(defvar decknix-webkit-fetch--counter 0)

(defun decknix-webkit-fetch-supported-p ()
  "Non-nil when this Emacs was built with xwidget support."
  (featurep 'xwidget-internal))

(defun decknix-webkit-fetch-origin (url)
  "Return the scheme://host[:port] origin of URL, or nil if it has none."
  (let ((parsed (and (stringp url) (url-generic-parse-url url))))
    (when (and parsed (url-type parsed) (url-host parsed)
               (not (string-empty-p (url-host parsed))))
      (let ((port (url-portspec parsed)))
        (concat (downcase (url-type parsed)) "://" (downcase (url-host parsed))
                (if port (format ":%d" port) ""))))))

(defun decknix-webkit-fetch-path (url)
  "Return the path and query of URL, defaulting to \"/\"."
  (let ((file (url-filename (url-generic-parse-url url))))
    (if (or (null file) (string-empty-p file)) "/"
      (if (string-prefix-p "/" file) file (concat "/" file)))))

(defun decknix-webkit-fetch--session-xwidgets ()
  "Return the xwidgets of live xwidget-webkit buffers, most recent first."
  (delq nil
        (mapcar (lambda (buffer)
                  (with-current-buffer buffer
                    (and (derived-mode-p 'xwidget-webkit-mode)
                         (xwidget-at (point-min)))))
                (buffer-list))))

(defun decknix-webkit-fetch-session-for-origin (origin)
  "Return an xwidget-webkit session whose current page is on ORIGIN, or nil."
  (cl-find-if (lambda (xwidget)
                (equal (decknix-webkit-fetch-origin (ignore-errors (xwidget-webkit-uri xwidget)))
                       origin))
              (decknix-webkit-fetch--session-xwidgets)))

(defun decknix-webkit-fetch--json-object (alist)
  "Encode ALIST of (NAME . VALUE) strings as a JSON object string."
  (if alist
      (let ((json-encoding-pretty-print nil))
        (json-encode (mapcar (lambda (pair) (cons (format "%s" (car pair)) (cdr pair))) alist)))
    "{}"))

(defun decknix-webkit-fetch-script (id method path headers body timeout-ms)
  "Return the JS that starts fetch ID and parks its JSON result in the page.
METHOD, PATH and BODY (a string or nil) are JSON-encoded, never spliced
raw, so any quote or newline in them stays data.  HEADERS is an alist.
The fetch never follows redirects: a redirect surfaces as
type \"opaqueredirect\" with status 0."
  (format
   (concat
    "(function(){var s=window.__decknixFetch||(window.__decknixFetch={});var id=%s;s[id]=null;"
    "var c=new AbortController();var t=setTimeout(function(){c.abort();},%d);"
    "var o={method:%s,headers:%s,credentials:'include',redirect:'manual',cache:'no-store',signal:c.signal};"
    "var b=%s;if(b!==null){o.body=b;}"
    "fetch(%s,o).then(function(r){return r.text().then(function(x){var h=[];"
    "r.headers.forEach(function(v,k){h.push([k,v]);});"
    "s[id]=JSON.stringify({ok:true,status:r.status,statusText:r.statusText,type:r.type,url:r.url,headers:h,body:x});});})"
    ".catch(function(e){s[id]=JSON.stringify({ok:false,error:(e&&e.name==='AbortError')?'timeout':'fetch-failed',message:String(e)});})"
    ".finally(function(){clearTimeout(t);});return 'started';})()")
   (json-encode-string id)
   timeout-ms
   (json-encode-string (upcase method))
   (decknix-webkit-fetch--json-object headers)
   (if body (json-encode-string body) "null")
   (json-encode-string path)))

(defun decknix-webkit-fetch-poll-script (id)
  "Return the JS that hands back fetch ID's result once, or null while pending.
Returns the string \"missing\" when the page has no record of ID, which
means it navigated or reloaded after the fetch started."
  (format
   (concat "(function(){var s=window.__decknixFetch;var id=%s;"
           "if(!s||!(id in s))return 'missing';var v=s[id];if(v===null)return null;"
           "delete s[id];return v;})()")
   (json-encode-string id)))

(defun decknix-webkit-fetch-error-json (error &optional message)
  "Return a result JSON string for ERROR (a string) with optional MESSAGE."
  (json-encode `((ok . :json-false) (error . ,error) (message . ,(or message "")))))

(defun decknix-webkit-fetch--finish (id result callback)
  "Deliver RESULT for fetch ID to CALLBACK once and drop its timers."
  (let ((entry (gethash id decknix-webkit-fetch--pending)))
    (when entry
      (remhash id decknix-webkit-fetch--pending)
      (dolist (key '(:poll :deadline))
        (when (timerp (plist-get entry key)) (cancel-timer (plist-get entry key))))
      (funcall callback result))))

(defun decknix-webkit-fetch--poll (xwidget id callback)
  "Ask XWIDGET, asynchronously, whether fetch ID has finished."
  (let ((entry (gethash id decknix-webkit-fetch--pending)))
    (when (and entry (not (plist-get entry :in-flight)))
      (puthash id (plist-put entry :in-flight t) decknix-webkit-fetch--pending)
      (condition-case err
          (xwidget-webkit-execute-script
           xwidget (decknix-webkit-fetch-poll-script id)
           (lambda (value)
             (let ((entry (gethash id decknix-webkit-fetch--pending)))
               (when entry
                 (puthash id (plist-put entry :in-flight nil) decknix-webkit-fetch--pending)
                 (cond ((equal value "missing")
                        (decknix-webkit-fetch--finish
                         id (decknix-webkit-fetch-error-json
                             "navigated" "the page navigated before the fetch finished")
                         callback))
                       ((stringp value)
                        (decknix-webkit-fetch--finish id value callback)))))))
        (error (decknix-webkit-fetch--finish
                id (decknix-webkit-fetch-error-json "fetch-failed" (error-message-string err))
                callback))))))

(defun decknix-webkit-fetch--started (xwidget id started callback)
  "Begin polling XWIDGET for fetch ID once its start script returned STARTED."
  (let ((entry (gethash id decknix-webkit-fetch--pending)))
    (when entry
      (if (equal started "started")
          (puthash id (plist-put entry :poll
                                 (run-at-time decknix-webkit-fetch-poll-interval
                                              decknix-webkit-fetch-poll-interval
                                              #'decknix-webkit-fetch--poll xwidget id callback))
                   decknix-webkit-fetch--pending)
        (decknix-webkit-fetch--finish
         id (decknix-webkit-fetch-error-json "fetch-failed" "the page did not start the fetch")
         callback)))))

(cl-defun decknix-webkit-fetch (xwidget url &key (method "GET") headers body timeout-ms callback)
  "Run METHOD URL as a same-origin fetch inside XWIDGET's page.
Returns the fetch id immediately.  CALLBACK later receives one JSON
string: the response (status, type, url, headers, body) or an error
\(timeout, fetch-failed, navigated).  HEADERS is an alist; BODY a string
or nil.  Signals an error when URL's origin is not the page's origin."
  (let* ((page-origin (decknix-webkit-fetch-origin (xwidget-webkit-uri xwidget)))
         (origin (decknix-webkit-fetch-origin url))
         (timeout-ms (or timeout-ms decknix-webkit-fetch-default-timeout-ms))
         (id (format "f%d-%d" (emacs-pid) (cl-incf decknix-webkit-fetch--counter))))
    (unless (and origin (equal origin page-origin))
      (error "decknix-webkit-fetch: %s is not on the page's origin %s" url page-origin))
    (puthash id (list :in-flight nil
                      :deadline (run-at-time (+ (/ timeout-ms 1000.0) 2) nil
                                             #'decknix-webkit-fetch--finish id
                                             (decknix-webkit-fetch-error-json
                                              "timeout" "no result from the page in time")
                                             callback))
             decknix-webkit-fetch--pending)
    (condition-case err
        (xwidget-webkit-execute-script
         xwidget
         (decknix-webkit-fetch-script id method (decknix-webkit-fetch-path url) headers body timeout-ms)
         (lambda (started) (decknix-webkit-fetch--started xwidget id started callback)))
      (error (decknix-webkit-fetch--finish
              id (decknix-webkit-fetch-error-json "fetch-failed" (error-message-string err))
              callback)))
    id))

(defun decknix-webkit-fetch--write-result (file json)
  "Write JSON to FILE atomically, only if FILE's directory still exists.
The caller deletes its directory when it gives up, so a late result
is dropped rather than recreating it."
  (let ((dir (file-name-directory file)))
    (when (file-directory-p dir)
      (let ((tmp (concat file ".tmp")))
        (with-temp-file tmp
          (set-buffer-file-coding-system 'utf-8-unix)
          (insert json))
        (rename-file tmp file t)))))

(defun decknix-webkit-fetch--read-request (file)
  "Parse the request JSON in FILE into an alist."
  (with-temp-buffer
    (insert-file-contents file)
    (json-parse-buffer :object-type 'alist :null-object nil :false-object nil)))

(defun decknix-webkit-fetch-request-file (file)
  "Start the request described by JSON FILE and return a symbol immediately.
FILE holds url, method, headers (object), body (string or null),
timeout_ms and result (the path to write).  Returns `queued' when the
fetch started (the result file is written when it finishes or times
out), or `no-session' / `unsupported' (also written to the result
file).  Never waits on the network, so it is safe from `emacsclient -e'."
  (let* ((request (decknix-webkit-fetch--read-request file))
         (result-file (alist-get 'result request))
         (url (alist-get 'url request))
         (write (lambda (json)
                  (ignore-errors (decknix-webkit-fetch--write-result result-file json)))))
    (cond
     ((not (decknix-webkit-fetch-supported-p))
      (funcall write (decknix-webkit-fetch-error-json "unsupported" "Emacs lacks xwidget support"))
      'unsupported)
     (t
      (let ((xwidget (decknix-webkit-fetch-session-for-origin (decknix-webkit-fetch-origin url))))
        (if (not xwidget)
            (progn
              (funcall write (decknix-webkit-fetch-error-json
                              "no-session" "no xwidget-webkit page is open on that origin"))
              'no-session)
          (decknix-webkit-fetch
           xwidget url
           :method (or (alist-get 'method request) "GET")
           :headers (mapcar (lambda (pair) (cons (symbol-name (car pair)) (cdr pair)))
                            (alist-get 'headers request))
           :body (alist-get 'body request)
           :timeout-ms (alist-get 'timeout_ms request)
           :callback write)
          'queued))))))

;;;###autoload
(defun decknix-webkit-session-open (url)
  "Show an xwidget-webkit session on URL's origin, so its sign-in can be done.
Reuses and reloads an existing session already on that origin.  A new
session is kept out of `xwidget-webkit-last-session-buffer', because
links opened elsewhere reuse that buffer and would navigate the signed-in
page away from its origin."
  (interactive "sURL: ")
  (unless (decknix-webkit-fetch-supported-p)
    (user-error "This Emacs was built without xwidget support"))
  (require 'xwidget)
  (let ((existing (decknix-webkit-fetch-session-for-origin (decknix-webkit-fetch-origin url)))
        (previous xwidget-webkit-last-session-buffer))
    (if existing
        (progn
          (pop-to-buffer (xwidget-buffer existing))
          (xwidget-webkit-goto-uri existing url))
      (xwidget-webkit-new-session url))
    (setq xwidget-webkit-last-session-buffer
          (and (buffer-live-p previous)
               (not (eq previous (current-buffer)))
               previous))))

(provide 'decknix-webkit-fetch)
;;; decknix-webkit-fetch.el ends here
