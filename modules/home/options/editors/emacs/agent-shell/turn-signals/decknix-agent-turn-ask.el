;;; decknix-agent-turn-ask.el --- What a turn's closing question expects -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, review

;;; Commentary:
;;
;; `decknix--agent-question-p' says THAT a turn ended on a question.  This
;; says what the question wants back, read from the same closing text:
;;
;;   - the review verdict a `/review-service-pr' plan presents, so a gate
;;     can be shown as "APPROVE, waiting on you" rather than "asking";
;;   - the reply it expects: a number from a `CHOOSE ONE' list, a word
;;     from a "(yes / edit / cancel)" hint, a plain yes or no, or free
;;     text;
;;   - whether the turn reports a review already on GitHub.
;;
;; All pure, over text the turn-signals capture already holds, so nothing
;; here reads a buffer, a file or the network.  Like the question test it
;; is heuristic, shaped by the closing turns of real review sessions; see
;; the fixtures in the tests.

;;; Code:

(require 'seq)
(require 'subr-x)

;; --- verdict -------------------------------------------------------------

(defconst decknix-agent-turn-ask--verdict-labelled-regexp
  "\\(?:[Vv]erdict\\|VERDICT\\)[^A-Za-z]\\{0,60\\}?\\(APPROVE\\|REQUEST[_ ]CHANGES\\|COMMENT\\)\\b"
  "A verdict named by its label: \"Verdict: APPROVE\", \"**Verdict:** APPROVE\",
or a \"PROPOSED VERDICT\" heading with the verdict on a line of its own.
The verdict itself must be upper case, so prose such as \"change the
verdict, or comment\" is not read as one.")

(defconst decknix-agent-turn-ask--verdict-bare-regexp
  "\\_<\\(APPROVE\\|REQUEST_CHANGES\\)\\_>"
  "A verdict named without its label, e.g. \"submit the APPROVE\".
`COMMENT' is left out: as a bare upper-case word it is too often a
heading (\"INLINE COMMENT\") to mean a verdict.")

(defun decknix-agent-turn-ask--last-match (regexp text)
  "Return group 1 of the LAST match of REGEXP in TEXT, or nil."
  (let ((case-fold-search nil) (start 0) found)
    (while (string-match regexp text start)
      (setq found (match-string 1 text)
            start (match-end 0)))
    found))

(defun decknix-agent-turn-ask-verdict (text)
  "Return the review verdict TEXT presents, or nil.

One of \"APPROVE\", \"REQUEST_CHANGES\" or \"COMMENT\".  The LAST one
wins: a plan revised after an `edit' restates its verdict lower down."
  (when (stringp text)
    (when-let* ((v (or (decknix-agent-turn-ask--last-match
                        decknix-agent-turn-ask--verdict-labelled-regexp text)
                       (decknix-agent-turn-ask--last-match
                        decknix-agent-turn-ask--verdict-bare-regexp text))))
      (replace-regexp-in-string " " "_" v))))

(defun decknix-agent-turn-ask-posted-p (text)
  "Non-nil when TEXT reports a review already submitted to GitHub.

The review's own URL is the marker: of 64 turns that followed a `yes' at
a real gate, the 58 that posted all linked `#pullrequestreview-N', and
the six that did not were each a revised plan put back to the gate."
  (and (stringp text)
       (string-match-p "/pull/[0-9]+#pullrequestreview-[0-9]+" text)
       t))

;; --- expected reply ------------------------------------------------------

(defconst decknix-agent-turn-ask--option-regexp
  "\\`[ \t]*\\(?:\\*\\*\\)?\\([1-9]\\)\\(?:\\*\\*\\)?[.)][ \t]+\\(.+?\\)[ \t]*\\'"
  "One numbered option line: \"1. yes  (submit)  [recommended]\".")

(defconst decknix-agent-turn-ask-trailing-lines 3
  "Non-option lines allowed after a numbered list for it still to close the turn.
Room for the \"Reply with the number or the name.\" line and a short
aside, but not for a list that was followed by more discussion.")

(defun decknix-agent-turn-ask--option-name (body)
  "Return the short name of an option BODY: \"yes\" from \"yes  (submit ...)\".
The text before the first em dash, spaced hyphen, parenthesis or run of
two spaces, the separators agents use between a name and its gloss."
  (let ((clean (replace-regexp-in-string "\\*\\*\\|`" "" body)))
    (string-trim
     (car (split-string clean "[ \t]+—\\|[ \t]+-[ \t]\\|[ \t]*(\\|[ \t]\\{2,\\}\\|[ \t]*\\["
                        nil)))))

(defun decknix-agent-turn-ask--option (line)
  "Return the option plist LINE describes, or nil."
  (when (string-match decknix-agent-turn-ask--option-regexp line)
    (let* ((n (string-to-number (match-string 1 line)))
           (body (match-string 2 line))
           (rec (and (string-match-p "[[(]recommended[])]" body) t))
           (label (string-trim
                   (replace-regexp-in-string
                    "[ \t]*[[(]recommended[])][ \t]*" " "
                    (replace-regexp-in-string "\\*\\*\\|`" "" body)))))
      (list :number n
            :name (decknix-agent-turn-ask--option-name body)
            :label label
            :recommended rec))))

(defun decknix-agent-turn-ask-options (text)
  "Return the numbered options TEXT closes on, in order, or nil.

Each is a plist (:number N :name NAME :label LABEL :recommended BOOL).
Only a list at the END counts -- at most
`decknix-agent-turn-ask-trailing-lines' other lines may follow it -- and
it must number 1, 2, 3 ... in order.  A numbered list in the middle of an
analysis is findings, not choices, and offering its numbers as replies
would send the agent something it never asked for."
  (when (stringp text)
    (let ((lines (reverse
                  (seq-remove (lambda (l) (string-match-p "\\`[ \t]*```" l))
                              (split-string text "\n"))))
          (trailing 0) (run nil) (done nil))
      (while (and lines (not done))
        (let* ((line (car lines))
               (opt (decknix-agent-turn-ask--option line))
               (blank (string-empty-p (string-trim line))))
          (cond
           (opt (push opt run))
           (blank nil)
           (run (setq done t))
           ((> (setq trailing (1+ trailing)) decknix-agent-turn-ask-trailing-lines)
            (setq done t lines nil))))
        (setq lines (cdr lines)))
      (when (and run
                 (seq-every-p #'identity
                              (seq-map-indexed
                               (lambda (o i) (= (plist-get o :number) (1+ i)))
                               run)))
        run))))

(defconst decknix-agent-turn-ask--words-regexp
  "[?][*_`]*[ \t]*[[(]\\([^])\n]*/[^])\n]*\\)[])][*_`]*[ \t]*$"
  "A question closed by its answers: \"Ready to submit? (yes / edit / cancel)\".")

(defun decknix-agent-turn-ask-words (text)
  "Return the answers a question in TEXT lists after its mark, or nil.
Lower-cased, in order: (\"yes\" \"edit\" \"cancel\").  The last such
question wins."
  (when (stringp text)
    (when-let* ((inside (let ((case-fold-search nil))
                          (decknix-agent-turn-ask--last-match
                           decknix-agent-turn-ask--words-regexp text))))
      (seq-remove #'string-empty-p
                  (mapcar (lambda (w) (downcase (string-trim w)))
                          (split-string inside "/"))))))

(defconst decknix-agent-turn-ask--yes-no-regexp
  (concat "\\`\\(?:[-*>#]+[ \t]*\\)?\\(?:\\*\\*\\)?"
          "\\(?:shall\\|should\\|want\\|ready\\|do\\|does\\|did\\|is\\|are\\|can\\|could"
          "\\|would\\|will\\|may\\|ok\\|okay\\|proceed\\|continue\\|go ahead\\|happy"
          "\\|push\\|merge\\|post\\|submit\\|approve\\|send\\)\\b")
  "Openings of a question that a plain yes or no answers.")

(defun decknix-agent-turn-ask--last-question-line (text)
  "Return the last line of TEXT ending on a question mark, trimmed, or nil."
  (car (last (seq-filter
              (lambda (l) (string-match-p "[?][*_`]*[ \t]*\\(?:[[(][^])\n]*[])]\\)?[*_`]*[ \t]*\\'" l))
              (mapcar #'string-trim (split-string text "\n"))))))

(defun decknix-agent-turn-ask-reply (text)
  "Return the kind of reply the question closing TEXT expects.

A plist with `:kind' one of:
  `numbered'  answer with a number; `:options' as from
              `decknix-agent-turn-ask-options'
  `words'     answer with one of `:words', listed after the question
  `yes-no'    a plain yes or no
  `open'      free text; no quick answer is offered
Numbered wins because a `CHOOSE ONE' block is the exact form the
workspace rules mandate for a choice.  Callers decide first whether TEXT
asks anything at all (`decknix--agent-question-p')."
  (let ((options (decknix-agent-turn-ask-options text))
        (words (decknix-agent-turn-ask-words text)))
    (cond
     (options (list :kind 'numbered :options options))
     ((and words (seq-every-p (lambda (w) (member w '("y" "n" "yes" "no"))) words))
      (list :kind 'yes-no))
     (words (list :kind 'words :words words))
     ((let* ((line (and (stringp text) (decknix-agent-turn-ask--last-question-line text)))
             ;; The question's own sentence: a paragraph often leads up to
             ;; it ("Looks like X changed.  Want me to re-review?").
             (q (and line (car (last (split-string line "[.!:;][ \t]+" t)))))
             (case-fold-search t))
        (and q (string-match-p decknix-agent-turn-ask--yes-no-regexp q)))
      (list :kind 'yes-no))
     (t (list :kind 'open)))))

(defun decknix-agent-turn-ask-reply-label (reply)
  "Return a short label for REPLY: \"1-3, rec 1\", \"yes/edit/cancel\", \"yes/no\"."
  (pcase (plist-get reply :kind)
    ('numbered
     (let* ((opts (plist-get reply :options))
            (rec (seq-find (lambda (o) (plist-get o :recommended)) opts)))
       (concat (if (= 1 (length opts)) "1" (format "1-%d" (length opts)))
               (if rec (format ", rec %d" (plist-get rec :number)) ""))))
    ('words (string-join (plist-get reply :words) "/"))
    ('yes-no "yes/no")
    (_ "free text")))

;; --- answering -----------------------------------------------------------

(defconst decknix-agent-turn-ask--affirm-regexp
  "\\`\\(?:y\\|yes\\|proceed\\|submit\\|approve\\|post\\|go\\|ok\\|okay\\|confirm\\|send\\|ship\\|lgtm\\)\\b"
  "Opening words of an answer, or an option name, that says go ahead.")

(defun decknix-agent-turn-ask-reply-intent (ask reply)
  "Return what REPLY, sent to a turn asking ASK, decided.

ASK is a plist from `decknix-agent-turn-ask'.  Returns `affirm' when the
answer (or the option a number picks) goes ahead -- the agent is now
acting on the plan -- `cancel' when it called the plan off, and `other'
for anything else: an edit, a question back, a free-text change."
  (let* ((text (downcase (string-trim (or reply ""))))
         (options (plist-get (plist-get ask :reply) :options))
         (picked (and (string-match "\\`\\([1-9]\\)\\b" text)
                      (seq-find (lambda (o)
                                  (= (plist-get o :number)
                                     (string-to-number (match-string 1 text))))
                                options)))
         (said (downcase (if picked (plist-get picked :name) text)))
         (case-fold-search t))
    (cond
     ((string-match-p decknix-agent-turn-ask--affirm-regexp said) 'affirm)
     ((string-match-p "\\`\\(?:cancel\\|no\\|n\\|abort\\|stop\\|hold\\)\\b" said) 'cancel)
     (t 'other))))

(defun decknix-agent-turn-ask-quick-reply (ask key)
  "Return what pressing KEY should send to a turn asking ASK.

KEY is `yes' or a digit 1-9.  Returns (:text TEXT :label LABEL) to send,
or (:error MESSAGE) saying why that key does not answer this question.
Strict on purpose: these answers post reviews, so a key that does not
match what was asked is refused rather than interpreted."
  (let* ((reply (plist-get ask :reply))
         (kind (plist-get reply :kind)))
    (cond
     ((null ask) (list :error "not asking anything"))
     ((eq key 'yes)
      (cond
       ((eq kind 'yes-no) (list :text "yes" :label "yes"))
       ((and (eq kind 'words) (member "yes" (plist-get reply :words)))
        (list :text "yes" :label "yes"))
       ((eq kind 'numbered)
        (list :error (format "wants a number (%s); press the digit"
                             (decknix-agent-turn-ask-reply-label reply))))
       (t (list :error "wants a free-text answer; go to the session"))))
     ((integerp key)
      (let ((opt (and (eq kind 'numbered)
                      (seq-find (lambda (o) (= key (plist-get o :number)))
                                (plist-get reply :options)))))
        (cond
         (opt (list :text (number-to-string key) :label (plist-get opt :label)))
         ((eq kind 'numbered)
          (list :error (format "no option %d (%s)" key
                               (decknix-agent-turn-ask-reply-label reply))))
         (t (list :error (format "not a numbered choice (reply: %s)"
                                 (decknix-agent-turn-ask-reply-label reply)))))))
     (t (list :error "unknown reply key")))))

(provide 'decknix-agent-turn-ask)
;;; decknix-agent-turn-ask.el ends here
