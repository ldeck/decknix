;;; decknix-agent-table.el --- GFM table alignment + narrow reflow -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, markdown, table

;;; Commentary:
;;
;; Pure, side-effect-free formatting core for GFM (pipe) tables.  The
;; agent emits collapsed, single-space tables that read poorly in the
;; comint buffer; this layer parses such a block and re-renders it either
;; aligned (columns padded so pipes line up) or, when the aligned width
;; would exceed the available view, reflowed into a per-row bullet block
;; with key/value sub-items.
;;
;; Everything here is a pure string transform so it can be ERT-tested and
;; shared by three consumers: the on-demand reformat command, the
;; copy-as-format converters, and the auto-overlay render hook (all wired
;; in the heredoc per AGENTS.md Rule 2).

;;; Code:

(require 'cl-lib)
(require 'subr-x)

;; -- Detection ------------------------------------------------------

(defun decknix-agent-table-row-p (line)
  "Return non-nil when LINE looks like a markdown table row (has a pipe)."
  (let ((s (string-trim line)))
    (and (not (string-empty-p s))
         (string-search "|" s))))

(defun decknix-agent-table-separator-p (line)
  "Return non-nil when LINE is a GFM delimiter row (dashes/colons only)."
  (let ((cells (decknix-agent-table-split-row line)))
    (and cells
         (cl-every (lambda (c) (string-match-p "\\`:?-+:?\\'" c)) cells))))

;; -- Splitting ------------------------------------------------------

(defun decknix-agent-table-split-row (line)
  "Split LINE into trimmed cell strings, dropping optional edge pipes."
  (let ((s (string-trim line)))
    (when (string-prefix-p "|" s) (setq s (substring s 1)))
    (when (string-suffix-p "|" s) (setq s (substring s 0 (1- (length s)))))
    (mapcar #'string-trim (split-string s "|"))))

;; -- Parsing --------------------------------------------------------

(defun decknix-agent-table--cell-align (cell)
  "Map a separator CELL's colon markers to an alignment symbol."
  (let ((l (string-prefix-p ":" cell))
        (r (string-suffix-p ":" cell)))
    (cond ((and l r) 'center) (r 'right) (l 'left) (t 'default))))

(defun decknix-agent-table--fit (lst n fill)
  "Pad LST with FILL or truncate it to length N."
  (let ((len (length lst)))
    (cond ((= len n) lst)
          ((< len n) (append lst (make-list (- n len) fill)))
          (t (cl-subseq lst 0 n)))))

(defun decknix-agent-table-parse (text)
  "Parse TEXT as a GFM table; return a plist or nil when not a table.
The plist has :headers (list of strings), :align (list of
left/right/center/default), and :rows (list of cell-string lists,
padded/truncated to the header column count)."
  (let ((lines (cl-remove-if (lambda (l) (string-empty-p (string-trim l)))
                             (split-string (string-trim text) "\n"))))
    (when (>= (length lines) 2)
      (let ((h (nth 0 lines)) (sep (nth 1 lines)))
        (when (and (decknix-agent-table-row-p h)
                   (not (decknix-agent-table-separator-p h))
                   (decknix-agent-table-separator-p sep))
          (let* ((headers (decknix-agent-table-split-row h))
                 (ncols (length headers))
                 (align (decknix-agent-table--fit
                         (mapcar #'decknix-agent-table--cell-align
                                 (decknix-agent-table-split-row sep))
                         ncols 'default))
                 (data (cl-remove-if-not #'decknix-agent-table-row-p
                                         (nthcdr 2 lines)))
                 (rows (mapcar (lambda (r)
                                 (decknix-agent-table--fit
                                  (decknix-agent-table-split-row r) ncols ""))
                               data)))
            (list :headers headers :align align :rows rows)))))))

;; -- Widths + cell padding -----------------------------------------

(defun decknix-agent-table-column-widths (tbl)
  "Return the max display width per column for parsed table TBL."
  (let* ((headers (plist-get tbl :headers))
         (n (length headers))
         (widths (mapcar #'string-width headers)))
    (dolist (r (plist-get tbl :rows))
      (dotimes (i n)
        (let ((w (string-width (or (nth i r) ""))))
          (when (> w (nth i widths)) (setf (nth i widths) w)))))
    widths))

(defun decknix-agent-table--pad-cell (text width align)
  "Pad TEXT to WIDTH display columns honouring ALIGN."
  (let* ((s (or text "")) (n (max 0 (- width (string-width s)))))
    (pcase align
      ('right (concat (make-string n ?\s) s))
      ('center (let ((l (/ n 2))) (concat (make-string l ?\s) s
                                          (make-string (- n l) ?\s))))
      (_ (concat s (make-string n ?\s))))))

(defun decknix-agent-table--row-line (cells widths align)
  "Render CELLS as a padded `| ... |' line given WIDTHS and ALIGN."
  (concat "|"
          (mapconcat
           (lambda (i)
             (format " %s " (decknix-agent-table--pad-cell
                             (nth i cells) (nth i widths) (nth i align))))
           (number-sequence 0 (1- (length widths))) "|")
          "|"))

(defun decknix-agent-table--sep-segment (width align)
  "Render the dash/colon separator segment for WIDTH and ALIGN."
  (pcase align
    ('left (concat ":" (make-string (max 1 (1- width)) ?-)))
    ('right (concat (make-string (max 1 (1- width)) ?-) ":"))
    ('center (concat ":" (make-string (max 1 (- width 2)) ?-) ":"))
    (_ (make-string (max 1 width) ?-))))

;; -- Renderers ------------------------------------------------------

(defun decknix-agent-table-render-aligned (tbl)
  "Render parsed table TBL as an aligned GFM table string."
  (let* ((headers (plist-get tbl :headers))
         (align (plist-get tbl :align))
         (widths (decknix-agent-table-column-widths tbl))
         (idxs (number-sequence 0 (1- (length widths))))
         (hl (decknix-agent-table--row-line headers widths align))
         (sl (concat "|" (mapconcat
                          (lambda (i)
                            (format " %s " (decknix-agent-table--sep-segment
                                            (nth i widths) (nth i align))))
                          idxs "|") "|"))
         (dls (mapcar (lambda (r) (decknix-agent-table--row-line r widths align))
                      (plist-get tbl :rows))))
    (mapconcat #'identity (append (list hl sl) dls) "\n")))

(defun decknix-agent-table-aligned-width (tbl)
  "Return the display width of TBL's aligned header line."
  (string-width (decknix-agent-table--row-line
                 (plist-get tbl :headers)
                 (decknix-agent-table-column-widths tbl)
                 (plist-get tbl :align))))

(defun decknix-agent-table-render-reflow (tbl)
  "Render TBL as a per-row bullet block with key/value sub-items.
The first column is the bullet title; remaining non-empty columns
become indented `- Header: value' lines."
  (let* ((headers (plist-get tbl :headers))
         (n (length headers))
         (out '()))
    (dolist (r (plist-get tbl :rows))
      (push (concat "• " (or (nth 0 r) "")) out)
      (dotimes (i n)
        (when (> i 0)
          (let ((v (or (nth i r) "")))
            (unless (string-empty-p v)
              (push (format "    - %s: %s" (nth i headers) v) out))))))
    (mapconcat #'identity (nreverse out) "\n")))

;; -- Dispatcher + block scan ---------------------------------------

(defun decknix-agent-table-format (text &optional target-width)
  "Format TEXT: aligned, or reflowed when wider than TARGET-WIDTH.
Returns TEXT unchanged when it is not a table.  With TARGET-WIDTH nil
the result is always aligned."
  (let ((tbl (decknix-agent-table-parse text)))
    (cond ((not tbl) text)
          ((and target-width
                (> (decknix-agent-table-aligned-width tbl) target-width))
           (decknix-agent-table-render-reflow tbl))
          (t (decknix-agent-table-render-aligned tbl)))))

(defun decknix-agent-table-block-bounds (lines idx)
  "Return (START . END) line indices of the table block covering IDX.
END is exclusive.  A block is the maximal run of row lines containing
IDX; nil unless that run holds a separator (i.e. is a real table)."
  (when (and (>= idx 0) (< idx (length lines))
             (decknix-agent-table-row-p (nth idx lines)))
    (let ((start idx) (end (1+ idx)))
      (while (and (> start 0)
                  (decknix-agent-table-row-p (nth (1- start) lines)))
        (setq start (1- start)))
      (while (and (< end (length lines))
                  (decknix-agent-table-row-p (nth end lines)))
        (setq end (1+ end)))
      (when (cl-some (lambda (k) (decknix-agent-table-separator-p (nth k lines)))
                     (number-sequence start (1- end)))
        (cons start end)))))

(defun decknix-agent-table-block-offsets (text)
  "Return a list of (START . END) character offsets of table blocks in TEXT.
START is the offset of the block's first character; END is exclusive and
stops at the end of the last table row (excluding its trailing newline).
Offsets are 0-based into TEXT, so a consumer can map them to buffer
positions with (+ region-start OFFSET)."
  (let* ((lines (split-string text "\n"))
         (n (length lines)) (i 0) (pos 0) (starts (make-vector n 0))
         (out '()))
    (dotimes (k n)
      (aset starts k pos)
      (setq pos (+ pos (length (nth k lines)) 1)))
    (while (< i n)
      (let ((next (and (< (1+ i) n) (nth (1+ i) lines))))
        (if (and (decknix-agent-table-row-p (nth i lines))
                 (not (decknix-agent-table-separator-p (nth i lines)))
                 next (decknix-agent-table-separator-p next))
            (let ((j (+ i 2)))
              (while (and (< j n)
                          (decknix-agent-table-row-p (nth j lines))
                          (not (decknix-agent-table-separator-p (nth j lines))))
                (setq j (1+ j)))
              (push (cons (aref starts i)
                          (+ (aref starts (1- j)) (length (nth (1- j) lines))))
                    out)
              (setq i j))
          (setq i (1+ i)))))
    (nreverse out)))

(defun decknix-agent-table-transform-blocks (text fn)
  "Replace every GFM table block in TEXT with (funcall FN block-text).
Non-table lines are preserved verbatim.  A block is a header row, a
separator row, and the contiguous data rows that follow."
  (let* ((lines (split-string text "\n"))
         (n (length lines)) (i 0) (out '()))
    (while (< i n)
      (let ((line (nth i lines))
            (next (and (< (1+ i) n) (nth (1+ i) lines))))
        (if (and (decknix-agent-table-row-p line)
                 (not (decknix-agent-table-separator-p line))
                 next (decknix-agent-table-separator-p next))
            (let ((j (+ i 2)))
              (while (and (< j n)
                          (decknix-agent-table-row-p (nth j lines))
                          (not (decknix-agent-table-separator-p (nth j lines))))
                (setq j (1+ j)))
              (push (funcall fn (mapconcat #'identity (cl-subseq lines i j) "\n"))
                    out)
              (setq i j))
          (push line out)
          (setq i (1+ i)))))
    (mapconcat #'identity (nreverse out) "\n")))

(provide 'decknix-agent-table)
;;; decknix-agent-table.el ends here
