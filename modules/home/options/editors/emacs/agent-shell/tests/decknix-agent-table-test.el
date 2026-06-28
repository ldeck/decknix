;;; decknix-agent-table-test.el --- Tests for decknix-agent-table -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-table "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests pinning the pure GFM-table formatting core: row / separator
;; detection, cell splitting, parsing into a structured table, column
;; width computation, aligned rendering, narrow-buffer bullet reflow, and
;; the width-aware `format' dispatcher.  Also covers `transform-blocks',
;; which rewrites every table block embedded in a larger markdown string
;; while leaving non-table prose untouched (used by the copy-as-format
;; converters and the auto-overlay).

;;; Code:

(require 'ert)
(require 'decknix-test-helpers)
(require 'decknix-agent-table)

;; A canonical collapsed table the model might emit (cells trimmed, ragged).
(defconst decknix-agent-table-test--input
  "| Name | Age | City |\n|---|---|---|\n| Alice | 30 | NYC |\n| Bob | 5 | LA |")

(defconst decknix-agent-table-test--aligned
  (concat "| Name  | Age | City |\n"
          "| ----- | --- | ---- |\n"
          "| Alice | 30  | NYC  |\n"
          "| Bob   | 5   | LA   |"))

(defconst decknix-agent-table-test--reflow
  (concat "• Alice\n"
          "    - Age: 30\n"
          "    - City: NYC\n"
          "• Bob\n"
          "    - Age: 5\n"
          "    - City: LA"))

;; -- Detection ------------------------------------------------------

(ert-deftest decknix-agent-table/row-p ()
  "A pipe-bearing line is a row; prose is not."
  (should (decknix-agent-table-row-p "| a | b |"))
  (should (decknix-agent-table-row-p "a | b"))
  (should-not (decknix-agent-table-row-p "just prose"))
  (should-not (decknix-agent-table-row-p "")))

(ert-deftest decknix-agent-table/separator-p ()
  "Only the dashed delimiter line is a separator."
  (should (decknix-agent-table-separator-p "|---|---|"))
  (should (decknix-agent-table-separator-p "| :--- | ---: | :--: |"))
  (should-not (decknix-agent-table-separator-p "| Name | Age |"))
  (should-not (decknix-agent-table-separator-p "| Alice | 30 |")))

;; -- Splitting ------------------------------------------------------

(ert-deftest decknix-agent-table/split-row-trims-and-drops-edge-pipes ()
  "Cells are trimmed; optional leading/trailing pipes are dropped."
  (should (equal '("Name" "Age" "City")
                 (decknix-agent-table-split-row "| Name | Age | City |")))
  (should (equal '("Name" "Age" "City")
                 (decknix-agent-table-split-row "|Name|Age|City|")))
  (should (equal '("a" "b") (decknix-agent-table-split-row "a | b"))))

;; -- Parsing --------------------------------------------------------

(ert-deftest decknix-agent-table/parse-shapes-the-table ()
  "Parse yields headers, per-column align, and padded rows."
  (let ((tbl (decknix-agent-table-parse decknix-agent-table-test--input)))
    (should (equal '("Name" "Age" "City") (plist-get tbl :headers)))
    (should (equal '(default default default) (plist-get tbl :align)))
    (should (equal '(("Alice" "30" "NYC") ("Bob" "5" "LA"))
                   (plist-get tbl :rows)))))

(ert-deftest decknix-agent-table/parse-reads-alignment ()
  "Colon markers in the separator map to left/right/center."
  (let ((tbl (decknix-agent-table-parse
              "| a | b | c | d |\n| :--- | ---: | :--: | --- |\n| 1 | 2 | 3 | 4 |")))
    (should (equal '(left right center default) (plist-get tbl :align)))))

(ert-deftest decknix-agent-table/parse-pads-ragged-rows ()
  "A short data row is padded with empty cells to the header width."
  (let ((tbl (decknix-agent-table-parse
              "| a | b | c |\n|---|---|---|\n| 1 |")))
    (should (equal '(("1" "" "")) (plist-get tbl :rows)))))

(ert-deftest decknix-agent-table/parse-returns-nil-for-non-table ()
  "Prose, or a header with no separator, is not a table."
  (should-not (decknix-agent-table-parse "just some prose\nmore prose"))
  (should-not (decknix-agent-table-parse "| a | b |\n| 1 | 2 |")))

;; -- Widths ---------------------------------------------------------

(ert-deftest decknix-agent-table/column-widths ()
  "Each width is the max display width across header + data cells."
  (let ((tbl (decknix-agent-table-parse decknix-agent-table-test--input)))
    (should (equal '(5 3 4) (decknix-agent-table-column-widths tbl)))))

;; -- Aligned render -------------------------------------------------

(ert-deftest decknix-agent-table/render-aligned ()
  "Aligned render pads every column so pipes line up."
  (let ((tbl (decknix-agent-table-parse decknix-agent-table-test--input)))
    (should (null (decknix-test-render-snapshot
                   (decknix-agent-table-render-aligned tbl)
                   decknix-agent-table-test--aligned)))))

(ert-deftest decknix-agent-table/render-aligned-respects-alignment ()
  "Right / center alignment shift padding to the correct side."
  (let ((tbl (decknix-agent-table-parse
              "| k | v |\n| --- | ---: |\n| a | 1 |\n| bb | 22 |")))
    (should (null (decknix-test-render-snapshot
                   (decknix-agent-table-render-aligned tbl)
                   (concat "| k  |  v |\n"
                           "| -- | -: |\n"
                           "| a  |  1 |\n"
                           "| bb | 22 |"))))))

(ert-deftest decknix-agent-table/aligned-width-is-header-line-width ()
  "Aligned width equals the display width of the rendered header line."
  (let ((tbl (decknix-agent-table-parse decknix-agent-table-test--input)))
    (should (= 22 (decknix-agent-table-aligned-width tbl)))))

;; -- Reflow ---------------------------------------------------------

(ert-deftest decknix-agent-table/render-reflow ()
  "Narrow reflow emits a bullet per row with key/value sub-items."
  (let ((tbl (decknix-agent-table-parse decknix-agent-table-test--input)))
    (should (null (decknix-test-render-snapshot
                   (decknix-agent-table-render-reflow tbl)
                   decknix-agent-table-test--reflow)))))

(ert-deftest decknix-agent-table/render-reflow-skips-empty-values ()
  "Empty trailing cells produce no sub-item line."
  (let ((tbl (decknix-agent-table-parse
              "| a | b | c |\n|---|---|---|\n| 1 | | 3 |")))
    (should (null (decknix-test-render-snapshot
                   (decknix-agent-table-render-reflow tbl)
                   "• 1\n    - c: 3")))))

;; -- Dispatcher -----------------------------------------------------

(ert-deftest decknix-agent-table/format-wide-aligns ()
  "With no width (or a generous width) `format' aligns."
  (should (null (decknix-test-render-snapshot
                 (decknix-agent-table-format decknix-agent-table-test--input)
                 decknix-agent-table-test--aligned)))
  (should (null (decknix-test-render-snapshot
                 (decknix-agent-table-format decknix-agent-table-test--input 200)
                 decknix-agent-table-test--aligned))))

(ert-deftest decknix-agent-table/format-narrow-reflows ()
  "When the aligned table is wider than the target, `format' reflows."
  (should (null (decknix-test-render-snapshot
                 (decknix-agent-table-format decknix-agent-table-test--input 10)
                 decknix-agent-table-test--reflow))))

(ert-deftest decknix-agent-table/format-passthrough-non-table ()
  "Non-table text is returned unchanged."
  (should (string= "hello\nworld"
                   (decknix-agent-table-format "hello\nworld" 10))))

;; -- transform-blocks ----------------------------------------------

(ert-deftest decknix-agent-table/transform-blocks-rewrites-only-tables ()
  "Each embedded table block is replaced; surrounding prose is intact."
  (let ((text (concat "Intro line\n\n"
                      decknix-agent-table-test--input
                      "\n\nOutro line"))
        (out (concat "Intro line\n\n"
                     "TABLE"
                     "\n\nOutro line")))
    (should (string= out
                     (decknix-agent-table-transform-blocks
                      text (lambda (_block) "TABLE"))))))

;; -- block-bounds --------------------------------------------------

(ert-deftest decknix-agent-table/block-bounds-spans-the-table ()
  "Bounds at any row index cover the whole header..last-row run."
  (let ((lines (split-string
                (concat "Intro\n\n" decknix-agent-table-test--input "\n\nOutro")
                "\n")))
    ;; lines: 0 Intro, 1 "", 2 header, 3 sep, 4 row, 5 row, 6 "", 7 Outro
    (should (equal '(2 . 6) (decknix-agent-table-block-bounds lines 4)))
    (should (equal '(2 . 6) (decknix-agent-table-block-bounds lines 2)))))

(ert-deftest decknix-agent-table/block-bounds-nil-off-table ()
  "A non-row line (or a row run with no separator) yields nil."
  (let ((lines '("Intro" "| a | b |" "| 1 | 2 |")))
    (should-not (decknix-agent-table-block-bounds lines 0))
    (should-not (decknix-agent-table-block-bounds lines 1))))

(provide 'decknix-agent-table-test)
;;; decknix-agent-table-test.el ends here
