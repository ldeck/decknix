;;; decknix-review-board-columns-test.el --- Review board column cells -*- lexical-binding: t -*-

;;; Code:

(require 'ert)
(require 'decknix-review-board-columns)

(ert-deftest decknix-rbc--author-short-with-a-bot-marker ()
  (should (equal "dependabot⚙" (decknix-review-board-columns-author "dependabot[bot]" "bot")))
  (should (equal "renovate⚙" (decknix-review-board-columns-author "renovate-bot" "bot")))
  (should (equal "jo" (decknix-review-board-columns-author "jo" "human")))
  (should (= decknix-review-board-columns-author-width (string-width
                 (decknix-review-board-columns-author "a-very-long-login-name" "human"))))
  (should (equal "" (decknix-review-board-columns-author nil nil))))

(ert-deftest decknix-rbc--author-bot-from-the-login-alone ()
  "A feed without `author_kind' still marks a `[bot]' login."
  (should (string-suffix-p "⚙" (decknix-review-board-columns-author "github-actions[bot]" nil))))

(ert-deftest decknix-rbc--age-is-pr-age-then-quiet-time ()
  (let ((now (float-time (date-to-time "2026-11-25T12:00:00Z"))))
    (should (equal "3d/2h" (decknix-review-board-columns-age
                            "2026-11-22T12:00:00Z" "2026-11-25T10:00:00Z" now)))
    (should (equal "3w/now" (decknix-review-board-columns-age
                             "2026-11-01T12:00:00Z" (- now 5) now)))
    (should (equal "-/-" (decknix-review-board-columns-age nil nil now)))))

(ert-deftest decknix-rbc--ci-glyph-and-rank ()
  (should (equal '("✓" . 3) (decknix-review-board-columns-ci '((ci (status . "pass"))))))
  (should (equal '("✗" . 0) (decknix-review-board-columns-ci '((ci (status . "fail"))))))
  (should (equal '("◐" . 2) (decknix-review-board-columns-ci '((ci (status . "running"))))))
  (should (equal '("·" . 4) (decknix-review-board-columns-ci '((ci (status . ""))))))
  (should (equal '("·" . 4) (decknix-review-board-columns-ci nil))))

(ert-deftest decknix-rbc--my-prior-review ()
  (should (equal '("A" . 3) (decknix-review-board-columns-my-review '((my_review . "APPROVED")))))
  (should (equal '("CR" . 1) (decknix-review-board-columns-my-review
                              '((my_review . "CHANGES_REQUESTED")))))
  (should (equal '("" . 4) (decknix-review-board-columns-my-review '((my_review))))))

(ert-deftest decknix-rbc--threads-human-then-bot ()
  (should (equal "h2 b1" (decknix-review-board-columns-threads
                          '((human_unresolved . 2) (bot_unresolved . 1)))))
  (should (equal "b3" (decknix-review-board-columns-threads
                       '((human_unresolved . 0) (bot_unresolved . 3)))))
  (should (equal "" (decknix-review-board-columns-threads nil))))

(ert-deftest decknix-rbc--title-width-fits-the-window ()
  "The title takes what is left, within bounds."
  (should (= 60 (decknix-review-board-columns-title-width 400)))
  (should (= 12 (decknix-review-board-columns-title-width 80)))
  (should (= (- 140 decknix-review-board-columns-fixed-width
                decknix-review-board-columns-phase-width)
             (decknix-review-board-columns-title-width 140))))

(ert-deftest decknix-rbc--cell-is-exactly-its-width ()
  (should (= 8 (string-width (decknix-review-board-columns-cell "abc" 8))))
  (should (= 8 (string-width (decknix-review-board-columns-cell "abcdefghijkl" 8))))
  (should (string-suffix-p "…" (decknix-review-board-columns-cell "abcdefghijkl" 8))))

(provide 'decknix-review-board-columns-test)
;;; decknix-review-board-columns-test.el ends here
