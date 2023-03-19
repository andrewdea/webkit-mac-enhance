;;; webkit-mac-enhance.el --- Fixes and functionalities for xwidget-webkit -*- lexical-binding: t; -*-

;; Copyright (C) 2022  Andrew De Angelis

;; Author: Andrew De Angelis <bobodeangelis@gmail.com>
;; Maintainer: Andrew De Angelis <bobodeangelis@gmail.com>
;; URL: https://github.com/andyjda/webkit-mac-enhance
;; Version: 0.0.1
;; Package-Requires: ((emacs "25.1"))
;; Keywords: comm

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License Version 3,
;; as published by the Free Software Foundation.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; License:

;; You can redistribute this program and/or modify it under the terms
;; of the GNU General Public License version 3.

;;; Commentary:
;; This package is aimed at fixing temporary issues in the xwidget-webkit
;; feature for the MacOS distribution of Emacs.
;;
;; On MacOS, the xwidget-webkit feature is functional, but a couple of features
;; lag behind the Linux distribution: mainly the History and Search features.
;; This package provides a temporary fix at the Emacs-Lisp layer: by implementing
;; a separate "Web History" component, keeping track of visited websites
;; within a csv file, and by reverting the "Search" feature to an earlier, simpler
;; implementation that allows us to search within a web page.
;;
;; A couple small additional features are provided:
;; 1) the ability to easily switch between
;; an "eww" and a "webkit" view of the same page.  The intended use-case is
;; situations where the user needs to navigate and manipulate a lot of text:
;; in these cases, the xwidget-webkit view can be annoying, whereas the
;; eww view allows us to use all our Emacs keybindings.
;; 2) the `websearch' function, allowing users to quickly open a webkit page
;; querying their specified `default-search-engine'
;;
;; As stated above, this package is intended to be temporary: the long-term
;; solution will be to address these issues in the Emacs source code, mostly at
;; the C and Objective-C level and, where not possible, in the Emacs-Lisp layer.


;;; Code:
(eval-when-compile (require 'xwidget))
(eval-when-compile (require 'eww))
(eval-when-compile (require 'csv-mode))
;; (eval-when-compile (require 'cl-seq))

(defgroup webkit-mac-enhance nil
  "Additional functionalities and fixes for xwidget-webkit."
  :group 'widgets)

(declare-function eww-current-url "eww.el")
(declare-function xwidget-webkit-current-url "xwidget.el")
(declare-function xwidget-webkit-current-session "xwidget.el")
(declare-function xwidget-webkit-buffer-kill "xwidget.el")
(declare-function xwidget-webkit-bookmark-make-record "xwidget.el")
(declare-function csv-mode "csv-mode.el")

;;; web search
(defcustom default-search-engine "duckduckgo.com"
  "The default search engine to use when browsing with xwidget-webkit"
  :group 'webkit-mac-enhance
  :type 'string)
;; (defcustom default-search-engine "search.brave.com"
;;   "The default search engine to use when browsing with xwidget-webkit")

;;;###autoload
(defun websearch (&optional new-session)
  "Prompt for a string to search for using `default-search-engine'.
Build a query string and run `xwidget-webkit-browse-url'
with the resulting url, and the optional NEW-SESSION argument"
  (interactive "P")
  (let ((url
	 (thread-last
	   (read-from-minibuffer
	    (format "use %s to search: " default-search-engine))
	   (url-hexify-string)
	   (concat "https://" default-search-engine "/search?q="))))
    (message "opening xwidget-webkit with this: %s" url)
    (xwidget-webkit-browse-url url new-session)))

;;; eww integration

;; toggling between eww and xwidget was an important feature
;; when search was broken in xwidget.
;; Now that it works fine (see section above)
;; it's not as needed, but is still a small nice-to-have,
;; as the eww view would allows us to navigate text using
;; all our usual Emacs key bindings
(defun eww-this ()
  "Open a new eww buffer with `my-current-url'.
This assumes that an xwidget session is currently open.
If it's not, `my-current-url' throws an error"
  (interactive)
  (eww-browse-url (xwidget-webkit-current-url)))

(defun my-xwidget-browse (&optional new-session)
  "From a `eww' session, open an xwidget session with the current url.
Use `xwidget-webkit-browse-url' with `eww-current-url' and NEW-SESSION"
  (interactive "P")
  (let ((url (eww-current-url)))
    (xwidget-webkit-browse-url url new-session)))

(advice-add 'eww-mode :after
	    (lambda ()
	      (define-key eww-mode-map "x" #'my-xwidget-browse)))

;;; web history
(defcustom web-history-file (concat user-emacs-directory "custom/web_history.csv")
  "Where to store our xwidget-webkit browsing history."
  :group 'webkit-mac-enhance
  :type 'string)

(defcustom web-history-file-header "day,time,title,url\n"
  "First row in our xwidget-webkit browsing history."
  :group 'webkit-mac-enhance
  :type 'string)

(defcustom web-history-file-session-separator
  "__________,__________,__________,__________\n"
  "Line that separates sessions in our xwidget-webkit browsing history."
  :group 'webkit-mac-enhance
  :type 'string)

(defcustom web-history-amt-days 60
  "Integer corresponding to the amount of days recorded in `web-history-file'.
Entries that are older than the current date minus this amount will be deleted"
  :group 'webkit-mac-enhance
  :type 'integer)

;; TODO: need to figure out how to add a page only once per session
(defun webkit-add-current-url-to-history (msg title)
  "Get the current url and add it to `web-history-file'.
Also add date, time, and xwidget TITLE.
To check whether the current url should be added to the history file,
this function is added as advice to xwidget-log.  When the MSG we are logging
tells us that webkit finished loading, we add the url to the file"
  ;; only add to history once load is finished
  (when
      ;; TODO: figure out why we call xwidget-log when the length of title > 0
      ;; that causes us to rename the buffer twice,
      ;; and log "webkit finished loading" twice
      (and (string-equal (nth 3 last-input-event)
                         "load-finished")
           (equal msg "webkit finished loading: %s"))
    (with-temp-file web-history-file
      (if (file-exists-p web-history-file)
	  (insert-file-contents-literally web-history-file)
        (insert web-history-file-header))
      ;; (let* ((title (xwidget-webkit-title (xwidget-webkit-current-session)))
      (let* ((url (xwidget-webkit-uri (xwidget-webkit-current-session)))
	     (time-as-list (split-string (current-time-string)))
	     (date
	      (string-join
	       (nconc (take 3 time-as-list) (last time-as-list)) " "))
	     (hour (nth 3 time-as-list))
	     (web-history-line (concat date "," hour "," title "," url "\n")))
        ;; (goto-char (point-min))
        (forward-line 1) ; add at the top, under the header: most recent first
        (insert web-history-line)))))
(advice-add 'xwidget-log :after #'webkit-add-current-url-to-history)

(defun webkit-history-add-session-separator (&rest _args)
  "Insert `web-history-file-session-separator' in `web-history-file'.
This helps visualize different sessions in the csv file.
  _ARGS are ignored, but included in the definition so that this
  function can be added as advice before `xwidget-webkit-new-session'.
  Side effect: delete old entries,
by calling `webkit-history-clear-older-entries'"
  (with-temp-file web-history-file
    (if (file-exists-p web-history-file)
	(insert-file-contents-literally web-history-file)
      (insert web-history-file-header))
    (forward-line 1)
    (insert web-history-file-session-separator)
    (webkit-history-clear-older-entries)))

(advice-add 'xwidget-webkit-new-session :before
	    #'webkit-history-add-session-separator)

(defun webkit-history-clear-older-entries ()
  "Delete entries older than `web-history-amt-days' ago from `web-history-file'."
  (let* ((date
	  (thread-last
	    (* 60 60 24 web-history-amt-days)
	    (time-subtract (current-time))
	    (current-time-string)
	    (replace-regexp-in-string
	     " [[:digit:]][[:digit:]]:[[:digit:]][[:digit:]]:[[:digit:]][[:digit:]]" "")
	    (replace-regexp-in-string "[[:space:]]+" " "))))
    (if (search-forward-regexp date nil 'no-error)
	;; if found, delete every following entry,
	;; and the preceding newline
	(progn
	  (move-beginning-of-line 1)
	  (let ((start (point))
		(end (point-max)))
	    (delete-region start end)
	    (delete-char -1))))))

;;;###autoload
(defun webkit-mac-enhance-display-web-history ()
  "Open `web-history-file' in another window."
  (interactive)
  (find-file-other-window web-history-file))

(advice-add 'xwidget-webkit-browse-history :override #'webkit-mac-enhance-display-web-history)

;;;;; web history mode
;; to display the history file
(defvar web-history-highlights
  '(
    ("," . 'csv-separator-face)
    ("[[:digit:]][[:digit:]]:[[:digit:]][[:digit:]]:[[:digit:]][[:digit:]]" .
     'font-lock-string-face)
    ("__________" . 'font-lock-builtin-face)
    ("https?:.*" . 'link)))

(defun web-history-open-url (arg)
  "If called when point is at a link, open that url.
Else, parse the line at point to find the link, prompt for confirmation,
  and open it.  Prefix ARG is used when calling `xwidget-webkit-browse-url',
  as the value of NEW-SESSION"
  (interactive "P")
  (let ((at-point (thing-at-point 'sexp 'no-properties)))
    (if (string-match-p "http" at-point)
	(progn
	  (xwidget-webkit-browse-url at-point arg))
      (let* ((line (thing-at-point 'line 'no-properties))
	     (link (string-trim (substring line (string-match-p "[^,]+$" line))))
	     (url (read-from-minibuffer "xwidget-webkit URL: " link)))
	(xwidget-webkit-browse-url url arg)))))

(defun web-history-mouse-open-url (event)
  "Move point to location defined by EVENT: if there's a link, open it."
  (interactive "e")
  (mouse-set-point event)
  (let ((at-point (thing-at-point 'sexp 'no-properties)))
    (if (string-match-p "http" at-point)
        (xwidget-webkit-browse-url at-point))))

(defvar web-history-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-<return>") #'web-history-open-url)
    (define-key map (kbd "C-c C-o") #'web-history-open-url)
    (define-key map (kbd "<mouse-3>") #'web-history-mouse-open-url)
    map))

;;;###autoload
(define-derived-mode web-history-mode csv-mode "web-history"
  "Major mode for displaying web history.
\\{web-history-mode-map}"
  (setq font-lock-defaults '(web-history-highlights))
  (setq-local buffer-read-only t)
  (setq-local comment-start nil)
  (setq-local comment-end nil)
  (setq-local font-lock-comment-face nil)
  (auto-revert-mode 1))
(add-to-list 'auto-mode-alist '("web_history.csv" . web-history-mode))

;;; Search text in page
;; this section is all copied from the earlier version of xwidget.el
;; at https://github.com/emacs-mirror/emacs/blob/emacs-28/lisp/xwidget.el
(defvar isearch-search-fun-function)

;; Initialize last search text length variable when isearch starts
(defvar xwidget-webkit-isearch-last-length 0)
(add-hook 'isearch-mode-hook
          (lambda ()
            (setq xwidget-webkit-isearch-last-length 0)))

;; This is minimal. Regex and incremental search will be nice
(defvar xwidget-webkit-search-js "
  var xwSearchForward = %s;
  var xwSearchRepeat = %s;
  var xwSearchString = '%s';
  if (window.getSelection() && !window.getSelection().isCollapsed) {
  if (xwSearchRepeat) {
  if (xwSearchForward)
  window.getSelection().collapseToEnd();
  else
  window.getSelection().collapseToStart();
  } else {
  if (xwSearchForward)
  window.getSelection().collapseToStart();
  else {
  var sel = window.getSelection();
  window.getSelection().collapse(sel.focusNode, sel.focusOffset + 1);
  }
  }
  }
  window.find(xwSearchString, false, !xwSearchForward, true, false, true);
  ")

(defun xwidget-webkit-search-fun-function ()
  "Return the function which perform the search in xwidget webkit."
  (lambda (string &optional bound noerror count)
    (ignore bound noerror count)
    (let ((current-length (length string))
          search-forward
          search-repeat)
      ;; Forward or backward
      (if (eq isearch-forward nil)
          (setq search-forward "false")
        (setq search-forward "true"))
      ;; Repeat if search string length not changed
      (if (eq current-length xwidget-webkit-isearch-last-length)
          (setq search-repeat "true")
        (setq search-repeat "false"))
      (setq xwidget-webkit-isearch-last-length current-length)
      (xwidget-webkit-execute-script
       (xwidget-webkit-current-session)
       (format xwidget-webkit-search-js
               search-forward
               search-repeat
               (regexp-quote string)))
      ;; Unconditionally avoid 'Failing I-search ...'
      (if (eq isearch-forward nil)
          (goto-char (point-max))
        (goto-char (point-min))))))

;;; xwidget configuration
;; adding our patches to the mode definition
(defun my-xwidget-webkit-fix-configuration ()
  "Xwidget webkit view mode.
This overrides the original definition in xwidget.el.
Because it tried to call the undefined function
`xwidget-webkit-estimated-load-progress'."
  (define-key xwidget-webkit-mode-map "s" #'websearch)
  (define-key xwidget-webkit-mode-map "t" #'eww-this)
  (define-key xwidget-webkit-mode-map "H" #'webkit-mac-enhance-display-web-history)
  (define-key xwidget-webkit-mode-map "x" #'xwidget-webkit-browse-url)
  (define-key xwidget-webkit-mode-map "\C-s" #'isearch-forward)
  (define-key xwidget-webkit-mode-map "\C-r" #'isearch-backward)
  (setq-local isearch-lazy-highlight nil)
  (setq-local isearch-search-fun-function
              #'xwidget-webkit-search-fun-function))

(advice-add 'xwidget-webkit-mode :after #'my-xwidget-webkit-fix-configuration)

;; add package to the `features' list
(provide 'webkit-mac-enhance)
;;; webkit-mac-enhance.el ends here
