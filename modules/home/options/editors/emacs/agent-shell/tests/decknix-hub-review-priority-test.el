;;; decknix-hub-review-priority-test.el --- Tests for review priority -*- lexical-binding: t -*-

;;; Commentary:
;;
;; The point of these is not that the numbers are right -- they are a
;; judgement call -- but that the ORDERINGS they produce are the ones
;; intended, and that no weight silently swamps another.  Each test names
;; the comparison it defends.

;;; Code:

(require 'ert)
(require 'decknix-hub-review-priority)

(defun decknix-rp-test--item (&rest kv)
  "Build a feed item from plist KV."
  (let (alist)
    (while kv
      (push (cons (pop kv) (pop kv)) alist))
    (nreverse alist)))

(defun decknix-rp-test--p (item &optional status age)
  (decknix--hub-review-priority item status age))

;; --- ticket prefix extraction ---

(ert-deftest decknix-rp--prefix-parsing ()
  "The `ABC-123:' convention every repo here uses."
  (should (equal "HOT" (decknix--hub-review-ticket-prefix "HOT-239: log uncaught exceptions")))
  (should (equal "NYX" (decknix--hub-review-ticket-prefix "NYX-4287: Decide ACR grants")))
  (should (equal "EH" (decknix--hub-review-ticket-prefix "EH-12: tidy")))
  (should (equal "HOT" (decknix--hub-review-ticket-prefix "hot-1: lowercase still counts"))))

(ert-deftest decknix-rp--prefix-absent ()
  "A PR with no ticket key is feature-weight, not an error."
  (should-not (decknix--hub-review-ticket-prefix "Add the ctas variable group"))
  (should-not (decknix--hub-review-ticket-prefix nil))
  (should (= 0 (decknix--hub-review-workstream-score "Add the ctas variable group"))))

;; --- the workstream ordering you asked for ---

(ert-deftest decknix-rp--incident-beats-feature-beats-eh ()
  "Incident (HOT/PIR/DOS/ALR) > feature > EH, all else equal."
  (let ((hot (decknix-rp-test--p (decknix-rp-test--item 'title "HOT-1: x")))
        (feat (decknix-rp-test--p (decknix-rp-test--item 'title "NYX-1: x")))
        (eh (decknix-rp-test--p (decknix-rp-test--item 'title "EH-1: x"))))
    (should (> hot feat))
    (should (> feat eh))))

(ert-deftest decknix-rp--all-incident-prefixes-rank-together ()
  "HOT, PIR, DOS and ALR are one band, not a hierarchy."
  (let ((scores (mapcar (lambda (p)
                          (decknix-rp-test--p
                           (decknix-rp-test--item 'title (format "%s-1: x" p))))
                        '("HOT" "PIR" "DOS" "ALR"))))
    (should (= 1 (length (delete-dups (copy-sequence scores)))))))

;; --- engagement ordering ---

(ert-deftest decknix-rp--engagement-ladder ()
  "replies-to-me > needs-reply > re-requested > stale > mentioned > team."
  (let ((scores
         (mapcar (lambda (k) (decknix--hub-review-engagement-score
                              (decknix-rp-test--item k t)))
                 '(replies_to_me needs_reply re_requested
                                 review_stale mentioned team_requested))))
    (should (equal scores (sort (copy-sequence scores) #'>)))
    (should (= 6 (length (delete-dups (copy-sequence scores)))))))

(ert-deftest decknix-rp--engagement-takes-the-strongest-band-only ()
  "Bands do not accumulate.
An item that is replies_to_me AND team_requested scores as the former,
not the sum -- otherwise engagement would drift past the incident bonus
and invert the workstream ordering."
  (should (= decknix--hub-review-w-replies-to-me
             (decknix--hub-review-engagement-score
              (decknix-rp-test--item 'replies_to_me t 'team_requested t
                                     'needs_reply t 'mentioned t)))))

;; --- the cross-axis case that motivated a composite score ---

(ert-deftest decknix-rp--untouched-incident-beats-engaged-feature ()
  "A HOT PR nobody has touched outranks a feature PR waiting on a reply.
This is the case strict tiers could not express without doubling every
level, and it is why the incident bonus exceeds the whole engagement
range."
  (let ((hot-cold (decknix-rp-test--p
                   (decknix-rp-test--item 'title "HOT-1: x" 'team_requested t)))
        (feat-hot (decknix-rp-test--p
                   (decknix-rp-test--item 'title "NYX-1: x" 'replies_to_me t))))
    (should (> hot-cold feat-hot))))

;; --- status effects ---

(ert-deftest decknix-rp--gone-sinks-below-everything ()
  "Nothing about a PR matters once no review is wanted."
  (let ((gone (decknix-rp-test--p
               (decknix-rp-test--item 'title "HOT-1: x" 'replies_to_me t)
               'gone 14))
        (worst (decknix-rp-test--p
                (decknix-rp-test--item 'title "EH-1: x" 'draft t 'author_kind "bot"))))
    (should (< gone worst))))

(ert-deftest decknix-rp--answered-demotes-but-does-not-sink ()
  "An answered HOT PR still outranks an untouched feature PR.
A penalty, not a floor: someone else responding is a hint, not a fact
about whether the work matters."
  (should (> (decknix-rp-test--p (decknix-rp-test--item 'title "HOT-1: x") 'answered)
             (decknix-rp-test--p (decknix-rp-test--item 'title "NYX-1: x")))))

(ert-deftest decknix-rp--draft-and-bot-demote ()
  "Drafts and bot-authored PRs sort below equivalent human work."
  (let ((base (decknix-rp-test--item 'title "NYX-1: x")))
    (should (< (decknix-rp-test--p (append base '((draft . t)))) (decknix-rp-test--p base)))
    (should (< (decknix-rp-test--p (append base '((author_kind . "bot"))))
               (decknix-rp-test--p base)))))

;; --- age is a nudge, never a promotion ---

(ert-deftest decknix-rp--age-breaks-ties ()
  "Among equals, the one waiting longest goes first."
  (let ((old (decknix-rp-test--p (decknix-rp-test--item 'title "NYX-1: x") nil 9))
        (new (decknix-rp-test--p (decknix-rp-test--item 'title "NYX-1: x") nil 0)))
    (should (> old new))))

(ert-deftest decknix-rp--age-cannot-outrank-a-tier ()
  "A fortnight-old EH draft must not beat a HOT PR raised an hour ago.
The age cap exists precisely to keep waiting from becoming importance."
  (let ((old-eh (decknix-rp-test--p
                 (decknix-rp-test--item 'title "EH-1: x") nil 365))
        (fresh-hot (decknix-rp-test--p
                    (decknix-rp-test--item 'title "HOT-1: x") nil 0)))
    (should (> fresh-hot old-eh))))

(ert-deftest decknix-rp--age-is-capped-and-safe ()
  "Age saturates, and nonsense input contributes nothing."
  (should (= decknix--hub-review-age-cap (decknix--hub-review-age-score 999)))
  (should (= 0 (decknix--hub-review-age-score -5)))
  (should (= 0 (decknix--hub-review-age-score nil))))

;; --- json-false must not read as engagement ---

(ert-deftest decknix-rp--json-false-is-not-truthy ()
  "Every flag test requires `eq t'; a `:json-false' must not promote."
  (should (= decknix--hub-review-w-baseline
             (decknix--hub-review-engagement-score
              (decknix-rp-test--item 'replies_to_me :json-false
                                     'needs_reply :json-false
                                     'mentioned :json-false)))))

;; --- the explanation tracks the score ---

(ert-deftest decknix-rp--explain-mentions-the-total ()
  "The breakdown states the number it is explaining."
  (let* ((item (decknix-rp-test--item 'title "HOT-1: x" 'replies_to_me t))
         (n (decknix-rp-test--p item nil 3)))
    (should (string-match-p (number-to-string n)
                            (decknix--hub-review-priority-explain item nil 3)))))

(provide 'decknix-hub-review-priority-test)
;;; decknix-hub-review-priority-test.el ends here
