;;; decknix-webkit-page.el --- xwidget-webkit page-text + find bridge -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: decknix, xwidget, webkit, search

;;; Commentary:
;;
;; Two thin JS-bridge helpers and a shared search history defvar
;; carved out of `decknix-agent-shell-workspace' (workspace-bulk).
;; The interactive `decknix-webkit-consult-line' command stays in
;; workspace-bulk because it wires the consult UI and is keymap-
;; bound to the WebKit major-mode there -- both heredoc-side
;; concerns per AGENTS.md Rule 2.
;;
;;   `decknix--webkit-search-history'  history list, shared by
;;                                     consult-line and any other
;;                                     interactive entry point
;;   `decknix--webkit-page-text'       innerText of the current
;;                                     xwidget-webkit page (string
;;                                     or nil if empty / no session)
;;   `decknix--webkit-find-in-page'    `window.find' bridge that
;;                                     scrolls + highlights the
;;                                     match natively in the page
;;   `decknix--webkit-paste-script'    pure JS builder that returns
;;                                     the IIFE for inserting TEXT
;;                                     into the page's focused
;;                                     <input>/<textarea>/contenteditable
;;                                     (nil for nil/empty/non-string)
;;   `decknix--webkit-paste-text'      bridge wrapper that runs the
;;                                     paste IIFE in the current
;;                                     xwidget-webkit session
;;
;; The helpers safely no-op when there is no current xwidget-webkit
;; session so the consult `:state' callback can call them on any
;; preview event without checking first.

;;; Code:

(require 'cl-lib)
(require 'json)

;; xwidget-webkit ships with Emacs 29 but is loaded lazily; the
;; calls below all use `ignore-errors' so this module loads cleanly
;; on a build that wasn't compiled with xwidget support.
(declare-function xwidget-webkit-current-session "xwidget")
(declare-function xwidget-webkit-execute-script "xwidget" (xwidget script))
(declare-function xwidget-webkit-execute-script-rv "xwidget"
                  (xwidget script &optional default))

(defvar decknix--webkit-search-history nil
  "History list for `decknix-webkit-consult-line'.
Shared with any future interactive find-in-page entry points so a
single MRU walks across all of them.")

(defun decknix--webkit-page-text ()
  "Return innerText of the current xwidget-webkit page, or nil if empty."
  (let* ((session (ignore-errors (xwidget-webkit-current-session)))
         (raw (and session
                   (ignore-errors
                     (xwidget-webkit-execute-script-rv
                      session
                      "document.body && document.body.innerText")))))
    (and (stringp raw) (not (string-empty-p raw)) raw)))

(defun decknix--webkit-find-in-page (needle)
  "Scroll the current xwidget-webkit page to NEEDLE and highlight it.
Uses `window.find' which natively scrolls the match into view and
highlights it via the browser's selection."
  (when (and needle (stringp needle) (not (string-empty-p needle)))
    (let ((session (ignore-errors (xwidget-webkit-current-session))))
      (when session
        (xwidget-webkit-execute-script
         session
         (format
          "(function(){try{window.getSelection().removeAllRanges();window.find(%s,false,false,true,false,false,false);}catch(e){}})()"
          (json-encode-string needle)))))))

(defun decknix--webkit-paste-script (text)
  "Return a JS IIFE string that inserts TEXT into the page's focused field.
Returns nil for nil, empty, or non-string TEXT.

The script targets `document.activeElement' and inserts via
`document.execCommand(\\='insertText\\=', false, TEXT)' so the page's
own input-event listeners (React, Vue, etc.) observe the change.
Falls back to a manual `value' assignment + `input' event dispatch
when `execCommand' returns false (rare; mostly Shadow-DOM custom
elements).  Works for `<input>', `<textarea>', and any element
where `isContentEditable' is true.

Returns false from the JS side if no editable element is focused;
the bridge wrapper does not surface that to the user (the page is
the source of truth for which fields can accept text)."
  (when (and text (stringp text) (not (string-empty-p text)))
    (format
     "(function(){try{var el=document.activeElement;if(!el)return false;var t=(el.tagName||'').toLowerCase();var editable=(t==='input'||t==='textarea'||el.isContentEditable);if(!editable)return false;var s=%s;var ok=false;try{ok=document.execCommand('insertText',false,s);}catch(e){ok=false;}if(!ok){try{if(t==='input'||t==='textarea'){var p=el.selectionStart,q=el.selectionEnd,v=el.value||'';el.value=v.slice(0,p)+s+v.slice(q);el.selectionStart=el.selectionEnd=p+s.length;}else{el.textContent=(el.textContent||'')+s;}el.dispatchEvent(new Event('input',{bubbles:true}));ok=true;}catch(e){ok=false;}}return ok;}catch(e){return false;}})()"
     (json-encode-string text))))

(defun decknix--webkit-paste-text (text)
  "Insert TEXT into the focused input field of the current xwidget-webkit page.
No-op when TEXT is nil/empty/non-string or when there is no current
xwidget-webkit session.  See `decknix--webkit-paste-script' for the
DOM contract."
  (let ((script (decknix--webkit-paste-script text)))
    (when script
      (let ((session (ignore-errors (xwidget-webkit-current-session))))
        (when session
          (xwidget-webkit-execute-script session script))))))

(provide 'decknix-webkit-page)
;;; decknix-webkit-page.el ends here
