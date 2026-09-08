;;; decknix-auto-review-group-test.el --- Tests for grouped dispatch -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Specification tests for `decknix-auto-review-group-plan'.
;;
;; Auto-review dispatched per item, so five dependabot bumps on one
;; service became five buffers, five brokers and five agents, each
;; reviewing one bump in ignorance of the other four.  Grouping is what
;; makes sequencing, conflict-detection and combined fixes possible at
;; all; none of them are achievable by five sessions that do not know
;; about each other.

;;; Code:

(require 'ert)
(require 'decknix-auto-review)

(defun decknix-arg-test--item (repo number &optional author title)
  (list (cons 'repo repo) (cons 'number number)
        (cons 'author (or author "dependabot[bot]"))
        (cons 'title (or title (format "bump thing to %s" number)))))

;; --- bots group by repo ---

(ert-deftest decknix-arg--bots-in-one-repo-become-one-unit ()
  "Five bumps on one service dispatch as a single session."
  (let* ((entries (mapcar (lambda (n) (cons 'ship (decknix-arg-test--item "UpsideRealty/upside" n)))
                          '(1 2 3 4 5)))
         (plan (decknix-auto-review-group-plan entries)))
    (should (= 1 (length plan)))
    (should (equal 'ship (nth 0 (car plan))))
    (should (equal "upside" (nth 1 (car plan))))
    (should (= 5 (length (nth 3 (car plan)))))))

(ert-deftest decknix-arg--different-repos-stay-separate ()
  "Grouping is per service; two repos are two sessions."
  (let* ((entries (list (cons 'ship (decknix-arg-test--item "org/a" 1))
                        (cons 'ship (decknix-arg-test--item "org/b" 2))))
         (plan (decknix-auto-review-group-plan entries)))
    (should (= 2 (length plan)))))

(ert-deftest decknix-arg--different-bots-do-not-merge ()
  "Same repo, different bot author, different session.
`author_kind' is `bot' for several authors and the ship command is
dependabot-shaped, so folding a renovate PR in with dependabot ones
would hand one agent a sequence it cannot coherently run."
  (let* ((entries (list (cons 'ship (decknix-arg-test--item "org/a" 1 "dependabot[bot]"))
                        (cons 'ship (decknix-arg-test--item "org/a" 2 "renovate[bot]"))))
         (plan (decknix-auto-review-group-plan entries)))
    (should (= 2 (length plan)))))

;; --- humans are never grouped ---

(ert-deftest decknix-arg--human-reviews-never-group ()
  "Two human PRs on one repo stay two sessions.
They are individually authored and individually argued with; folding
them would hide exactly the reviews that most need reading."
  (let* ((entries (list (cons 'review (decknix-arg-test--item "org/a" 1 "alice"))
                        (cons 'review (decknix-arg-test--item "org/a" 2 "alice"))))
         (plan (decknix-auto-review-group-plan entries)))
    (should (= 2 (length plan)))
    (should (seq-every-p (lambda (u) (= 1 (length (nth 3 u)))) plan))))

(ert-deftest decknix-arg--humans-and-bots-coexist ()
  "A mixed tick yields one bot unit plus one unit per human PR."
  (let* ((entries (list (cons 'ship (decknix-arg-test--item "org/a" 1))
                        (cons 'ship (decknix-arg-test--item "org/a" 2))
                        (cons 'review (decknix-arg-test--item "org/a" 3 "alice"))))
         (plan (decknix-auto-review-group-plan entries)))
    (should (= 2 (length plan)))
    (should (= 1 (length (seq-filter (lambda (u) (eq 'ship (nth 0 u))) plan))))))

;; --- ordering ---

(ert-deftest decknix-arg--members-ordered-by-priority ()
  "Within a group, highest priority first, so sequencing starts there."
  (let* ((entries (mapcar (lambda (n) (cons 'ship (decknix-arg-test--item "org/a" n)))
                          '(1 2 3)))
         (pri (lambda (item) (alist-get 'number item)))
         (plan (decknix-auto-review-group-plan entries pri)))
    (should (equal '(3 2 1)
                   (mapcar (lambda (i) (alist-get 'number i)) (nth 3 (car plan)))))))

(ert-deftest decknix-arg--units-ordered-by-strongest-member ()
  "One urgent bump lifts its whole group rather than being buried."
  (let* ((entries (list (cons 'ship (decknix-arg-test--item "org/low" 1))
                        (cons 'ship (decknix-arg-test--item "org/high" 9))))
         (pri (lambda (item) (alist-get 'number item)))
         (plan (decknix-auto-review-group-plan entries pri)))
    (should (equal "high" (nth 1 (car plan))))))

;; --- degenerate input ---

(ert-deftest decknix-arg--empty-plan ()
  "No eligible entries yields no units, not an error."
  (should-not (decknix-auto-review-group-plan nil))
  (should-not (decknix-auto-review-group-plan nil #'identity)))

(provide 'decknix-auto-review-group-test)
;;; decknix-auto-review-group-test.el ends here
