;;; sspai.el --- Write and publish local SSPAI articles  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Dzming Li

;; Author: Dzming Li <i@dzming.li>
;; Maintainer: Dzming Li <i@dzming.li>
;; Version: 0.1.0
;; Package-Requires: ((emacs "31.1") (firefox-cookies "0.1.0"))
;; Keywords: convenience, hypermedia, tools
;; URL: https://github.com/DzmingLi/sspai.el
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Write SSPAI articles in Org mode, upload local body images and the
;; document's generic `banner' image, publish to the community,
;; submit for editorial review, and update existing articles from local sources.
;;
;; Use `firefox-cookies' to read the explicitly configured Firefox login.
;; Account Bearer, article editing, and Qiniu upload tokens stay in memory;
;; credentials are never written into source files.
;;
;;   #+TITLE: Example
;;   #+BANNER: ./banner.png
;;   #+FILETAGS: :Emacs:
;;
;; Local Org files are authoritative.  Publication only pushes local content.

;;; Code:

(require 'cl-lib)
(require 'dom)
(require 'firefox-cookies)
(require 'json)
(require 'mailcap)
(require 'org)
(require 'ox-html)
(require 'subr-x)
(require 'url)
(require 'url-cookie)
(require 'url-http)
(require 'url-parse)
(require 'url-util)
(require 'xml)

(defgroup sspai nil
  "Write and publish local SSPAI articles."
  :group 'applications
  :prefix "sspai-")

(define-error 'sspai-api-error "SSPAI API request failed")
(define-error
 'sspai-source-changed
 "Local SSPAI source changed during publication")
(define-error
 'sspai-create-result-unknown
 "SSPAI draft creation result is unknown")
(define-error
 'sspai-published-but-not-checkpointed
 "SSPAI article changed remotely but local metadata was not saved")
(define-error
 'sspai-image-uploaded-but-not-checkpointed
 "SSPAI image was uploaded but its local cache was not saved")

;;;; Customization

(defcustom sspai-request-timeout 30
  "Timeout in seconds for one SSPAI or Qiniu HTTP request."
  :type 'integer
  :group 'sspai)

(defcustom sspai-maximum-image-size (* 5 1024 1024)
  "Largest image, in bytes, that `sspai.el' will upload."
  :type 'integer
  :group 'sspai)

(defcustom sspai-title-width-limit 32
  "Displayed title width at which `sspai.el' warns before a write."
  :type 'integer
  :group 'sspai)

;;;; Constants and data structures

(defconst sspai--recommended-image-size (* 2 1024 1024)
  "Image size in bytes above which an upload emits a quality warning.")

(defconst sspai--type-to-status
  '((0 . "featured")
    (1 . "audit")
    (2 . "audit")
    (4 . "draft")
    (5 . "published")))

(defconst sspai--editable-types '(4 5))

(defconst sspai--hash-regexp "\\`[[:xdigit:]]\\{64\\}\\'")

(cl-defstruct (sspai--response
               (:constructor sspai--make-response))
  status
  body)

;;;; Generic value helpers

(defun sspai--required-string (field value)
  "Require a non-empty string VALUE for FIELD."
  (unless (and (stringp value) (not (string-empty-p (string-trim value))))
    (user-error "sspai: %s 必须是非空字符串" field))
  (string-trim value))

(defun sspai--integer (field value &optional allow-zero)
  "Normalize VALUE as an integer for FIELD.
When ALLOW-ZERO is nil, require a positive integer."
  (let ((number
         (cond
          ((integerp value) value)
          ((and (stringp value)
                (string-match-p "\\`[0-9]+\\'" value))
           (string-to-number value))
          ((null value) nil)
          (t (user-error "sspai: %s 必须是整数" field)))))
    (when (and number
               (if allow-zero (< number 0) (<= number 0)))
      (user-error "sspai: %s 超出允许范围" field))
    number))

(defun sspai--boolean (field value &optional default)
  "Normalize VALUE as a boolean for FIELD, using DEFAULT when absent."
  (cond
   ((null value) default)
   ((or (eq value t) (equal value "true"))
    t)
   ((or (eq value :json-false) (equal value "false"))
    nil)
   (t (user-error "sspai: %s 必须是 true 或 false" field))))

(defun sspai--bool-json (value)
  "Return VALUE in the representation expected by `json-serialize'."
  (if value t :json-false))

;;;; URL and authentication

(defun sspai--api-url (path)
  "Return the SSPAI editor API URL for PATH."
  (concat "https://sspai.com/api/v1" path))

(defun sspai--access-token (url)
  "Read the Firefox login token for API URL without caching it."
  (let* ((value (cdr (assoc "sspai_jwt_token" (firefox-cookies-get url))))
         (token (and (stringp value) (url-unhex-string value t))))
    (unless (and token (not (string-empty-p (string-trim token)))
                 (not (string-match-p "[\r\n]" token)))
      (user-error "sspai: Firefox 登录 Cookie 无效或缺失，请在配置的 profile 中登录少数派"))
    (string-trim token)))

;;;; HTTP and API envelopes

(defun sspai--buffer-response-body ()
  "Return decoded UTF-8 response body from the current URL buffer."
  (let ((start
         (or (and (boundp 'url-http-end-of-headers)
                  url-http-end-of-headers)
             (save-excursion
               (goto-char (point-min))
               (when (re-search-forward "\r?\n\r?\n" nil t)
                 (point))))))
    (unless start
      (error "sspai: 无法解析 HTTP 响应头"))
    (decode-coding-string
     (buffer-substring-no-properties start (point-max))
     'utf-8 t)))

(cl-defun sspai--http
    (method url &key data content-type headers auth redact)
  "Send one HTTP request to URL and return an `sspai--response'.
DATA may be UTF-8 or an unibyte multipart payload.  AUTH adds the SSPAI
Bearer token and is only accepted for SSPAI API URLs.  Cookies and
automatic redirects are disabled.  REDACT is a list of additional transient
secrets that must not appear in a transport error."
  (when auth
    (unless (string-prefix-p
             "https://sspai.com/api/v1/" url)
      (error "sspai: 拒绝向少数派 API 之外发送 Bearer token：%s" url)))
  (let* ((account-token (and auth (sspai--access-token url)))
         (url-request-method method)
         (url-request-data data)
         (url-request-extra-headers
          (append
           (when content-type
             `(("Content-Type" . ,content-type)))
           '(("Accept" . "application/json")
             ("User-Agent" . "sspai.el/0.1.0 (Emacs)"))
           (when auth
             ;; Browser/SQLite strings can be multibyte even for ASCII JWTs.
             ;; A multibyte header would promote UTF-8 body bytes during
             ;; `url-http-create-request', which then rejects Chinese posts.
             `(("Authorization"
                . ,(encode-coding-string
                    (concat "Bearer " account-token) 'utf-8))))
           headers))
         (url-max-redirections 0)
         (url-automatic-caching nil)
         ;; The editor API uses explicit Bearer authentication.  Isolating the
         ;; URL cookie jars prevents ambient browser/session cookies from
         ;; becoming an accidental second credential channel.
         (url-cookie-file nil)
         (url-cookie-storage nil)
         (url-cookie-secure-storage nil)
         (url-cookie-confirmation nil)
         buffer)
    (condition-case err
        (setq buffer
              (url-retrieve-synchronously
               url t t sspai-request-timeout))
      (error
       (let ((message-text (error-message-string err)))
         (dolist (secret (cons account-token redact))
           (when (and (stringp secret)
                      (not (string-empty-p secret)))
             (setq message-text
                   (replace-regexp-in-string
                    (regexp-quote secret)
                    "<redacted>"
                    message-text t t))))
         (signal
          'sspai-api-error
          (list (format "网络请求失败 %s %s：%s"
                        method url message-text))))))
    (unless (buffer-live-p buffer)
      (signal
       'sspai-api-error
       (list
        (format "请求超时或未收到响应：%s %s" method url))))
    (unwind-protect
        (with-current-buffer buffer
          (sspai--make-response
           :status (or (and (boundp 'url-http-response-status)
                            url-http-response-status)
                       0)
           :body (sspai--buffer-response-body)))
      (kill-buffer buffer))))

(defun sspai--parse-json (text)
  "Parse JSON TEXT into symbol-keyed alists and lists."
  (unless (string-empty-p (string-trim text))
    (condition-case err
        (json-parse-string
         text
         :object-type 'alist
         ;; Vectors preserve the JSON array/object distinction.  This matters
         ;; when a complete article object is sent back to the update endpoint:
         ;; nil must not turn an empty server array into JSON null.
         :array-type 'array
         :null-object nil
         :false-object :json-false)
      (json-parse-error
       (error "sspai: 服务端返回了无效 JSON：%s"
              (error-message-string err))))))

(defun sspai--successful-status-p (status)
  "Return non-nil when STATUS is a successful HTTP status."
  (and (integerp status) (<= 200 status) (< status 300)))

(defun sspai--json-error-message (json body)
  "Extract a useful error message from JSON or raw BODY."
  (or (and json
           (or (alist-get 'msg json)
               (alist-get 'message json)
               (let ((value (alist-get 'error json)))
                 (and (stringp value) value))))
      (and (stringp body)
           (not (string-empty-p (string-trim body)))
           (string-trim body))
      "未知错误"))

(cl-defun sspai--api-request (method path &key query payload)
  "Send an authorized SSPAI API request and return its full JSON envelope."
  (let* ((query-string
          (and query
               (mapconcat
                (lambda (entry)
                  (concat
                   (url-hexify-string
                    (if (symbolp (car entry))
                        (symbol-name (car entry))
                      (format "%s" (car entry))))
                   "="
                   (url-hexify-string (format "%s" (cdr entry)))))
                query "&")))
         (url (sspai--api-url
               (concat path
                       (if query-string
                           (concat "?" query-string)
                         ""))))
         (encoded
          (and payload
               (encode-coding-string
                (json-serialize
                 payload :null-object nil :false-object :json-false)
                'utf-8 t)))
         (response
          (sspai--http
           method url
           :data encoded
           :content-type (and payload
                              "application/json; charset=utf-8")
           :redact
           (let ((token (and payload
                             (alist-get 'token payload))))
             (and (stringp token) (list token)))
           :auth t))
         (status (sspai--response-status response))
         (body (sspai--response-body response))
         (json (ignore-errors (sspai--parse-json body))))
    (unless (sspai--successful-status-p status)
      (signal
       'sspai-api-error
       (list
        (cond
         ((= status 401)
          "Bearer token 无效、已撤销或已过期")
         ((= status 403)
          (concat "Bearer token 权限不足："
                  (sspai--json-error-message json body)))
         (t
          (format "HTTP %s：%s"
                  status (sspai--json-error-message json body))))
        status path 'http)))
    (unless json
      (signal 'sspai-api-error
              (list "成功响应没有 JSON body"
                    status path 'invalid-success)))
    (let ((error-code (alist-get 'error json)))
      (unless (and (integerp error-code)
                   (zerop error-code))
        (signal
         'sspai-api-error
         (list
          (if (integerp error-code)
              (sspai--json-error-message json body)
            "API envelope 缺少整数 error 字段")
          error-code path 'envelope))))
    json))

(defun sspai--api-data (method path &optional query payload)
  "Return the `data' member from an SSPAI API envelope."
  (alist-get 'data (sspai--api-request
                    method path :query query :payload payload)))

;;;; Source metadata

(defun sspai--validate-source-file (file)
  "Require FILE to have an Org extension, and return FILE."
  (unless (equal (downcase (or (file-name-extension file) "")) "org")
    (user-error "sspai: 仅支持 .org 源稿"))
  file)

(defun sspai--read-file-text (file)
  "Read UTF-8 source FILE as text."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun sspai--type-status (type)
  "Return local status string for Matrix editor TYPE."
  (or (cdr (assq type sspai--type-to-status))
      (format "type-%s" type)))

(defun sspai--normalize-image-cache (table)
  "Validate the string-keyed image cache TABLE."
  (setq table (or table (make-hash-table :test #'equal)))
  (maphash
   (lambda (key url)
     (unless (and (stringp key) (string-match-p sspai--hash-regexp key)
                  (stringp url) (string-prefix-p "https://" url))
       (user-error "sspai: 无效的图片缓存条目：%S" key)))
   table)
  table)

(defun sspai--org-header-and-body (text)
  "Split Org TEXT into (HEADER-LINES BODY)."
  (let ((lines (split-string text "\n" nil))
        header body done)
    (while lines
      (let ((line (pop lines)))
        (if (and (not done)
                 (or (string-empty-p line)
                     (string-match-p
                      "\\`[ \t]*#\\(?:\\+[^:]+:.*\\|[^+].*\\)?\\'"
                      line)))
            (push line header)
          (setq done t)
          (push line body))))
    (list (nreverse header)
          (mapconcat #'identity (nreverse body) "\n"))))

(defun sspai--org-header-values (header)
  "Collect leading Org HEADER keyword values."
  (let (values)
    (dolist (line header)
      (when (string-match
             "\\`[ \t]*#\\+\\([^: \t\n]+\\):[ \t]*\\(.*\\)\\'" line)
        (let* ((key (upcase (match-string 1 line)))
               (value (string-trim (match-string 2 line))))
          ;; Repeated #+PROPERTY and other ordinary Org keywords are legal and
          ;; are preserved verbatim.  Only fields read by this package need a
          ;; uniqueness check.
          (when (or (member key '("TITLE" "BANNER" "FILETAGS"))
                    (string-prefix-p "SSPAI_" key))
            (when (assoc key values)
              (user-error "sspai: Org keyword #+%s 不能重复" key))
            (push (cons key value) values)))))
    (nreverse values)))

(defun sspai--org-value (key values &optional allow-empty)
  "Return KEY from Org keyword VALUES.
When ALLOW-EMPTY is nil, reject an explicitly empty value."
  (let ((cell (assoc key values)))
    (when cell
      (when (and (not allow-empty) (string-empty-p (cdr cell)))
        (user-error "sspai: #+%s 不能为空" key))
      (cdr cell))))

(defun sspai--org-image-cache (raw)
  "Parse RAW Org image cache JSON."
  (if (or (null raw) (string-empty-p raw))
      (make-hash-table :test #'equal)
    (condition-case err
        (sspai--normalize-image-cache
         (json-parse-string
          raw
          :object-type 'hash-table
          :array-type 'list
          :null-object nil
          :false-object :json-false))
      (error
       (user-error "sspai: #+SSPAI_IMAGE_CACHE 不是有效 JSON：%s"
                   (error-message-string err))))))

(defun sspai--org-meta-and-body (text)
  "Read article settings and body directly from Org TEXT."
  (pcase-let* ((`(,header ,body) (sspai--org-header-and-body text))
               (values (sspai--org-header-values header)))
    (cl-flet ((value (key) (sspai--org-value key values)))
      (let* ((banner-id (or (sspai--integer "banner-id"
                                            (value "SSPAI_BANNER_ID") t) 0))
             (banner-key (value "SSPAI_BANNER_KEY"))
             (banner-hash (value "SSPAI_BANNER_HASH"))
             (benefits-on (sspai--boolean "benefits-statement-on"
                                          (value "SSPAI_BENEFITS_STATEMENT_ON")))
             (benefits-id (or (sspai--integer "benefits-statement-id"
                                              (value "SSPAI_BENEFITS_STATEMENT_ID") t)
                              0)))
        (when (and banner-hash (not (string-match-p sspai--hash-regexp banner-hash)))
          (user-error "sspai: 无效的题图缓存 hash"))
        (when (and banner-key (zerop banner-id))
          (user-error "sspai: banner-key 存在时必须同时保存 banner-id"))
        (when (and benefits-on (zerop benefits-id))
          (user-error "sspai: 开启利益相关声明时必须设置 statement id"))
        (list
         (list :id (sspai--integer "id" (value "SSPAI_ID"))
               :status (value "SSPAI_STATUS")
               :title (sspai--org-value "TITLE" values t)
               :banner (value "BANNER")
               :tags (delete-dups
                      (split-string (or (sspai--org-value "FILETAGS" values t) "")
                                    ":" t "[ \t]+"))
               :allow-comment (sspai--boolean "allow-comment"
                                              (value "SSPAI_ALLOW_COMMENT") t)
               :benefits-statement-on benefits-on
               :benefits-statement-id benefits-id
               :banner-id banner-id :banner-key banner-key :banner-hash banner-hash
               :image-cache (sspai--org-image-cache
                             (sspai--org-value "SSPAI_IMAGE_CACHE" values t))
               :source-text text)
         body)))))

(defun sspai--read-source (file)
  "Return (META RAW-BODY) from Org FILE."
  (sspai--validate-source-file file)
  (sspai--org-meta-and-body (sspai--read-file-text file)))

;;;; Source formatting and safe checkpoints

(defun sspai--format-org-source (text meta)
  "Update publication fields in TEXT from META, preserving all other text."
  (pcase-let* ((`(,header ,body) (sspai--org-header-and-body text))
               (cache (plist-get meta :image-cache))
               (fields
                `(("SSPAI_ID" . ,(plist-get meta :id))
                  ("SSPAI_STATUS" . ,(plist-get meta :status))
                  ("SSPAI_BANNER_ID" . ,(plist-get meta :banner-id))
                  ("SSPAI_BANNER_KEY" . ,(plist-get meta :banner-key))
                  ("SSPAI_BANNER_HASH" . ,(plist-get meta :banner-hash))
                  ("SSPAI_IMAGE_CACHE" . ,(when (> (hash-table-count cache) 0)
                                            (json-serialize cache))))))
    (dolist (field fields)
      (let* ((key (car field))
             (value (cdr field))
             (line (and value (not (equal value 0))
                        (format "#+%s: %s" key value)))
             (regexp (concat "\\`[ \t]*#\\+" key ":[^\n]*\\'"))
             (case-fold-search t)
             found)
        (setq header
              (delq nil
                    (mapcar (lambda (old)
                              (if (string-match-p regexp old)
                                  (prog1 line (setq found t))
                                old))
                            header)))
        (when (and line (not found))
          (push line header))))
    (concat (mapconcat #'identity header "\n")
            (unless (string-empty-p body) "\n") body)))

(defun sspai--atomic-write-text (file text)
  "Atomically replace local regular FILE with TEXT."
  (let* ((file (expand-file-name file))
         (directory (file-name-directory file))
         (mode (and (file-exists-p file) (file-modes file)))
         temporary)
    (when (file-remote-p file)
      (user-error "sspai: checkpoint 不支持远程路径"))
    (when (file-symlink-p file)
      (user-error "sspai: 拒绝通过符号链接写回源稿：%s" file))
    (unless (and (file-exists-p file) (file-regular-p file))
      (user-error "sspai: 源稿不是本地普通文件：%s" file))
    (setq temporary
          (make-temp-file
           (expand-file-name ".sspai-checkpoint-" directory)))
    (unwind-protect
        (progn
          (with-temp-buffer
            (insert text)
            (let ((coding-system-for-write 'utf-8-unix))
              (write-region
               (point-min) (point-max) temporary nil 'silent)))
          (when mode (set-file-modes temporary mode))
          (rename-file temporary file t)
          (setq temporary nil))
      (when (and temporary (file-exists-p temporary))
        (ignore-errors (delete-file temporary))))))

(defun sspai--write-source (file meta)
  "Save publication fields from META without rewriting FILE's editorial text."
  (sspai--validate-source-file file)
  (sspai--assert-source-unchanged file meta)
  (let ((text (sspai--format-org-source (plist-get meta :source-text) meta)))
    (sspai--atomic-write-text file text)
    (setf (plist-get meta :source-text) text))
  (when-let* ((buffer (find-buffer-visiting (expand-file-name file))))
    (with-current-buffer buffer
      (revert-buffer t t t))))

(defun sspai--create-source (file title)
  "Create a local Org FILE with TITLE without overwriting."
  (sspai--validate-source-file file)
  (let* ((file (expand-file-name file))
         (directory (file-name-directory file)))
    (when (file-remote-p file)
      (user-error "sspai: 新建源稿不支持远程路径"))
    (when (or (file-exists-p file) (file-symlink-p file))
      (user-error "sspai: 目标路径已被占用，拒绝覆盖：%s" file))
    (make-directory directory t)
    (with-temp-buffer
      (insert "#+TITLE: " (or title "") "\n\n")
      (let ((coding-system-for-write 'utf-8-unix))
        (write-region (point-min) (point-max) file nil 'silent nil 'excl)))
    (find-file file)
    file))

;;;; Source conversion

(defun sspai--source-to-html (file raw-body)
  "Export Org RAW-BODY from FILE using the built-in HTML exporter."
  (sspai--validate-source-file file)
  (let ((default-directory (file-name-directory (expand-file-name file)))
        (org-export-use-babel nil)
        (org-export-allow-bind-keywords nil)
        (org-html-htmlize-output-type nil))
    (string-trim
     (org-export-string-as
      raw-body 'html t
      (list :with-toc nil :section-numbers nil :with-title nil
            :with-author nil :with-date nil :html-inline-images t
            :html-doctype "html5" :html-html5-fancy t
            :html-toplevel-hlevel 2)))))

(defun sspai--parse-html (html)
  "Parse HTML and return a DOM node."
  (with-temp-buffer
    (insert html)
    (libxml-parse-html-region (point-min) (point-max))))

(defun sspai--inner-html (node)
  "Serialize NODE children as HTML without NODE's own wrapper."
  (with-temp-buffer
    (dolist (child (dom-children node))
      (cond
       ((stringp child) (insert (xml-escape-string child)))
       ((consp child) (dom-print child nil nil))))
    (buffer-string)))

;;;; Attachment upload

(defun sspai--read-file-bytes (path)
  "Read PATH literally and return an unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally path)
    (buffer-string)))

(defun sspai--decode-data-url (value)
  "Decode image data URL VALUE into (MIME . BYTES), or return nil."
  (when (string-match
         "\\`data:\\([^;,]+\\)\\(?:;[^,]*\\)?,\\(.*\\)\\'" value)
    (let ((mime (downcase (match-string 1 value)))
          (payload (match-string 2 value))
          (params (match-string 0 value)))
      (cons
       mime
       (if (string-match-p ";base64," params)
           (base64-decode-string payload)
         (encode-coding-string
          (url-unhex-string payload) 'binary t))))))

(defun sspai--normalize-local-reference (reference base-dir)
  "Resolve image REFERENCE relative to BASE-DIR.
Return the symbol `external' for HTTP(S) URLs."
  (let* ((without-tail
          (substring reference
                     0
                     (or (string-match "[?#]" reference)
                         (length reference))))
         (parsed (url-generic-parse-url without-tail))
         (scheme (url-type parsed))
         (host (url-host parsed)))
    (cond
     ((or (member scheme '("http" "https"))
          (and (null scheme) host))
      'external)
     ((and scheme (not (string-equal scheme "file")))
      (user-error "sspai: 不支持图片 URL scheme：%s" scheme))
     ((and host
           (not (string-empty-p host))
           (not (string-equal (downcase host) "localhost")))
      (user-error "sspai: 不支持远程 file URL host：%s" host))
     (t
      (let ((encoded-path
             (if scheme (url-filename parsed) without-tail)))
        (when (string-empty-p encoded-path)
          (user-error "sspai: 图片引用缺少本地路径"))
        (expand-file-name
         (decode-coding-string
          (url-unhex-string encoded-path) 'utf-8)
         base-dir))))))

(defun sspai--image-bytes-and-mime (reference base-dir)
  "Return (MIME . BYTES) for image REFERENCE.
Return `external' for an HTTP(S) reference."
  (if (string-prefix-p "data:" reference)
      (let ((decoded
             (or (sspai--decode-data-url reference)
                 (user-error "sspai: 无法解析图片 data URL"))))
        (unless (string-prefix-p "image/" (car decoded))
          (user-error "sspai: data URL 不是图片：%s" (car decoded)))
        decoded)
    (let ((path
           (sspai--normalize-local-reference reference base-dir)))
      (if (eq path 'external)
          'external
        (unless (and (file-regular-p path) (file-readable-p path))
          (user-error "sspai: 图片文件不可读：%s" path))
        (let ((mime
               (downcase
                (or (mailcap-file-name-to-mime-type path) ""))))
          (when (string-equal mime "image/jpg")
            (setq mime "image/jpeg"))
          (unless (member mime
                          '("image/png" "image/jpeg" "image/gif"))
            (user-error "sspai: 不支持图片类型 %s：%s" mime path))
          (cons mime (sspai--read-file-bytes path)))))))

(defun sspai--mime-extension (mime)
  "Return a safe extension for image MIME."
  (pcase (downcase mime)
    ("image/png" "png")
    ("image/jpeg" "jpg")
    ("image/gif" "gif")
    (_ (user-error "sspai: 不支持图片 MIME：%s" mime))))

(defun sspai--random-name (extension)
  "Return an ASCII random-looking attachment name with EXTENSION."
  (let* ((hex
          (secure-hash
           'sha256
           (format "%s:%s:%s:%s"
                   (float-time)
                   (emacs-pid)
                   (random)
                   (user-uid))))
         (uuid
          (format "%s-%s-%s-%s-%s"
                  (substring hex 0 8)
                  (substring hex 8 12)
                  (substring hex 12 16)
                  (substring hex 16 20)
                  (substring hex 20 32))))
    (concat uuid "." extension)))

(defun sspai--check-image-size (bytes context)
  "Validate BYTES size and warn for CONTEXT when above the recommendation."
  (let ((size (string-bytes bytes)))
    (when (> size sspai-maximum-image-size)
      (user-error
       "sspai: %s 大小 %.2f MB，超过 %.2f MB 上限"
       context
       (/ size 1048576.0)
       (/ sspai-maximum-image-size 1048576.0)))
    (when (> size sspai--recommended-image-size)
      (message
       "sspai: %s 为 %.2f MB；官方建议图片控制在 %.2f MB 内"
       context
       (/ size 1048576.0)
       (/ sspai--recommended-image-size 1048576.0)))))

(defun sspai--multipart-escape (value)
  "Validate and return multipart header VALUE."
  (unless (and (stringp value)
               (not (string-match-p "[\r\n\"]" value)))
    (error "sspai: multipart header value 不安全"))
  value)

(defun sspai--multipart-body (fields filename mime bytes)
  "Build multipart body for text FIELDS and one file.
Return (CONTENT-TYPE . UNIBYTE-BODY)."
  (let* ((boundary
          (concat "----------------sspai"
                  (substring
                   (secure-hash
                    'sha256
                    (format "%s:%s:%s"
                            (float-time) (random) (length bytes)))
                   0 32)))
         (crlf "\r\n")
         (parts nil))
    (dolist (field fields)
      (push
       (encode-coding-string
        (concat
         "--" boundary crlf
         "Content-Disposition: form-data; name=\""
         (sspai--multipart-escape (car field))
         "\"" crlf crlf
         (or (cdr field) "") crlf)
        'utf-8 t)
       parts))
    (push
     (encode-coding-string
      (concat
       "--" boundary crlf
       "Content-Disposition: form-data; name=\"file\"; filename=\""
       (sspai--multipart-escape filename)
       "\"" crlf
       "Content-Type: " (sspai--multipart-escape mime) crlf crlf)
      'utf-8 t)
     parts)
    (push bytes parts)
    (push (encode-coding-string crlf 'utf-8 t) parts)
    (push
     (encode-coding-string
      (concat "--" boundary "--" crlf)
      'utf-8 t)
     parts)
    (cons
     (concat "multipart/form-data; boundary=" boundary)
     (apply #'concat (nreverse parts)))))

(defun sspai--attachment-token (filename)
  "Get one short-lived SSPAI attachment upload credential for FILENAME."
  (let ((data
         (sspai--api-data
          "GET"
          "/matrix/editor/attachment/upload/token/get"
          `((cname . ,filename)))))
    (unless (and data
                 (stringp (alist-get 'token data))
                 (not (string-empty-p
                       (alist-get 'token data))))
      (signal 'sspai-api-error
              (list "上传凭据缺少 token")))
    data))

(defun sspai--qiniu-upload (filename mime bytes credential)
  "Upload BYTES to Qiniu with SSPAI CREDENTIAL.
Return a plist containing :url, :key, :id, and :hash."
  (let* ((token (alist-get 'token credential))
         (issued-key (alist-get 'key credential))
         (attachment-id
          (or (sspai--integer
               "attachment id"
               (alist-get 'id credential)
               t)
              0))
         (fields
          (append
           `(("token" . ,token))
           (when issued-key
             `(("key" . ,issued-key)))))
         (multipart
          (sspai--multipart-body fields filename mime bytes))
         (response
          (sspai--http
           "POST" "https://upload.qiniup.com/"
           :data (cdr multipart)
           :content-type (car multipart)
           :redact (list token)
           :auth nil))
         (status (sspai--response-status response))
         (body (sspai--response-body response))
         (json (ignore-errors (sspai--parse-json body))))
    (unless (sspai--successful-status-p status)
      (signal
       'sspai-api-error
       (list
        (format "Qiniu HTTP %s：%s"
                status (sspai--json-error-message json body)))))
    (when-let* ((qiniu-error
                 (and json (alist-get 'error json))))
      (unless (and (integerp qiniu-error) (zerop qiniu-error))
        (signal 'sspai-api-error
                (list (sspai--json-error-message json body)))))
    (let ((key (or (and json (alist-get 'key json))
                   issued-key)))
      (unless (and (stringp key) (not (string-empty-p key)))
        (signal 'sspai-api-error
                (list "Qiniu 响应与 SSPAI 凭据都缺少 attachment key")))
      (list
       :url (concat
             "https://cdnfile.sspai.com"
             "/" key)
       :key key
       :id attachment-id
       :hash (and json (alist-get 'hash json))))))

(defun sspai--upload-image-bytes (bytes mime context)
  "Upload image BYTES of MIME for CONTEXT and return an upload plist."
  (sspai--check-image-size bytes context)
  (let* ((filename
          (sspai--random-name (sspai--mime-extension mime)))
         (credential (sspai--attachment-token filename)))
    (sspai--qiniu-upload filename mime bytes credential)))

;;;###autoload
(defun sspai-upload-image-file (path)
  "Upload local image PATH and copy its SSPAI CDN URL."
  (interactive "fImage file: ")
  (let* ((path (expand-file-name path))
         (pair (sspai--image-bytes-and-mime
                path (file-name-directory path))))
    (when (eq pair 'external)
      (user-error "sspai: 请选择本地图片"))
    (let* ((result
            (sspai--upload-image-bytes
             (cdr pair) (car pair) (file-name-nondirectory path)))
           (url (plist-get result :url)))
      (kill-new url)
      (message "sspai: 已上传并复制 %s" url)
      url)))

(defun sspai--checkpoint-upload (checkpoint url)
  "Run CHECKPOINT after an image was uploaded to URL.
Signal a dedicated error when the remote image exists but its local cache
could not be persisted."
  (when checkpoint
    (condition-case err
        (funcall checkpoint)
      (error
       (signal
        'sspai-image-uploaded-but-not-checkpointed
        (list
         (format "图片已上传到 %s，但本地 checkpoint 失败：%s"
                 url (error-message-string err))
         url err))))))

(defun sspai--rewrite-body-images (html base-dir cache &optional checkpoint)
  "Upload local images in HTML and return rewritten HTML.
BASE-DIR resolves relative paths.  CACHE maps SHA-256 to CDN URL.
After each new upload, call CHECKPOINT so a later failure cannot cause a
duplicate upload on retry."
  (let* ((dom
          (sspai--parse-html
           (concat "<html><body>" html "</body></html>")))
         (uploaded 0)
         (cached 0)
         (skipped 0))
    (dolist (img (dom-by-tag dom 'img))
      (let ((src (dom-attr img 'src)))
        (unless (and (stringp src) (not (string-empty-p src)))
          (user-error "sspai: <img> 缺少非空 src"))
        (let ((pair (sspai--image-bytes-and-mime src base-dir)))
          (if (eq pair 'external)
              (cl-incf skipped)
            (let* ((mime (car pair))
                   (bytes (cdr pair))
                   (hash (secure-hash 'sha256 bytes))
                   (cached-url (gethash hash cache))
                   (url
                    (or
                     (and cached-url
                          (prog1 cached-url (cl-incf cached)))
                     (let ((result
                            (sspai--upload-image-bytes
                             bytes mime "正文图片")))
                       (cl-incf uploaded)
                       (puthash hash (plist-get result :url) cache)
                       (sspai--checkpoint-upload
                        checkpoint (plist-get result :url))
                       (plist-get result :url)))))
              (setcdr (assq 'src (dom-attributes img)) url))))))
    (message "sspai: 正文图片 %d 上传 / %d 缓存命中 / %d 外链保留"
             uploaded cached skipped)
    (let ((body (car (dom-by-tag dom 'body))))
      (sspai--inner-html body))))

(defun sspai--cdn-key-from-url (url)
  "Return SSPAI attachment key from CDN URL, or nil."
  (let ((prefix
         (concat
          "https://cdnfile.sspai.com"
          "/")))
    (when (and (stringp url) (string-prefix-p prefix url))
      (substring url (length prefix)))))

(defun sspai--canonical-banner-key (value)
  "Normalize SSPAI banner VALUE to an attachment key."
  (let ((banner (or value "")))
    (cond
     ((string-empty-p banner) "")
     ((string-match-p "\\`https://" banner)
      (or (sspai--cdn-key-from-url banner)
          (error "sspai: article banner 不属于配置的 CDN：%s"
                 banner)))
     (t (string-remove-prefix "/" banner)))))

(defun sspai--prepare-banner (file meta &optional checkpoint)
  "Ensure META's generic banner is usable by SSPAI.
Mutate META's banner synchronization fields and return (KEY . ID), or nil.
Call CHECKPOINT immediately after a new remote upload."
  (let ((banner (plist-get meta :banner)))
    (cond
     ((null banner)
      (setf (plist-get meta :banner-key) nil
            (plist-get meta :banner-hash) nil
            (plist-get meta :banner-id) 0)
      nil)
     ((string-match-p "\\`https://" banner)
      (let ((key (sspai--cdn-key-from-url banner)))
        (unless key
          (user-error
           (concat
            "sspai: 题图必须是本地文件或当前 SSPAI CDN URL；"
            "外部 URL 无法提供 banner-id")))
        (unless (and (string-equal key
                                   (or (plist-get meta :banner-key) ""))
                     (> (or (plist-get meta :banner-id) 0) 0))
          (user-error
           "sspai: 该 CDN 题图缺少与之匹配的 sspai banner-key/banner-id"))
        (cons key (plist-get meta :banner-id))))
     (t
      (let* ((base-dir (file-name-directory (expand-file-name file)))
             (pair (sspai--image-bytes-and-mime banner base-dir)))
        (when (eq pair 'external)
          (user-error "sspai: 无法解析本地题图：%s" banner))
        (let* ((mime (car pair))
               (bytes (cdr pair))
               (hash (secure-hash 'sha256 bytes)))
          (if (and (string-equal
                    hash (or (plist-get meta :banner-hash) ""))
                   (plist-get meta :banner-key)
                   (> (or (plist-get meta :banner-id) 0) 0))
              (cons (plist-get meta :banner-key)
                    (plist-get meta :banner-id))
            (let ((result
                   (sspai--upload-image-bytes bytes mime "题图")))
              (unless (> (or (plist-get result :id) 0) 0)
                (signal
                 'sspai-api-error
                 (list "题图上传凭据没有返回 attachment id")))
              (setf (plist-get meta :banner-key)
                    (plist-get result :key)
                    (plist-get meta :banner-id)
                    (plist-get result :id)
                    (plist-get meta :banner-hash) hash)
              (sspai--checkpoint-upload
               checkpoint (plist-get result :url))
              (cons (plist-get result :key)
                    (plist-get result :id))))))))))

;;;; Matrix article API

(defun sspai--tag-title (tag)
  "Return the non-empty title from one standard SSPAI TAG object."
  (unless (listp tag)
    (error "sspai: 服务端返回了无效的标准标签：%S" tag))
  (sspai--required-string "remote tag.title"
                          (alist-get 'title tag)))

(defun sspai--standard-tag-summary (tags)
  "Return a stable vector summarizing standard SSPAI TAGS."
  (vconcat
   (sort
    (mapcar
     (lambda (tag)
       `((id . ,(alist-get 'id tag))
         (title . ,(sspai--tag-title tag))))
     tags)
    (lambda (left right)
      (let ((left-title (alist-get 'title left))
            (right-title (alist-get 'title right)))
        (if (string-equal left-title right-title)
            (string< (format "%s" (alist-get 'id left))
                     (format "%s" (alist-get 'id right)))
          (string< left-title right-title)))))))

(defun sspai--normalize-article (object)
  "Keep the fields required for publishing article OBJECT.
The complete API object and editing token stay in memory only."
  (let ((id (sspai--integer "article.id" (alist-get 'id object)))
        (type (sspai--integer "article.type" (alist-get 'type object) t)))
    (unless (and id type)
      (error "sspai: article 响应缺少 id 或 type"))
    (list :id id :type type
          :status (sspai--type-status type)
          :token (alist-get 'token object)
          :title (alist-get 'title_last object)
          :body (alist-get 'body_last object)
          :free (sspai--boolean "article.free" (alist-get 'free object) t)
          :delete-status (sspai--boolean "article.delete_status"
                                         (alist-get 'delete_status object))
          :standard-tags (alist-get 'tags object)
          :raw object)))

(defun sspai--api-error-code-or-status (err)
  "Return numeric API error code or HTTP status carried by ERR."
  (let ((value (caddr err)))
    (and (integerp value) value)))

(defun sspai--api-error-not-found-p (err)
  "Return non-nil when ERR means the article does not exist."
  (memq (sspai--api-error-code-or-status err) '(404 3004)))

(defun sspai--definite-api-rejection-p (err)
  "Return non-nil when ERR contains a server rejection code.
Transport failures have no numeric code and therefore remain ambiguous."
  (let ((code (sspai--api-error-code-or-status err))
        (kind (nth 4 err)))
    (and (integerp code)
         (or (eq kind 'envelope)
             (and (eq kind 'http) (<= 400 code) (< code 500)
                  (/= code 408))))))

(defun sspai--article-get (id &optional allow-missing)
  "Get and normalize article ID.
Return nil for a missing article when ALLOW-MISSING is non-nil."
  (setq id (sspai--integer "article id" id))
  (condition-case err
      (sspai--normalize-article
       (sspai--api-data
        "GET"
        "/matrix/editor/article/single/info/get"
        `((id . ,id))))
    (sspai-api-error
     (if (and allow-missing (sspai--api-error-not-found-p err))
         nil
       (signal (car err) (cdr err))))))

(defun sspai--article-add (payload)
  "Create and normalize one draft with exact add PAYLOAD.
Creation is non-idempotent.  An ambiguous transport result is never retried."
  (condition-case err
      (sspai--normalize-article
       (sspai--api-data
        "POST" "/matrix/editor/article/add" nil payload))
    (sspai-api-error
     (if (sspai--definite-api-rejection-p err)
         (signal (car err) (cdr err))
       (signal
        'sspai-create-result-unknown
        (list
         (concat
          "新建少数派草稿的结果未知；请先在网页写作后台确认是否已创建，"
          "不要直接重试，以免产生重复草稿。")))))
    (error
     ;; A malformed success response may still follow an accepted create.
     (signal
      'sspai-create-result-unknown
      (list
       (concat
        "少数派可能已经创建草稿，但响应无法确认；请先检查网页后台。"
        (error-message-string err)))))))

(defun sspai--article-auto-save (payload)
  "Send exact auto-save PAYLOAD."
  (sspai--api-data
   "POST" "/matrix/editor/article/auto/save" nil payload))

(defun sspai--article-update (payload)
  "Send a complete article update PAYLOAD."
  (sspai--api-data
   "POST" "/matrix/editor/article/update" nil payload))

(defun sspai--tag-payloads (source-tags remote)
  "Map SOURCE-TAGS to (STANDARD . CUSTOM) JSON vectors.
Only standard tag objects already present in REMOTE can be retained safely;
new names become custom tags because the standard API requires server IDs."
  (let ((remaining (copy-sequence source-tags))
        standard)
    (when remote
      (dolist (tag (append (plist-get remote :standard-tags) nil))
        (let ((title (sspai--tag-title tag)))
          (when (member title remaining)
            (push (copy-tree tag t) standard)
            (setq remaining (delete title remaining))))))
    (cons (vconcat (nreverse standard))
          (vconcat remaining))))

(defun sspai--article-add-payload (meta html banner-pair)
  "Return the exact non-idempotent add payload for META, HTML and BANNER-PAIR."
  (let* ((title
          (sspai--required-string "title" (plist-get meta :title)))
         (tags (sspai--tag-payloads (plist-get meta :tags) nil)))
    `((type . 4)
      (banner . ,(or (car-safe banner-pair) ""))
      (banner_id . ,(or (cdr-safe banner-pair) 0))
      (title . ,title)
      (title_last . ,title)
      (body . ,html)
      (body_last . ,html)
      (allow_comment
       . ,(sspai--bool-json
           (plist-get meta :allow-comment)))
      (tags . ,(car tags))
      (custom_tags . ,(cdr tags))
      (delete_status . :json-false))))

(defun sspai--article-auto-save-payload (remote title html)
  "Return the exact auto-save payload for REMOTE, TITLE, and HTML."
  (let ((token (plist-get remote :token)))
    (unless (and (stringp token) (not (string-empty-p token)))
      (signal 'sspai-api-error
              (list "article 响应缺少本次更新所需的编辑 token")))
    `((id . ,(plist-get remote :id))
      (token . ,token)
      (title_last . ,title)
      (body_last . ,html)
      (update_at . ,(floor (float-time))))))

(defun sspai--full-update-payload
    (remote meta html banner-pair action)
  "Return a complete update object based on REMOTE.
META, HTML, BANNER-PAIR, and ACTION supply intentional edits while all unknown
service fields and the transient article token are preserved."
  (unless (memq action '(community audit))
    (error "sspai: 未知写入动作：%S" action))
  (let* ((raw (copy-tree (plist-get remote :raw) t))
         (title
          (sspai--required-string "title" (plist-get meta :title)))
         (tag-payloads
          (sspai--tag-payloads (plist-get meta :tags) remote))
         (target-type
          (pcase action
            ('community 5)
            ('audit 2))))
    (unless (and (listp raw)
                 (memq (plist-get remote :type)
                       sspai--editable-types)
                 (plist-get remote :free))
      (user-error "sspai: 当前远端状态不可编辑"))
    (unless (and (stringp (plist-get remote :token))
                 (not (string-empty-p
                       (plist-get remote :token))))
      (signal 'sspai-api-error
              (list "article 响应缺少本次更新所需的编辑 token")))
    (setf (alist-get 'type raw) target-type
          (alist-get 'banner raw) (or (car banner-pair) "")
          (alist-get 'banner_id raw) (or (cdr banner-pair) 0)
          (alist-get 'title_last raw) title
          (alist-get 'body_last raw) html
          (alist-get 'allow_comment raw)
          (sspai--bool-json (plist-get meta :allow-comment))
          (alist-get 'tags raw) (car tag-payloads)
          (alist-get 'custom_tags raw) (cdr tag-payloads)
          (alist-get 'benefits_statement_on raw)
          (sspai--bool-json (plist-get meta :benefits-statement-on))
          (alist-get 'benefits_statement_id raw)
          (or (plist-get meta :benefits-statement-id) 0)
          (alist-get 'delete_status raw) :json-false)
    ;; Editorial review leaves the currently published content in place.
    (when (eq action 'community)
      (setf (alist-get 'title raw) title
            (alist-get 'body raw) html))
    raw))

(defun sspai--update-core (object action)
  "Return the intentional update fields from article OBJECT for ACTION."
  (let ((tags (alist-get 'tags object))
        (custom-tags
         (alist-get 'custom_tags object)))
    `((type . ,(alist-get 'type object))
      (banner
       . ,(sspai--canonical-banner-key
           (alist-get 'banner object)))
      (banner_id . ,(or (alist-get 'banner_id object) 0))
      (title_last . ,(or (alist-get 'title_last object)
                         ""))
      (body_last . ,(or (alist-get 'body_last object)
                        ""))
      (allow_comment
       . ,(sspai--bool-json
           (sspai--boolean
            "article.allow_comment"
            (alist-get 'allow_comment object)
            t)))
      (tags . ,(sspai--standard-tag-summary tags))
      (custom_tags . ,(vconcat custom-tags))
      (benefits_statement_on
       . ,(sspai--bool-json
           (sspai--boolean
            "article.benefits_statement_on"
            (alist-get 'benefits_statement_on object)
            nil)))
      (benefits_statement_id
       . ,(or (alist-get 'benefits_statement_id object) 0))
      (delete_status
       . ,(sspai--bool-json
           (sspai--boolean
            "article.delete_status"
            (alist-get 'delete_status object)
            nil)))
      ,@(when (eq action 'community)
          `((title . ,(or (alist-get 'title object)
                          ""))
            (body . ,(or (alist-get 'body object)
                         "")))))))

(defun sspai--auto-save-confirmed (remote title html)
  "Auto-save TITLE and HTML for REMOTE, recovering only by a confirming GET."
  (let ((payload
         (sspai--article-auto-save-payload remote title html))
        original-error)
    (condition-case err
        (sspai--article-auto-save payload)
      (sspai-api-error
       (if (sspai--definite-api-rejection-p err)
           (signal (car err) (cdr err))
         (setq original-error err))))
    (if (null original-error)
        remote
      (let ((fetched
             (condition-case nil
                 (sspai--article-get (plist-get remote :id))
               (error nil))))
        (if (and fetched
                 (string-equal title (plist-get fetched :title))
                 (string-equal html (plist-get fetched :body)))
            fetched
          (signal (car original-error) (cdr original-error)))))))

(defun sspai--update-matches-p (remote payload action)
  "Whether REMOTE confirms PAYLOAD for ACTION, allowing server moderation.
SSPAI may route an immediate community publication into its audit queue.
Only that status transition is allowed; every other requested field must match."
  (let ((actual (sspai--update-core (plist-get remote :raw) action))
        (expected (sspai--update-core payload action)))
    (or (equal actual expected)
        (and (eq action 'community)
             (eql (alist-get 'type expected) 5)
             (memq (alist-get 'type actual) '(1 2))
             (equal (assq-delete-all 'type actual)
                    (assq-delete-all 'type expected))))))

(defun sspai--full-update-confirmed (remote payload action)
  "Update REMOTE with PAYLOAD and confirm canonical state for ACTION."
  (let (original-error)
    (condition-case err
        (sspai--article-update payload)
      (sspai-api-error
       (if (sspai--definite-api-rejection-p err)
           (signal (car err) (cdr err))
         (setq original-error err))))
    (let ((fetched
           (condition-case nil
               (sspai--article-get (plist-get remote :id))
             (error nil))))
      (cond
       ((and fetched (sspai--update-matches-p fetched payload action))
        fetched)
       (original-error
        (signal (car original-error) (cdr original-error)))
       ((null fetched)
        (signal
         'sspai-published-but-not-checkpointed
         (list
          (concat
           "少数派已接受 article update，但无法读回确认；"
           "请先在网页后台检查，不要直接重发。"))))
       (t
        (signal
         'sspai-published-but-not-checkpointed
         (list
          (concat
           "少数派已接受 article update，但读回内容与请求不一致；"
           "请先在网页后台检查，不要直接重发。"))))))))

;;;; In-flight source checks and publication state

(defun sspai--assert-source-unchanged (file meta)
  "Refuse a checkpoint if FILE or its visiting buffer changed since META was read."
  (when (or (when-let* ((buffer (find-buffer-visiting file)))
              (buffer-modified-p buffer))
            (not (equal (plist-get meta :source-text)
                        (sspai--read-file-text file))))
    (signal 'sspai-source-changed
            '("网络操作期间源稿发生变化；拒绝覆盖新内容"))))

(defun sspai--state (file)
  "Read local source FILE and fetch its current remote article, if tracked."
  (pcase-let* ((`(,meta ,raw-body) (sspai--read-source file))
               (id (plist-get meta :id))
               (remote (and id (sspai--article-get id t))))
    (list :status (cond ((null id) 'new)
                        ((null remote) 'remote-deleted)
                        (t 'tracked))
          :meta meta :raw-body raw-body :remote remote)))

(defun sspai--status-label (status)
  "Return a Chinese label for article tracking STATUS."
  (pcase status
    ('new "尚未发布")
    ('tracked "已关联远端文章，以本地稿件为准")
    ('remote-deleted "远端文章不存在或已删除")
    (_ (format "%S" status))))

(defun sspai--current-source-file ()
  "Return the saved, checkpoint-capable current SSPAI source file."
  (unless buffer-file-name
    (user-error "sspai: 当前 buffer 没有关联文件"))
  (when (buffer-modified-p)
    (user-error "sspai: 请先保存当前源稿"))
  (let ((file (expand-file-name buffer-file-name)))
    (sspai--validate-source-file file)
    (when (file-remote-p file)
      (user-error "sspai: 发布不支持远程源稿"))
    (when (file-symlink-p file)
      (user-error "sspai: 拒绝从符号链接源稿发布"))
    (unless (and (file-exists-p file)
                 (file-regular-p file)
                 (file-readable-p file)
                 (file-writable-p file)
                 (file-writable-p
                  (file-name-directory file)))
      (user-error "sspai: 源稿必须是本地可读写普通文件"))
    file))

(defun sspai--publication-meta (meta remote)
  "Copy local META and record REMOTE identity and publication status only."
  (let ((updated (copy-sequence meta)))
    (setf (plist-get updated :id) (plist-get remote :id)
          (plist-get updated :status) (plist-get remote :status))
    updated))

(defun sspai--checkpoint-pushed
    (file expected-meta remote)
  "Checkpoint REMOTE after a successful write to FILE."
  (let ((updated
         (sspai--publication-meta expected-meta remote)))
    (condition-case err
        (sspai--write-source file updated)
      (error
       (signal
        'sspai-published-but-not-checkpointed
        (list
         (concat
          (format "少数派文章 %s 已写入，但本地状态保存失败；"
                  (plist-get remote :id))
          "请勿直接重发。"
          (error-message-string err))))))
    updated))

;;;; Publication commands

(defun sspai--write-result-label (action remote)
  "Describe the confirmed result of ACTION from REMOTE."
  (if (and (eq action 'community)
           (memq (plist-get remote :type) '(1 2)))
      "提交（少数派已转入审核，尚未公开）"
    (sspai--action-label action)))

(defun sspai--validate-write-meta (meta)
  "Validate user-editable META before any remote side effect."
  (let ((title
         (sspai--required-string "title"
                                 (plist-get meta :title))))
    (when (and (plist-get meta :benefits-statement-on)
               (not (> (or
                        (plist-get meta
                                   :benefits-statement-id)
                        0)
                       0)))
      (user-error
       "sspai: 开启利益相关声明时必须设置正整数 statement id"))
    (when (> (string-width title) sspai-title-width-limit)
      (message
       "sspai: 标题显示宽度为 %d，超过建议值 %d"
       (string-width title) sspai-title-width-limit))
    title))

(defun sspai--prepare-write-assets (file meta raw-body)
  "Convert and upload FILE assets described by META and RAW-BODY.
Return (HTML BANNER-PAIR).  Every new upload is checkpointed immediately."
  (let* ((html
          (sspai--source-to-html file raw-body))
         (checkpoint
          (lambda ()
            (sspai--write-source file meta)))
         (rewritten
          (sspai--rewrite-body-images
           html
           (file-name-directory (expand-file-name file))
           (plist-get meta :image-cache)
           checkpoint))
         (banner-pair
          (sspai--prepare-banner file meta checkpoint)))
    (sspai--assert-source-unchanged file meta)
    (list rewritten banner-pair)))

(defun sspai--remote-editable-p (remote)
  "Return non-nil when REMOTE is currently writable."
  (and remote
       (memq (plist-get remote :type)
             sspai--editable-types)
       (plist-get remote :free)
       (not (plist-get remote :delete-status))))

(defun sspai--action-label (action)
  "Return a Chinese label for article ACTION."
  (pcase action
    ('community "发布到 Matrix 社区")
    ('audit "提交编辑审核")
    (_ (format "%S" action))))

(defun sspai--write-state (file state action)
  "Execute ACTION for FILE, always publishing its local content from STATE."
  (unless (memq action '(community audit))
    (user-error "sspai: 仅支持立即发布或投稿编辑部"))
  (let* ((status (plist-get state :status))
         (meta (plist-get state :meta))
         (raw-body (plist-get state :raw-body))
         (remote (plist-get state :remote)))
    (when (eq status 'remote-deleted)
      (user-error
       (concat
        "sspai: 远端文章不存在；不会沿用旧 ID 新建，"
        "请先在网页后台确认或另建源稿")))
    (when (and remote (not (sspai--remote-editable-p remote)))
      (user-error
       "sspai: 远端 type=%s/free=%s 已锁定，不能更新"
       (plist-get remote :type)
       (if (plist-get remote :free) "true" "false")))
    (sspai--validate-write-meta meta)
    (pcase-let* ((`(,html ,banner-pair)
                  (sspai--prepare-write-assets
                   file meta raw-body))
                 (title (plist-get meta :title)))
      (unless remote
        ;; Save the ID before follow-up requests so retries update this article.
        (setq remote (sspai--article-add
                      (sspai--article-add-payload meta html banner-pair))
              meta (sspai--checkpoint-pushed file meta remote)))
      (let* ((saved (sspai--auto-save-confirmed remote title html))
             (payload (sspai--full-update-payload
                       saved meta html banner-pair action))
             (written (sspai--full-update-confirmed saved payload action)))
        (sspai--checkpoint-pushed file meta written)
        (message "sspai: 已%s并保存发布状态"
                 (sspai--write-result-label action written))
        written))))

;;;###autoload
(defun sspai-publish-community ()
  "Publish the current local source to the SSPAI Matrix community."
  (interactive)
  (let* ((file (sspai--current-source-file))
         (state (sspai--state file)))
    (sspai--write-state file state 'community)))

;;;###autoload
(defun sspai-submit-for-review ()
  "Submit the current source for SSPAI editorial review.
The resulting audit state is locked by the service."
  (interactive)
  (let* ((file (sspai--current-source-file))
         (state (sspai--state file)))
    (sspai--write-state file state 'audit)))

;;;###autoload
(defun sspai-status ()
  "Show remote article tracking and Matrix editor status for the current source."
  (interactive)
  (let* ((file (sspai--current-source-file))
         (state (sspai--state file))
         (status (plist-get state :status))
         (remote (plist-get state :remote)))
    (message
     "sspai: %s%s"
     (sspai--status-label status)
     (if remote
         (format "；type=%s (%s)，free=%s"
                 (plist-get remote :type)
                 (plist-get remote :status)
                 (if (plist-get remote :free)
                     "true" "false"))
       ""))
    status))

;;;; Creating local Org sources

;;;###autoload
(defun sspai-new-article (file &optional title)
  "Create a new Org SSPAI source FILE with optional TITLE."
  (interactive
   (list
    (read-file-name
     "少数派源稿（.org）: "
     default-directory nil nil)))
  (sspai--create-source
   file title)
  (message "sspai: 已创建文章源稿：%s" file))

(provide 'sspai)

;;; sspai.el ends here
