;;; decknix-agent-table-overlay-test.el --- Tests for table overlays -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-table-overlay "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests for the display-overlay layer: a table block gets a single
;; `display' overlay carrying the aligned (wide) or reflowed (narrow)
;; rendering, the underlying buffer text is preserved (so copy stays
;; raw), re-painting does not stack overlays, and prose gets none.

;;; Code:

(require 'ert)
(require 'decknix-test-helpers)
(require 'decknix-agent-table)
(require 'decknix-agent-table-overlay)

(defconst decknix-agent-table-overlay-test--input
  "| Name | Age | City |\n|---|---|---|\n| Alice | 30 | NYC |\n| Bob | 5 | LA |")

(defconst decknix-agent-table-overlay-test--aligned
  (concat "| Name  | Age | City |\n"
          "| ----- | --- | ---- |\n"
          "| Alice | 30  | NYC  |\n"
          "| Bob   | 5   | LA   |"))

(defmacro decknix-agent-table-overlay-test--with-buffer (&rest body)
  "Run BODY in a temp buffer holding intro/table/outro text."
  (declare (indent 0))
  `(with-temp-buffer
     (insert "Intro\n\n" decknix-agent-table-overlay-test--input "\n\nOutro")
     ,@body))

(ert-deftest decknix-agent-table-overlay/wide-aligns ()
  "A generous width yields one overlay whose display is the aligned table."
  (decknix-agent-table-overlay-test--with-buffer
    (let ((ovs (decknix-agent-table-overlay-region (point-min) (point-max) 200)))
      (should (= 1 (length ovs)))
      (should (string= decknix-agent-table-overlay-test--aligned
                       (overlay-get (car ovs) 'display)))
      (should (overlay-get (car ovs) 'decknix-agent-table)))))

(ert-deftest decknix-agent-table-overlay/preserves-underlying-text ()
  "The overlay leaves the raw markdown in the buffer (copy stays raw)."
  (decknix-agent-table-overlay-test--with-buffer
    (let ((ovs (decknix-agent-table-overlay-region (point-min) (point-max) 200)))
      (should (string= decknix-agent-table-overlay-test--input
                       (buffer-substring-no-properties
                        (overlay-start (car ovs)) (overlay-end (car ovs))))))))

(ert-deftest decknix-agent-table-overlay/narrow-reflows ()
  "A narrow width reflows the table into a bullet list in the display."
  (decknix-agent-table-overlay-test--with-buffer
    (let ((ovs (decknix-agent-table-overlay-region (point-min) (point-max) 10)))
      (should (= 1 (length ovs)))
      (should (string-prefix-p "• Alice" (overlay-get (car ovs) 'display))))))

(ert-deftest decknix-agent-table-overlay/repaint-does-not-stack ()
  "Re-painting clears prior decknix overlays so only one remains."
  (decknix-agent-table-overlay-test--with-buffer
    (decknix-agent-table-overlay-region (point-min) (point-max) 200)
    (decknix-agent-table-overlay-region (point-min) (point-max) 200)
    (should (= 1 (cl-count-if
                  (lambda (o) (overlay-get o 'decknix-agent-table))
                  (overlays-in (point-min) (point-max)))))))

(ert-deftest decknix-agent-table-overlay/prose-gets-none ()
  (with-temp-buffer
    (insert "just prose\nmore prose")
    (should (null (decknix-agent-table-overlay-region
                   (point-min) (point-max) 200)))))

(provide 'decknix-agent-table-overlay-test)
;;; decknix-agent-table-overlay-test.el ends here
