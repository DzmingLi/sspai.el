;;; sspai.el --- Write and publish local SSPAI articles  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Dzming Li

;; Author: Dzming Li <i@dzming.li>
;; Maintainer: Dzming Li <i@dzming.li>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (yaml "1.2.4") (firefox-cookies "0.1.0"))
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

;; Write SSPAI articles in Markdown or Org, upload local body images and the
;; document's generic `banner' image, save drafts, publish to the community,
;; submit for editorial review, and update existing articles from local sources.
;;
;; This client targets SSPAI's Matrix editor API.  It deliberately
;; keeps the account Bearer token, per-article token, and Qiniu upload token
;; separate.  Account credentials are read through `firefox-cookies' by default
;; and are never written into a source document.
;;
;; Markdown metadata:
;;
;;   ---
;;   title: "Example"
;;   banner: "./banner.png"
;;   tags: ["Emacs", "效率"]
;;   sspai:
;;     status: "draft"
;;   ---
;;
;; Org uses #+TITLE, the platform-neutral #+BANNER and #+FILETAGS, plus
;; #+SSPAI_* keywords for publication state and image upload metadata.

;;; Code:

(require 'auth-source)
(require 'cl-lib)
(require 'dom)
(require 'firefox-cookies)
(require 'json)
(require 'mailcap)
(require 'org)
(require 'subr-x)
(require 'url)
(require 'url-cookie)
(require 'url-http)
(require 'url-parse)
(require 'url-util)
(require 'xml)
(require 'yaml)

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

(defcustom sspai-api-base-url "https://sspai.com/api/v1"
  "Base URL of the authorized SSPAI editor API.
It must be an HTTPS URL without a query or fragment."
  :type 'string
  :group 'sspai)

(defcustom sspai-site-base-url "https://sspai.com"
  "Public SSPAI site origin used to construct article and preview URLs."
  :type 'string
  :group 'sspai)

(defcustom sspai-upload-url "https://upload.qiniup.com/"
  "Qiniu upload URL returned by the current SSPAI editor contract.
The SSPAI Bearer token is never sent to this URL."
  :type 'string
  :group 'sspai)

(defcustom sspai-cdn-base-url "https://cdnfile.sspai.com"
  "Base URL used to turn an SSPAI attachment key into a public URL."
  :type 'string
  :group 'sspai)

(defcustom sspai-access-token nil
  "Authorized SSPAI editor Bearer token for the current Emacs session.
When nil, use `sspai-cookie-function' to read the Firefox login token.
When both are nil, look in `auth-source' for an entry whose host matches
`sspai-api-base-url', user is \"sspai.el\", and port is \"https\"."
  :type '(choice (const :tag "Use Firefox cookies or auth-source" nil)
                 (string :tag "Bearer token"))
  :group 'sspai)

(defcustom sspai-cookie-function #'firefox-cookies-get
  "Function called with an API URL to read its applicable cookies.
Return an alist of (NAME . VALUE) strings, as `firefox-cookies-get' does.
The sspai_jwt_token cookie supplies the API Bearer token; other cookies are
not sent.  Configure `firefox-cookies-profile-directory' explicitly and log
in to SSPAI in that Firefox profile.  Cookies are read afresh for each request.
Set this to nil to use `auth-source' instead.  A non-nil `sspai-access-token'
takes precedence over this function."
  :type '(choice (const :tag "Use auth-source" nil) function)
  :group 'sspai)

(defcustom sspai-request-timeout 30
  "Timeout in seconds for one SSPAI or Qiniu HTTP request."
  :type 'integer
  :group 'sspai)

(defcustom sspai-confirm-before-write t
  "When non-nil, ask before changing a remote SSPAI article."
  :type 'boolean
  :group 'sspai)

(defcustom sspai-upload-local-images t
  "When non-nil, upload local images referenced by article HTML."
  :type 'boolean
  :group 'sspai)

(defcustom sspai-maximum-image-size (* 5 1024 1024)
  "Largest image, in bytes, that `sspai.el' will upload."
  :type 'integer
  :group 'sspai)

(defcustom sspai-recommended-image-size (* 2 1024 1024)
  "Image size above which `sspai.el' emits a quality warning.
The web editor currently accepts files up to
`sspai-maximum-image-size', while the official creation guide recommends
keeping body images within 2 MB."
  :type 'integer
  :group 'sspai)

(defcustom sspai-banner-standard-size '(1420 . 708)
  "Official SSPAI banner size as (WIDTH . HEIGHT), in pixels.
The central HEIGHT by HEIGHT square is the documented safe area."
  :type '(cons integer integer)
  :group 'sspai)

(defcustom sspai-shift-heading-level t
  "When non-nil, shift source headings down one level for the article body.
The article title occupies the page's h1, so source h1 headings become h2."
  :type 'boolean
  :group 'sspai)

(defcustom sspai-title-width-limit 32
  "Displayed title width at which `sspai.el' warns before a write."
  :type 'integer
  :group 'sspai)

;;;; Constants and data structures

(defconst sspai--status-to-type
  '(("draft" . 4)
    ("published" . 5)
    ("community" . 5)
    ("audit" . 2)
    ("review" . 2)))

(defconst sspai--type-to-status
  '((0 . "featured")
    (1 . "audit")
    (2 . "audit")
    (4 . "draft")
    (5 . "published")))

(defconst sspai--editable-types '(4 5))

(defconst sspai--hash-regexp "\\`[[:xdigit:]]\\{64\\}\\'")

(defconst sspai--org-owned-keywords
  '("SSPAI_ID"
    "SSPAI_STATUS"
    "SSPAI_ALLOW_COMMENT"
    "SSPAI_BENEFITS_STATEMENT_ON"
    "SSPAI_BENEFITS_STATEMENT_ID"
    "SSPAI_BANNER_ID"
    "SSPAI_BANNER_KEY"
    "SSPAI_BANNER_HASH"
    "SSPAI_IMAGE_CACHE"))

(defconst sspai--missing (make-symbol "sspai--missing"))

(cl-defstruct (sspai--response
               (:constructor sspai--make-response))
  status
  headers
  body
  url)

;;;; Generic value helpers

(defun sspai--object-get (object key)
  "Return KEY from JSON/YAML OBJECT represented as an alist or hash table."
  (cond
   ((hash-table-p object)
    (let ((value (gethash key object sspai--missing)))
      (if (eq value sspai--missing)
          (gethash (symbol-name key) object)
        value)))
   ((listp object)
    (let ((cell (or (assq key object)
                    (assoc (symbol-name key) object))))
      (cdr cell)))
   (t nil)))

(defun sspai--object-member-p (object key)
  "Return non-nil when OBJECT explicitly contains KEY."
  (cond
   ((hash-table-p object)
    (or (not (eq (gethash key object sspai--missing) sspai--missing))
        (not (eq (gethash (symbol-name key) object sspai--missing)
                 sspai--missing))))
   ((listp object)
    (or (assq key object) (assoc (symbol-name key) object)))
   (t nil)))

(defun sspai--object-set (object key value)
  "Set KEY to VALUE in alist OBJECT and return OBJECT."
  (setf (alist-get key object) value)
  object)

(defun sspai--value-string (value)
  "Return scalar VALUE as a string, or nil for compound values."
  (cond
   ((null value) nil)
   ((stringp value) value)
   ((symbolp value) (symbol-name value))
   ((numberp value) (number-to-string value))
   (t nil)))

(defun sspai--required-string (field value)
  "Normalize VALUE as a required non-empty string for FIELD."
  (let ((text (and (sspai--value-string value)
                   (string-trim (sspai--value-string value)))))
    (unless (and text (not (string-empty-p text)))
      (user-error "sspai: %s 必须是非空字符串" field))
    text))

(defun sspai--optional-string (field value)
  "Normalize VALUE as an optional non-empty string for FIELD."
  (if (null value)
      nil
    (sspai--required-string field value)))

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
   ((or (eq value t)
        (and (stringp value)
             (member (downcase value) '("true" "yes" "on" "1"))))
    t)
   ((or (eq value :json-false)
        (and (stringp value)
             (member (downcase value) '("false" "no" "off" "0"))))
    nil)
   (t (user-error "sspai: %s 必须是 true 或 false" field))))

(defun sspai--bool-json (value)
  "Return VALUE in the representation expected by `json-serialize'."
  (if value t :json-false))

(defun sspai--yaml-string (value)
  "Quote VALUE as a JSON string, which is also a valid YAML scalar."
  (json-serialize (or value "")))

(defun sspai--trim-body (body)
  "Normalize BODY line endings and its final newline.
Leading whitespace, including indentation on the first line, is preserved."
  (let ((text (replace-regexp-in-string
               "\r\n?\\|\n" "\n" (or body "") t t)))
    (concat (replace-regexp-in-string "\n+\\'" "" text) "\n")))

(defun sspai--hash-json (object)
  "Return a stable SHA-256 hash of fixed-order alist OBJECT."
  (secure-hash
   'sha256
   (encode-coding-string
    (json-serialize object :null-object nil :false-object :json-false)
    'utf-8 t)))

;;;; URL and authentication

(defun sspai--normalize-base-url (&optional value)
  "Validate and normalize API base URL VALUE."
  (let* ((raw (string-trim (or value sspai-api-base-url "")))
         (parsed (url-generic-parse-url raw))
         (scheme (downcase (or (url-type parsed) "")))
         (host (url-host parsed))
         (port (url-port parsed))
         (file (or (url-filename parsed) "")))
    (unless (and (string-equal scheme "https")
                 (stringp host)
                 (not (string-empty-p host))
                 (not (url-user parsed))
                 (not (string-match-p "[?#]" raw))
                 (or (null port)
                     (and (integerp port) (< 0 port 65536)))
                 (or (string-empty-p file)
                     (string-prefix-p "/" file)))
      (user-error "sspai: API base 必须是 HTTPS URL：%s" raw))
    (replace-regexp-in-string "/+\\'" "" raw)))

(defun sspai--normalize-origin (field value)
  "Validate FIELD VALUE as an HTTPS origin and return it without trailing slash."
  (let* ((raw (string-trim (or value "")))
         (parsed (url-generic-parse-url raw))
         (scheme (downcase (or (url-type parsed) "")))
         (host (url-host parsed))
         (port (url-port parsed))
         (file (or (url-filename parsed) "")))
    (unless (and (string-equal scheme "https")
                 host
                 (not (url-user parsed))
                 (or (null port)
                     (and (integerp port) (< 0 port 65536)))
                 (member file '("" "/"))
                 (not (string-match-p "[?#]" raw)))
      (user-error "sspai: %s 必须是 HTTPS origin：%s" field raw))
    (replace-regexp-in-string "/+\\'" "" raw)))

(defun sspai--api-host ()
  "Return the configured SSPAI API host."
  (url-host (url-generic-parse-url (sspai--normalize-base-url))))

(defun sspai--api-url (path)
  "Return absolute configured API URL for relative PATH."
  (unless (and (stringp path) (string-prefix-p "/" path))
    (error "sspai: API path 必须以 / 开头：%S" path))
  (concat (sspai--normalize-base-url) path))

(defun sspai--site-url (path)
  "Return absolute SSPAI site URL for PATH."
  (concat (sspai--normalize-origin "site base" sspai-site-base-url)
          (if (string-prefix-p "/" path) "" "/")
          path))

(defun sspai--secret-value (secret)
  "Return SECRET, calling it when auth-source supplied a thunk."
  (if (functionp secret) (funcall secret) secret))

(defun sspai--access-token (&optional url)
  "Return the authorized SSPAI editor Bearer token for API URL.
Read browser credentials on each call, without caching or persisting them."
  (let ((direct (and (stringp sspai-access-token)
                     (string-trim sspai-access-token))))
    (cond
     ((and direct (not (string-empty-p direct))) direct)
     (sspai-cookie-function
      (let* ((cookies (funcall sspai-cookie-function
                               (or url (sspai--api-url "/"))))
             (value (cdr (assoc "sspai_jwt_token" cookies))))
        (unless (and (stringp value)
                     (not (string-empty-p (string-trim value))))
          (user-error
           (concat "sspai: Firefox 中没有有效的少数派登录 Cookie；"
                   "请在配置的 Firefox profile 中登录 sspai.com")))
        (let ((token (url-unhex-string value t)))
          (when (or (string-empty-p (string-trim token))
                    (string-match-p "[\r\n]" token))
            (user-error "sspai: Firefox 登录 token 格式无效，请重新登录"))
          (string-trim token))))
     (t
      (let* ((entry
              (car
               (auth-source-search
                :host (sspai--api-host)
                :user "sspai.el"
                :port "https"
                :require '(:secret)
                :max 1)))
             (secret (and entry
                          (sspai--secret-value
                           (plist-get entry :secret)))))
        (unless (and (stringp secret)
                     (not (string-empty-p (string-trim secret))))
          (user-error
           (concat
            "sspai: 未找到 Bearer token；请设置 sspai-access-token，"
            "或在 auth-source 中保存 machine %s login sspai.el password TOKEN")
           (sspai--api-host)))
        (string-trim secret))))))

;;;; HTTP and API envelopes

(defun sspai--header-value (headers name)
  "Return NAME from response HEADERS, ignoring case."
  (cdr (assoc-string name headers t)))

(defun sspai--parse-response-headers ()
  "Parse HTTP response headers in the current URL buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((end (or (and (boundp 'url-http-end-of-headers)
                        url-http-end-of-headers)
                   (progn
                     (re-search-forward "\r?\n\r?\n" nil t)
                     (point))))
          headers)
      (forward-line 1)
      (while (and end (< (point) end)
                  (re-search-forward
                   "^\\([^:\r\n]+\\):[ \t]*\\([^\r\n]*\\)" end t))
        (push (cons (downcase (match-string 1))
                    (string-trim (match-string 2)))
              headers))
      (nreverse headers))))

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
Bearer token and is only accepted for configured API URLs.  Cookies and
automatic redirects are disabled.  REDACT is a list of additional transient
secrets that must not appear in a transport error."
  (when auth
    (unless (string-prefix-p
             (concat (sspai--normalize-base-url) "/") url)
      (error "sspai: 拒绝向 API base 之外发送 Bearer token：%s" url)))
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
           :headers (sspai--parse-response-headers)
           :body (sspai--buffer-response-body)
           :url url))
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
           (or (sspai--object-get json 'msg)
               (sspai--object-get json 'message)
               (let ((value (sspai--object-get json 'error)))
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
                             (sspai--object-get payload 'token))))
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
    (let ((error-code (sspai--object-get json 'error)))
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
  (sspai--object-get
   (sspai--api-request
    method path :query query :payload payload)
   'data))

;;;; Source metadata

(defun sspai--file-format (file)
  "Return source format symbol for FILE."
  (pcase (downcase (or (file-name-extension file) ""))
    ((or "md" "markdown") 'markdown)
    ("org" 'org)
    (_ (user-error "sspai: 仅支持 .md、.markdown 和 .org 源稿"))))

(defun sspai--read-file-text (file)
  "Read UTF-8 source FILE as text."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun sspai--normalize-status (value &optional default)
  "Normalize status VALUE, using DEFAULT when VALUE is absent."
  (let ((text (downcase
               (or (sspai--value-string value)
                   default
                   "draft"))))
    (pcase text
      ("draft" "draft")
      ((or "published" "community") "published")
      ((or "audit" "review") "audit")
      ("featured" "featured")
      (_ (user-error
          "sspai: status 必须是 draft、published 或 audit：%s"
          text)))))

(defun sspai--status-type (status)
  "Return Matrix editor numeric type for STATUS."
  (or (cdr (assoc (sspai--normalize-status status)
                  sspai--status-to-type))
      (user-error "sspai: 状态 %s 不能用于写入" status)))

(defun sspai--type-status (type)
  "Return local status string for Matrix editor TYPE."
  (or (cdr (assq type sspai--type-to-status))
      (format "type-%s" type)))

(defun sspai--normalize-tags (value)
  "Normalize YAML/Org tag VALUE into a duplicate-free string list."
  (let ((items
         (cond
          ((null value) nil)
          ((stringp value)
           (let ((trimmed (string-trim value)))
             (cond
              ((string-empty-p trimmed) nil)
              ((and (string-prefix-p ":" trimmed)
                    (string-suffix-p ":" trimmed))
               (split-string trimmed ":" t "[ \t\n]+"))
              (t
               (split-string trimmed "[,，]" t "[ \t\n]+")))))
          ((vectorp value) (append value nil))
          ((listp value) value)
          (t (user-error "sspai: tags 必须是字符串或列表"))))
        normalized)
    (dolist (item items)
      (let ((text (sspai--required-string "tag" item)))
        (unless (member text normalized)
          (push text normalized))))
    (nreverse normalized)))

(defun sspai--normalize-image-cache (value)
  "Normalize image cache VALUE to an equal hash table."
  (let ((table (make-hash-table :test #'equal)))
    (cond
     ((null value))
     ((hash-table-p value)
      (maphash
       (lambda (key url)
         (let ((key (downcase
                     (sspai--required-string "image-cache key" key)))
               (url (sspai--required-string "image-cache URL" url)))
           (unless (string-match-p sspai--hash-regexp key)
             (user-error "sspai: 无效 image-cache key：%s" key))
           (unless (string-match-p "\\`https://" url)
             (user-error "sspai: image-cache URL 必须使用 HTTPS：%s" url))
           (puthash key url table)))
       value))
     ((listp value)
      (dolist (entry value)
        (let ((key
               (downcase
                (sspai--required-string "image-cache key" (car entry))))
              (url
               (sspai--required-string "image-cache URL" (cdr entry))))
          (unless (string-match-p sspai--hash-regexp key)
            (user-error "sspai: 无效 image-cache key：%s" key))
          (unless (string-match-p "\\`https://" url)
            (user-error "sspai: image-cache URL 必须使用 HTTPS：%s" url))
          (puthash key url table))))
     (t (user-error "sspai: image-cache 必须是 mapping/object")))
    table))

(defun sspai--meta-from-object (object title banner tags)
  "Normalize SSPAI metadata OBJECT and generic TITLE, BANNER, TAGS."
  (unless (or (null object) (listp object) (hash-table-p object))
    (user-error "sspai: sspai metadata 必须是 mapping/object"))
  (let* ((id (sspai--integer "id" (sspai--object-get object 'id)))
         (status (sspai--normalize-status
                  (sspai--object-get object 'status) "draft"))
         (allow-comment
          (sspai--boolean
           "allow-comment"
           (sspai--object-get object 'allow-comment)
           t))
         (benefits-on
          (sspai--boolean
           "benefits-statement-on"
           (sspai--object-get object 'benefits-statement-on)
           nil))
         (benefits-id
          (or (sspai--integer
               "benefits-statement-id"
               (sspai--object-get object 'benefits-statement-id)
               t)
              0))
         (banner-id
          (or (sspai--integer
               "banner-id"
               (sspai--object-get object 'banner-id)
               t)
              0))
         (banner-key
          (sspai--optional-string
           "banner-key" (sspai--object-get object 'banner-key)))
         (banner-hash
          (sspai--optional-string
           "banner-hash" (sspai--object-get object 'banner-hash)))
         (image-cache
          (sspai--normalize-image-cache
           (sspai--object-get object 'image-cache)))
         ;; An empty title is useful in a newly-created local template.  It is
         ;; rejected only when a remote write is prepared.
         (title
          (cond
           ((null title) nil)
           ((sspai--value-string title)
            (string-trim (sspai--value-string title)))
           (t (user-error "sspai: title 必须是字符串"))))
         (banner (sspai--optional-string "banner" banner))
         (tags (sspai--normalize-tags tags)))
    (dolist (hash (delq nil (list banner-hash)))
      (unless (string-match-p sspai--hash-regexp hash)
        (user-error "sspai: hash 格式无效：%s" hash)))
    (when (and banner-key (zerop banner-id))
      ;; A body attachment URL has no usable banner attachment id.
      (user-error "sspai: banner-key 存在时必须同时保存 banner-id"))
    (when (and benefits-on (zerop benefits-id))
      (user-error
       "sspai: 开启利益相关声明时必须设置 benefits-statement-id"))
    (list
     :id id
     :url (and id (sspai--site-url (format "/post/%d" id)))
     :status status
     :title title
     :banner banner
     :tags tags
     :allow-comment allow-comment
     :benefits-statement-on benefits-on
     :benefits-statement-id benefits-id
     :banner-id banner-id
     :banner-key banner-key
     :banner-hash banner-hash
     :image-cache image-cache)))

(defun sspai--md-split-frontmatter (text)
  "Split Markdown TEXT into (FRONTMATTER BODY)."
  (unless (string-match "\\`---[ \t]*\n" text)
    (user-error "sspai: Markdown 源稿必须以 YAML front matter 开头"))
  (let ((start (match-end 0)))
    (unless (string-match "^---[ \t]*\n" text start)
      (user-error "sspai: YAML front matter 缺少结束分隔线"))
    (list (substring text start (match-beginning 0))
          (substring text (match-end 0)))))

(defun sspai--md-meta-and-body (file)
  "Return normalized metadata and raw body for Markdown FILE."
  (pcase-let* ((`(,frontmatter ,body)
                 (sspai--md-split-frontmatter
                  (sspai--read-file-text file)))
                (object
                 (condition-case err
                     (yaml-parse-string
                      frontmatter
                      :object-type 'alist
                      :sequence-type 'list
                      :null-object nil
                      :false-object :json-false)
                   (error
                    (user-error "sspai: YAML metadata 无效：%s"
                                (error-message-string err)))))
                (title (sspai--object-get object 'title))
                (banner (sspai--object-get object 'banner))
                (tags (sspai--object-get object 'tags))
                (sspai-object (sspai--object-get object 'sspai)))
    (list
     (sspai--meta-from-object sspai-object title banner tags)
     ;; The formatter owns one blank line between YAML and body.  Drop that
     ;; structural newline here so repeated checkpoints stay idempotent.
     (if (string-prefix-p "\n" body) (substring body 1) body))))

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

(defun sspai--org-meta-and-body (file)
  "Return normalized metadata and raw body for Org FILE."
  (pcase-let* ((`(,header ,body)
                 (sspai--org-header-and-body
                  (sspai--read-file-text file)))
                (values (sspai--org-header-values header))
                (object
                 `((id . ,(sspai--org-value "SSPAI_ID" values))
                   (status . ,(sspai--org-value "SSPAI_STATUS" values))
                   (allow-comment
                    . ,(sspai--org-value
                        "SSPAI_ALLOW_COMMENT" values))
                   (benefits-statement-on
                    . ,(sspai--org-value
                        "SSPAI_BENEFITS_STATEMENT_ON" values))
                   (benefits-statement-id
                    . ,(sspai--org-value
                        "SSPAI_BENEFITS_STATEMENT_ID" values))
                   (banner-id
                    . ,(sspai--org-value "SSPAI_BANNER_ID" values))
                   (banner-key
                    . ,(sspai--org-value "SSPAI_BANNER_KEY" values))
                   (banner-hash
                    . ,(sspai--org-value "SSPAI_BANNER_HASH" values))
                   (image-cache
                    . ,(sspai--org-image-cache
                        (sspai--org-value
                         "SSPAI_IMAGE_CACHE" values t))))))
    (list
     (sspai--meta-from-object
      object
      (sspai--org-value "TITLE" values)
      (sspai--org-value "BANNER" values)
      (sspai--org-value "FILETAGS" values t))
     body)))

(defun sspai--read-source (file)
  "Return (META RAW-BODY) from FILE."
  (pcase (sspai--file-format file)
    ('markdown (sspai--md-meta-and-body file))
    ('org (sspai--org-meta-and-body file))))

;;;; Source formatting and safe checkpoints

(defun sspai--image-cache-alist (table)
  "Return image cache TABLE as a stable, sorted alist."
  (let (entries)
    (maphash (lambda (key value) (push (cons key value) entries)) table)
    (sort entries (lambda (left right)
                    (string< (car left) (car right))))))

(defun sspai--json-string-object (entries)
  "Serialize string-to-string ENTRIES as a stable JSON object."
  (concat
   "{"
   (mapconcat
    (lambda (entry)
      (concat (json-serialize (car entry))
              ":"
              (json-serialize (cdr entry))))
    entries
    ",")
   "}"))

(defun sspai--format-yaml-tags (tags)
  "Format TAGS as one YAML sequence."
  (if tags
      (concat
       "tags:\n"
       (mapconcat
        (lambda (tag)
          (concat "  - " (sspai--yaml-string tag)))
        tags "\n")
       "\n")
    "tags: []\n"))

(defun sspai--format-yaml-meta (meta)
  "Format normalized META as an owned top-level YAML mapping."
  (let (lines)
    (cl-labels
        ((put-string
          (key value)
          (when value
            (push (format "  %s: %s" key (sspai--yaml-string value))
                  lines)))
         (put-number
          (key value &optional omit-zero)
          (when (and (integerp value)
                     (or (not omit-zero) (not (zerop value))))
            (push (format "  %s: %s" key value) lines)))
         (put-bool
          (key value)
          (push (format "  %s: %s" key (if value "true" "false"))
                lines)))
      (put-number "id" (plist-get meta :id))
      (put-string "status" (plist-get meta :status))
      (unless (plist-get meta :allow-comment)
        (put-bool "allow-comment" nil))
      (put-bool "benefits-statement-on"
                (plist-get meta :benefits-statement-on))
      (put-number "benefits-statement-id"
                  (plist-get meta :benefits-statement-id) t)
      (put-number "banner-id" (plist-get meta :banner-id) t)
      (put-string "banner-key" (plist-get meta :banner-key))
      (put-string "banner-hash" (plist-get meta :banner-hash))
      (when (> (hash-table-count (plist-get meta :image-cache)) 0)
        (push "  image-cache:" lines)
        (dolist (entry
                 (reverse
                  (sspai--image-cache-alist
                   (plist-get meta :image-cache))))
          (push (format "    %s: %s"
                        (car entry)
                        (sspai--yaml-string (cdr entry)))
                lines))))
    (concat
     "sspai:\n"
     (mapconcat #'identity (nreverse lines) "\n")
     "\n")))

(defun sspai--yaml-remove-owned-fields (frontmatter)
  "Remove top-level title, banner, tags, and sspai from FRONTMATTER."
  (let ((lines (split-string frontmatter "\n" nil))
        output skipping)
    (dolist (line lines)
      (let ((top-key
             (and
              (string-match
               "\\`\\([[:alnum:]_-]+\\):\\(?:[ \t].*\\|\\)\\'" line)
              (downcase (match-string 1 line)))))
        (when top-key
          (setq skipping
                (member top-key '("title" "banner" "tags" "sspai"))))
        (unless skipping
          (push line output))))
    (string-trim-right
     (mapconcat #'identity (nreverse output) "\n"))))

(defun sspai--format-markdown-source (old-text meta body)
  "Return Markdown source based on OLD-TEXT, META, and BODY."
  (let* ((parts (sspai--md-split-frontmatter old-text))
         (other (sspai--yaml-remove-owned-fields (car parts))))
    (concat
     "---\n"
     "title: " (sspai--yaml-string (or (plist-get meta :title) "")) "\n"
     (when (plist-get meta :banner)
       (concat "banner: "
               (sspai--yaml-string (plist-get meta :banner))
               "\n"))
     (sspai--format-yaml-tags (plist-get meta :tags))
     (unless (string-empty-p other) (concat other "\n"))
     (sspai--format-yaml-meta meta)
     "---\n\n"
     (sspai--trim-body body))))

(defun sspai--format-org-meta (meta)
  "Format META as owned Org keywords."
  (let (lines)
    (cl-labels
        ((put-string
          (key value)
          (when value
            (push (format "#+SSPAI_%s: %s" key value) lines)))
         (put-number
          (key value &optional omit-zero)
          (when (and (integerp value)
                     (or (not omit-zero) (not (zerop value))))
            (push (format "#+SSPAI_%s: %s" key value) lines)))
         (put-bool
          (key value)
          (push (format "#+SSPAI_%s: %s"
                        key (if value "true" "false"))
                lines)))
      (put-number "ID" (plist-get meta :id))
      (put-string "STATUS" (plist-get meta :status))
      (unless (plist-get meta :allow-comment)
        (put-bool "ALLOW_COMMENT" nil))
      (put-bool "BENEFITS_STATEMENT_ON"
                (plist-get meta :benefits-statement-on))
      (put-number "BENEFITS_STATEMENT_ID"
                  (plist-get meta :benefits-statement-id) t)
      (put-number "BANNER_ID" (plist-get meta :banner-id) t)
      (put-string "BANNER_KEY" (plist-get meta :banner-key))
      (put-string "BANNER_HASH" (plist-get meta :banner-hash))
      (when (> (hash-table-count (plist-get meta :image-cache)) 0)
        (put-string
         "IMAGE_CACHE"
         (sspai--json-string-object
          (sspai--image-cache-alist
           (plist-get meta :image-cache))))))
    (concat (mapconcat #'identity (nreverse lines) "\n") "\n")))

(defun sspai--format-org-source (old-text meta body)
  "Return Org source based on OLD-TEXT, META, and BODY."
  (pcase-let* ((`(,header ,_old-body)
                 (sspai--org-header-and-body old-text))
                (kept
                 (cl-remove-if
                  (lambda (line)
                    (and
                     (string-match
                      "\\`[ \t]*#\\+\\([^: \t\n]+\\):" line)
                     (let ((key (upcase (match-string 1 line))))
                       (or (member key '("TITLE" "BANNER" "FILETAGS"))
                           ;; Rewrite the entire platform namespace.  This is
                           ;; deliberately broader than the known field list:
                           ;; stale/unknown token-like SSPAI fields must never
                           ;; survive a checkpoint.
                           (string-prefix-p "SSPAI_" key)
                           (member key sspai--org-owned-keywords)))))
                  header))
                (kept-text
                 (string-trim
                  (mapconcat #'identity kept "\n"))))
    (concat
     "#+TITLE: " (or (plist-get meta :title) "") "\n"
     (when (plist-get meta :banner)
       (concat "#+BANNER: " (plist-get meta :banner) "\n"))
     "#+FILETAGS: "
     (if (plist-get meta :tags)
         (concat ":"
                 (mapconcat #'identity (plist-get meta :tags) ":")
                 ":")
       "")
     "\n"
     (sspai--format-org-meta meta)
     (unless (string-empty-p kept-text)
       (concat kept-text "\n"))
     "\n"
     (sspai--trim-body body))))

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

(defun sspai--write-source (file meta body)
  "Safely checkpoint FILE with META and BODY."
  (let* ((old-text (sspai--read-file-text file))
         (new-text
          (pcase (sspai--file-format file)
            ('markdown
             (sspai--format-markdown-source old-text meta body))
            ('org
             (sspai--format-org-source old-text meta body)))))
    (sspai--atomic-write-text file new-text)
    (when-let* ((buffer
                (find-buffer-visiting (expand-file-name file))))
      (with-current-buffer buffer
        (unless (buffer-modified-p)
          (revert-buffer t t t))))))

(defun sspai--create-source (file meta body)
  "Create a new source FILE from META and BODY without overwriting."
  (let* ((file (expand-file-name file))
         (format (sspai--file-format file))
         (directory (file-name-directory file))
         text)
    (when (file-remote-p file)
      (user-error "sspai: 新建源稿不支持远程路径"))
    (when (or (file-exists-p file) (file-symlink-p file))
      (user-error "sspai: 目标路径已被占用，拒绝覆盖：%s" file))
    (make-directory directory t)
    (setq text
          (pcase format
            ('markdown
             (concat
              "---\n"
              "title: "
              (sspai--yaml-string (or (plist-get meta :title) ""))
              "\n"
              (when (plist-get meta :banner)
                (concat "banner: "
                        (sspai--yaml-string (plist-get meta :banner))
                        "\n"))
              (sspai--format-yaml-tags (plist-get meta :tags))
              (sspai--format-yaml-meta meta)
              "---\n\n"
              (sspai--trim-body body)))
            ('org
             (concat
              "#+TITLE: " (or (plist-get meta :title) "") "\n"
              (when (plist-get meta :banner)
                (concat "#+BANNER: " (plist-get meta :banner) "\n"))
              "#+FILETAGS: "
              (if (plist-get meta :tags)
                  (concat ":"
                          (mapconcat #'identity
                                     (plist-get meta :tags) ":")
                          ":")
                "")
              "\n"
              (sspai--format-org-meta meta)
              "\n"
              (sspai--trim-body body)))))
    (with-temp-buffer
      (insert text)
      (let ((coding-system-for-write 'utf-8-unix))
        (write-region
         (point-min) (point-max) file nil 'silent nil 'excl)))
    (find-file file)
    file))

;;;; Source conversion

(defun sspai--run-filter (program args input)
  "Run PROGRAM with ARGS over INPUT and return UTF-8 stdout."
  (let ((stderr-file (make-temp-file "sspai-stderr-"))
        (stdout-buffer (generate-new-buffer " *sspai-stdout*")))
    (unwind-protect
        (with-temp-buffer
          (insert input)
          (let ((coding-system-for-write 'utf-8)
                (coding-system-for-read 'utf-8)
                (status
                 (apply
                  #'call-process-region
                  (point-min) (point-max)
                  program nil
                  (list stdout-buffer stderr-file)
                  nil args)))
            (unless (eq status 0)
              (let ((stderr
                     (with-temp-buffer
                       (insert-file-contents stderr-file)
                       (string-trim (buffer-string)))))
                (error "sspai: %s 退出 %s%s"
                       program status
                       (if (string-empty-p stderr)
                           "" (concat "：" stderr)))))
            (with-current-buffer stdout-buffer
              (buffer-string))))
      (when (buffer-live-p stdout-buffer)
        (kill-buffer stdout-buffer))
      (ignore-errors (delete-file stderr-file)))))

(defun sspai--source-to-html (file raw-body)
  "Convert RAW-BODY from FILE to the SSPAI editor's HTML representation."
  (unless (executable-find "pandoc")
    (user-error "sspai: 发布 Markdown/Org 文章需要安装 pandoc"))
  (let ((from (pcase (sspai--file-format file)
                ('markdown "gfm+raw_html")
                ('org "org")))
        (args nil))
    (setq args
          (append
           (list "-f" from "-t" "html5" "--wrap=none")
           (when sspai-shift-heading-level
             '("--shift-heading-level-by=1"))))
    (string-trim
     (sspai--run-filter "pandoc" args raw-body))))

(defun sspai--remote-html-to-source (file html)
  "Convert remote HTML into FILE's local source format."
  (unless (executable-find "pandoc")
    (user-error "sspai: 导入 SSPAI 文章需要安装 pandoc"))
  (let ((to (pcase (sspai--file-format file)
              ('markdown "gfm+raw_html")
              ('org "org"))))
    (sspai--trim-body
     (sspai--run-filter
      "pandoc"
      (append
       (list "-f" "html" "-t" to "--wrap=none")
       (when sspai-shift-heading-level
         '("--shift-heading-level-by=-1")))
      (or html "")))))

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
    (when (> size sspai-recommended-image-size)
      (message
       "sspai: %s 为 %.2f MB；官方建议图片控制在 %.2f MB 内"
       context
       (/ size 1048576.0)
       (/ sspai-recommended-image-size 1048576.0)))))

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
                 (stringp (sspai--object-get data 'token))
                 (not (string-empty-p
                       (sspai--object-get data 'token))))
      (signal 'sspai-api-error
              (list "上传凭据缺少 token")))
    data))

(defun sspai--qiniu-upload (filename mime bytes credential)
  "Upload BYTES to Qiniu with SSPAI CREDENTIAL.
Return a plist containing :url, :key, :id, and :hash."
  (let* ((token (sspai--object-get credential 'token))
         (issued-key (sspai--object-get credential 'key))
         (attachment-id
          (or (sspai--integer
               "attachment id"
               (sspai--object-get credential 'id)
               t)
              0))
         (fields
          (append
           `(("token" . ,token))
           (when issued-key
             `(("key" . ,issued-key)))))
         (multipart
          (sspai--multipart-body fields filename mime bytes))
         (upload-origin
          (sspai--normalize-origin "upload URL" sspai-upload-url))
         (response
          (sspai--http
           "POST" (concat upload-origin "/")
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
                (and json (sspai--object-get json 'error))))
      (unless (and (integerp qiniu-error) (zerop qiniu-error))
        (signal 'sspai-api-error
                (list (sspai--json-error-message json body)))))
    (let ((key (or (and json (sspai--object-get json 'key))
                   issued-key)))
      (unless (and (stringp key) (not (string-empty-p key)))
        (signal 'sspai-api-error
                (list "Qiniu 响应与 SSPAI 凭据都缺少 attachment key")))
      (list
       :url (concat
             (replace-regexp-in-string "/+\\'" "" sspai-cdn-base-url)
             "/" key)
       :key key
       :id attachment-id
       :hash (and json (sspai--object-get json 'hash))))))

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
  (if (not sspai-upload-local-images)
      html
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
        (sspai--inner-html body)))))

(defun sspai--cdn-key-from-url (url)
  "Return SSPAI attachment key from CDN URL, or nil."
  (let ((prefix
         (concat
          (replace-regexp-in-string "/+\\'" "" sspai-cdn-base-url)
          "/")))
    (when (and (stringp url) (string-prefix-p prefix url))
      (substring url (length prefix)))))

(defun sspai--canonical-banner-key (value)
  "Normalize SSPAI banner VALUE to an attachment key."
  (let ((banner (or (sspai--value-string value) "")))
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

(defun sspai--json-array-list (value field)
  "Return JSON array VALUE as a list for FIELD."
  (cond
   ((vectorp value) (append value nil))
   ((null value) nil)
   ;; Also accept list arrays supplied by tests or a caller.  Service JSON
   ;; itself is parsed with vectors so empty arrays remain distinct from null.
   ((listp value) value)
   (t (error "sspai: 服务端的 %s 不是数组：%S" field value))))

(defun sspai--tag-title (tag)
  "Return the non-empty title from one standard SSPAI TAG object."
  (unless (or (listp tag) (hash-table-p tag))
    (error "sspai: 服务端返回了无效的标准标签：%S" tag))
  (sspai--required-string "remote tag.title"
                          (sspai--object-get tag 'title)))

(defun sspai--standard-tag-summary (tags)
  "Return a stable vector summarizing standard SSPAI TAGS."
  (vconcat
   (sort
    (mapcar
     (lambda (tag)
       `((id . ,(sspai--object-get tag 'id))
         (title . ,(sspai--tag-title tag))))
     (sspai--json-array-list tags "tags"))
    (lambda (left right)
      (let ((left-title (sspai--object-get left 'title))
            (right-title (sspai--object-get right 'title)))
        (if (string-equal left-title right-title)
            (string< (format "%s" (sspai--object-get left 'id))
                     (format "%s" (sspai--object-get right 'id)))
          (string< left-title right-title)))))))

(defun sspai--normalize-article (object)
  "Normalize a complete Matrix editor article OBJECT.
The per-article editing token remains only in the returned in-memory plist and
its private :raw object.  Neither value is ever written to a source file."
  (unless (or (listp object) (hash-table-p object))
    (error "sspai: article 响应不是 object"))
  (let* ((id (sspai--integer "article.id"
                             (sspai--object-get object 'id)))
         (type (sspai--integer "article.type"
                               (sspai--object-get object 'type)
                               t))
         (token-value (sspai--object-get object 'token))
         (token
          (and (stringp token-value)
               (not (string-empty-p token-value))
               token-value))
         (title
          (or (sspai--value-string
               (sspai--object-get object 'title))
              ""))
         (title-last
          (if (sspai--object-member-p object 'title_last)
              (or (sspai--value-string
                   (sspai--object-get object 'title_last))
                  "")
            title))
         (body
          (or (sspai--value-string
               (sspai--object-get object 'body))
              ""))
         (body-last
          (if (sspai--object-member-p object 'body_last)
              (or (sspai--value-string
                   (sspai--object-get object 'body_last))
                  "")
            body))
         (banner
          (or (sspai--value-string
               (sspai--object-get object 'banner))
              ""))
         (banner-id
          (or (sspai--integer
               "article.banner_id"
               (sspai--object-get object 'banner_id)
               t)
              0))
         (banner-key
          (let ((key (sspai--canonical-banner-key banner)))
            (unless (string-empty-p key) key)))
         (banner-url
          (and banner-key
               (concat
                (replace-regexp-in-string
                 "/+\\'" "" sspai-cdn-base-url)
                "/" banner-key)))
         (standard-tags
          (let ((value (sspai--object-get object 'tags)))
            (vconcat (sspai--json-array-list value "tags"))))
         (custom-tags
          (sspai--normalize-tags
           (sspai--object-get object 'custom_tags)))
         (all-tags
          (sspai--normalize-tags
           (append
            (mapcar #'sspai--tag-title
                    (append standard-tags nil))
            custom-tags)))
         (allow-comment
          (sspai--boolean
           "article.allow_comment"
           (sspai--object-get object 'allow_comment)
           t))
         (benefits-on
          (sspai--boolean
           "article.benefits_statement_on"
           (sspai--object-get object 'benefits_statement_on)
           nil))
         (benefits-id
          (or (sspai--integer
               "article.benefits_statement_id"
               (sspai--object-get object 'benefits_statement_id)
               t)
              0))
         (free
          (if (sspai--object-member-p object 'free)
              (sspai--boolean
               "article.free" (sspai--object-get object 'free) nil)
            t))
         (delete-status
          (sspai--boolean
           "article.delete_status"
           (sspai--object-get object 'delete_status)
           nil))
         (updated-at
          (or
           (sspai--integer
            "article.body_updated_at"
            (sspai--object-get object 'body_updated_at)
            t)
           (sspai--integer
            "article.updated_at"
            (sspai--object-get object 'updated_at)
            t)
           0)))
    (unless id
      (error "sspai: article 响应缺少正整数 id"))
    (unless (integerp type)
      (error "sspai: article 响应缺少整数 type"))
    (when (and banner-key (zerop banner-id))
      (error "sspai: article banner 存在但 banner_id 缺失"))
    (when (and benefits-on (zerop benefits-id))
      (error
       "sspai: article 开启利益声明但 statement id 缺失"))
    (list
     :id id
     :token token
     :type type
     :status (sspai--type-status type)
     :free free
     :delete-status delete-status
     :title title-last
     :body body-last
     :published-title title
     :published-body body
     :banner banner
     :banner-id banner-id
     :banner-key banner-key
     :banner-url banner-url
     :standard-tags standard-tags
     :custom-tags custom-tags
     :tags all-tags
     :allow-comment allow-comment
     :benefits-statement-on benefits-on
     :benefits-statement-id benefits-id
     :updated-at updated-at
     :url (sspai--site-url (format "/post/%d" id))
     :raw (copy-tree object t))))

(defun sspai--api-error-code-or-status (err)
  "Return numeric API error code or HTTP status carried by ERR."
  (let ((value (caddr err)))
    (and (integerp value) value)))

(defun sspai--api-error-kind (err)
  "Return the structured origin marker carried by ERR, if any."
  (nth 4 err))

(defun sspai--api-error-not-found-p (err)
  "Return non-nil when ERR means the article does not exist."
  (memq (sspai--api-error-code-or-status err) '(404 3004)))

(defun sspai--definite-api-rejection-p (err)
  "Return non-nil when ERR contains a server rejection code.
Transport failures have no numeric code and therefore remain ambiguous."
  (let ((code (sspai--api-error-code-or-status err))
        (kind (sspai--api-error-kind err)))
    (cond
     ((eq kind 'envelope) (integerp code))
     ((eq kind 'invalid-success) nil)
     ((eq kind 'http)
      (and (integerp code)
           (<= 400 code) (< code 500)
           (/= code 408)))
     ;; Preserve callers that signal the older three-field condition while
     ;; remaining conservative about HTTP 5xx and request timeouts.
     (t
      (and (integerp code)
           (<= 400 code) (< code 500)
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
  (unless (memq action '(draft community audit))
    (error "sspai: 未知写入动作：%S" action))
  (let* ((raw (copy-tree (plist-get remote :raw) t))
         (title
          (sspai--required-string "title" (plist-get meta :title)))
         (tag-payloads
          (sspai--tag-payloads (plist-get meta :tags) remote))
         (target-type
          (pcase action
            ('draft (plist-get remote :type))
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
    (setq raw (sspai--object-set raw 'type target-type))
    (setq raw (sspai--object-set
               raw 'banner (or (car-safe banner-pair) "")))
    (setq raw (sspai--object-set
               raw 'banner_id (or (cdr-safe banner-pair) 0)))
    (setq raw (sspai--object-set raw 'title_last title))
    (setq raw (sspai--object-set raw 'body_last html))
    (setq raw
          (sspai--object-set
           raw 'allow_comment
           (sspai--bool-json (plist-get meta :allow-comment))))
    (setq raw (sspai--object-set raw 'tags (car tag-payloads)))
    (setq raw (sspai--object-set
               raw 'custom_tags (cdr tag-payloads)))
    (setq raw
          (sspai--object-set
           raw 'benefits_statement_on
           (sspai--bool-json
            (plist-get meta :benefits-statement-on))))
    (setq raw
          (sspai--object-set
           raw 'benefits_statement_id
           (or (plist-get meta :benefits-statement-id) 0)))
    (setq raw (sspai--object-set raw 'delete_status :json-false))
    ;; Community publication commits the edit.  Draft saving and audit
    ;; submission intentionally leave the currently published fields alone.
    (when (eq action 'community)
      (setq raw (sspai--object-set raw 'title title))
      (setq raw (sspai--object-set raw 'body html)))
    raw))

(defun sspai--update-core (object action)
  "Return the intentional update fields from article OBJECT for ACTION."
  (let ((tags (sspai--object-get object 'tags))
        (custom-tags
         (sspai--normalize-tags
          (sspai--object-get object 'custom_tags))))
    `((type . ,(sspai--object-get object 'type))
      (banner
       . ,(sspai--canonical-banner-key
           (sspai--object-get object 'banner)))
      (banner_id . ,(or (sspai--object-get object 'banner_id) 0))
      (title_last . ,(or (sspai--value-string
                          (sspai--object-get object 'title_last))
                         ""))
      (body_last . ,(or (sspai--value-string
                         (sspai--object-get object 'body_last))
                        ""))
      (allow_comment
       . ,(sspai--bool-json
           (sspai--boolean
            "article.allow_comment"
            (sspai--object-get object 'allow_comment)
            t)))
      (tags . ,(sspai--standard-tag-summary tags))
      (custom_tags . ,(vconcat custom-tags))
      (benefits_statement_on
       . ,(sspai--bool-json
           (sspai--boolean
            "article.benefits_statement_on"
            (sspai--object-get object 'benefits_statement_on)
            nil)))
      (benefits_statement_id
       . ,(or (sspai--object-get object 'benefits_statement_id) 0))
      (delete_status
       . ,(sspai--bool-json
           (sspai--boolean
            "article.delete_status"
            (sspai--object-get object 'delete_status)
            nil)))
      ,@(when (eq action 'community)
          `((title . ,(or (sspai--value-string
                           (sspai--object-get object 'title))
                          ""))
            (body . ,(or (sspai--value-string
                          (sspai--object-get object 'body))
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

(defun sspai--body-image-references (file raw-body)
  "Return local-or-remote image references found in FILE's RAW-BODY.
Pandoc remains the authority for publication; this conservative scanner only
adds dependency fingerprints so replacing bytes at an unchanged local path is
detectable while publishing; these fingerprints are never saved in metadata."
  (let (references)
    (cl-labels
        ((remember
          (value)
          (when (and (stringp value)
                     (not (string-empty-p value))
                     (not (member value references)))
            (push value references)))
         (scan
          (regexp group)
          (let ((position 0))
            (while (string-match regexp raw-body position)
              (remember (match-string group raw-body))
              (setq position
                    (max (match-end 0) (1+ position)))))))
      ;; Raw HTML may occur in either source format.
      (scan "<img\\(?:[^>]*?\\)[ \t\n]+src=[\"']\\([^\"']+\\)[\"']" 1)
      (pcase (sspai--file-format file)
        ('markdown
         (let ((position 0))
           (while
               (string-match
                (concat
                 "!\\[[^]\n]*\\]("
                 "\\(?:<\\([^>\n]+\\)>\\|\\([^ \t\n)]+\\)\\)")
                raw-body position)
             (remember
              (or (match-string 1 raw-body)
                  (match-string 2 raw-body)))
             (setq position
                   (max (match-end 0) (1+ position))))))
        ('org
         (scan "\\[\\[file:\\([^]\n]+\\)\\]" 1))))
    (nreverse references)))

(defun sspai--reference-fingerprint (reference base-dir)
  "Return a stable dependency fingerprint for REFERENCE below BASE-DIR.
External URLs return nil.  Missing local files produce a marker so deletion is
also detected as a local change."
  (cond
   ((string-prefix-p "data:" reference)
    ;; The URI bytes already occur in the source hash; no filesystem
    ;; dependency is needed.
    nil)
   (t
    (condition-case err
        (let ((path
               (sspai--normalize-local-reference
                reference base-dir)))
          (cond
           ((eq path 'external) nil)
           ((and (file-regular-p path) (file-readable-p path))
            (concat reference "="
                    (secure-hash
                     'sha256 (sspai--read-file-bytes path))))
           (t (concat reference "=<missing>"))))
      (error
       (concat reference "=<invalid:"
               (secure-hash
                'sha256 (error-message-string err))
               ">"))))))

(defun sspai--local-dependency-fingerprints (file meta raw-body)
  "Return a sorted vector of local image fingerprints for FILE."
  (if (null file)
      (let ((saved (plist-get meta :banner-hash)))
        (if saved (vector (concat "banner=" saved)) []))
    (let* ((base-dir
            (file-name-directory (expand-file-name file)))
           (references
           (append
             (when (plist-get meta :banner)
               (list (plist-get meta :banner)))
             (sspai--body-image-references file raw-body)))
           values)
      (dolist (reference references)
        (when-let* ((fingerprint
                    (sspai--reference-fingerprint
                     reference base-dir)))
          (push fingerprint values)))
      (vconcat (sort (delete-dups values) #'string<)))))

(defun sspai--source-fingerprint (meta raw-body &optional file)
  "Fingerprint local META and RAW-BODY only for in-flight write checks.
Include FILE image dependencies.  This value is never stored in source files."
  (sspai--hash-json
   `((title . ,(or (plist-get meta :title) ""))
     (body . ,(sspai--trim-body raw-body))
     (banner . ,(or (plist-get meta :banner) ""))
     (dependencies
      . ,(sspai--local-dependency-fingerprints
          file meta raw-body))
     (tags . ,(vconcat (plist-get meta :tags)))
     (status . ,(plist-get meta :status))
     (allow_comment
      . ,(sspai--bool-json
          (plist-get meta :allow-comment)))
     (benefits_statement_on
      . ,(sspai--bool-json
          (plist-get meta :benefits-statement-on)))
     (benefits_statement_id
      . ,(or (plist-get meta :benefits-statement-id) 0)))))

(defun sspai--copy-meta (meta)
  "Return META with an independently copied image cache."
  (let ((copy (copy-sequence meta)))
    (plist-put
     copy :image-cache
     (copy-hash-table (plist-get meta :image-cache)))))

(defun sspai--meta-apply-remote (meta remote)
  "Return META updated from canonical REMOTE fields."
  (let* ((copy (sspai--copy-meta meta))
         (same-local-banner
          (and (plist-get meta :banner)
               (string-equal
                (or (plist-get meta :banner-key) "")
                (or (plist-get remote :banner-key) ""))
               (= (or (plist-get meta :banner-id) 0)
                  (or (plist-get remote :banner-id) 0))))
         (banner
          (cond
           ((null (plist-get remote :banner-key)) nil)
           (same-local-banner (plist-get meta :banner))
           (t (plist-get remote :banner-url)))))
    (setq copy (plist-put copy :id (plist-get remote :id)))
    (setq copy (plist-put copy :url (plist-get remote :url)))
    (setq copy (plist-put copy :status (plist-get remote :status)))
    (setq copy (plist-put copy :title (plist-get remote :title)))
    (setq copy (plist-put copy :banner banner))
    (setq copy (plist-put copy :tags (plist-get remote :tags)))
    (setq copy
          (plist-put copy :allow-comment
                     (plist-get remote :allow-comment)))
    (setq copy
          (plist-put copy :benefits-statement-on
                     (plist-get remote :benefits-statement-on)))
    (setq copy
          (plist-put copy :benefits-statement-id
                     (plist-get remote :benefits-statement-id)))
    (setq copy
          (plist-put copy :banner-id
                     (plist-get remote :banner-id)))
    (setq copy
          (plist-put copy :banner-key
                     (plist-get remote :banner-key)))
    (unless same-local-banner
      (setq copy (plist-put copy :banner-hash nil)))
    copy))

(defun sspai--assert-source-unchanged
    (file expected-meta expected-body)
  "Refuse a checkpoint when editable FILE changed during a network operation."
  (pcase-let* ((`(,current-meta ,current-body)
                 (sspai--read-source file))
                (expected
                 (sspai--source-fingerprint
                  expected-meta expected-body file))
                (current
                 (sspai--source-fingerprint
                  current-meta current-body file)))
    (unless (string-equal expected current)
      (signal
       'sspai-source-changed
       '("网络操作期间源稿或本地图片发生变化；拒绝覆盖新内容")))))

(defun sspai--checkpoint-image-cache (file meta raw-body)
  "Persist META's upload cache while preserving editable RAW-BODY."
  (sspai--assert-source-unchanged file meta raw-body)
  (sspai--write-source file meta raw-body))

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
    ('new "尚未创建远端草稿")
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
    (sspai--file-format file)
    (when (file-remote-p file)
      (user-error "sspai: 发布与同步不支持远程源稿"))
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

(defun sspai--confirm (prompt enabled)
  "Ask PROMPT when ENABLED is non-nil."
  (when (and enabled (not (yes-or-no-p prompt)))
    (user-error "sspai: 已取消")))

(defun sspai--publication-meta (meta remote)
  "Copy local META and record REMOTE identity and publication status only."
  (let ((updated (sspai--copy-meta meta)))
    (setf (plist-get updated :id) (plist-get remote :id)
          (plist-get updated :url) (plist-get remote :url)
          (plist-get updated :status) (plist-get remote :status))
    updated))

(defun sspai--checkpoint-pushed
    (file expected-meta raw-body remote)
  "Checkpoint REMOTE after a successful write to FILE."
  (let ((updated
         (sspai--publication-meta expected-meta remote)))
    (condition-case err
        (progn
          (sspai--assert-source-unchanged
           file expected-meta raw-body)
          (sspai--write-source file updated raw-body))
      (error
       (signal
        'sspai-published-but-not-checkpointed
        (list
         (concat
          "少数派远端已经写入，但本地 checkpoint 失败；"
          "请勿直接重发。"
          (error-message-string err))))))
    updated))

(defun sspai--checkpoint-created-interim
    (file expected-meta intended-meta raw-body remote action)
  "Immediately persist a newly created REMOTE id before follow-up ACTION.
Editable values remain those in INTENDED-META, so an interrupted publish can
be retried using the recorded article ID without creating another draft."
  (let ((updated
         (sspai--publication-meta intended-meta remote)))
    (setq updated
          (plist-put updated :status
                     (pcase action
                       ('draft "draft")
                       ('community "published")
                       ('audit "audit"))))
    (condition-case err
        (progn
          (sspai--assert-source-unchanged
           file expected-meta raw-body)
          (sspai--write-source file updated raw-body))
      (error
       (signal
        'sspai-published-but-not-checkpointed
        (list
         (concat
          "草稿已经创建，但文章 ID 无法写回源稿；"
          "请先在网页后台记录新草稿，切勿直接重试。"
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
  (let* ((title (sspai--validate-write-meta meta))
         (_title title)
         (html
          (sspai--source-to-html file raw-body))
         (checkpoint
          (lambda ()
            (sspai--checkpoint-image-cache
             file meta raw-body)))
         (rewritten
          (sspai--rewrite-body-images
           html
           (file-name-directory (expand-file-name file))
           (plist-get meta :image-cache)
           checkpoint))
         (banner-pair
          (sspai--prepare-banner file meta checkpoint)))
    (sspai--assert-source-unchanged file meta raw-body)
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
    ('draft "保存草稿")
    ('community "发布到 Matrix 社区")
    ('audit "提交编辑审核")
    (_ (format "%S" action))))

(defun sspai--action-from-meta (meta)
  "Return write action requested by META status."
  (pcase (plist-get meta :status)
    ("draft" 'draft)
    ("published" 'community)
    ("audit" 'audit)
    (_
     (user-error "sspai: 当前 status 不可用于写入：%s"
                 (plist-get meta :status)))))

(defun sspai--needs-post-create-update-p (meta action)
  "Return non-nil when a new draft needs a follow-up update."
  (or (not (eq action 'draft))
      (plist-get meta :benefits-statement-on)
      (> (or (plist-get meta :benefits-statement-id) 0) 0)))

(defun sspai--write-state (file state action)
  "Execute ACTION for FILE, always publishing its local content from STATE."
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
    (let ((title (sspai--validate-write-meta meta)))
      (sspai--confirm
       (format "%s少数派文章《%s》？"
               (sspai--action-label action) title)
       sspai-confirm-before-write))
    (pcase-let* ((`(,html ,banner-pair)
                   (sspai--prepare-write-assets
                    file meta raw-body))
                  (title (plist-get meta :title))
                  (intended-meta (sspai--copy-meta meta)))
      (if remote
          (let* ((after-autosave
                  (sspai--auto-save-confirmed
                   remote title html))
                 (payload
                  (sspai--full-update-payload
                   after-autosave intended-meta
                   html banner-pair action))
                 (written
                  (sspai--full-update-confirmed
                   after-autosave payload action)))
            (sspai--checkpoint-pushed
             file meta raw-body written)
            (message "sspai: 已%s并保存发布状态"
                     (sspai--write-result-label action written))
            written)
        (let* ((created
                (sspai--article-add
                (sspai--article-add-payload
                  intended-meta html banner-pair)))
               (follow-up
                (sspai--needs-post-create-update-p
                 intended-meta action)))
          (if (not follow-up)
              (progn
                (sspai--checkpoint-pushed
                 file meta raw-body created)
                (message
                 "sspai: 已创建草稿并保存 article id/checkpoint")
                created)
            ;; Persist the non-idempotent create result before either of the
            ;; subsequent update calls.  A failure from this point forward can
            ;; safely be retried as an update rather than another add.
            (let* ((interim
                    (sspai--checkpoint-created-interim
                     file meta intended-meta raw-body
                     created action))
                   (after-autosave
                    (sspai--auto-save-confirmed
                     created title html))
                   (payload
                    (sspai--full-update-payload
                     after-autosave intended-meta
                     html banner-pair action))
                   (written
                    (sspai--full-update-confirmed
                     after-autosave payload action)))
              (sspai--checkpoint-pushed
               file interim raw-body written)
              (message
               "sspai: 已创建草稿、%s并保存 checkpoint"
               (sspai--write-result-label action written))
              written)))))))

;;;###autoload
(defun sspai-save-draft ()
  "Create or save the current SSPAI draft.
For a published article this updates its editable `*_last' version without
changing the committed public title/body.  Local content is authoritative."
  (interactive)
  (let* ((file (sspai--current-source-file))
         (state (sspai--state file)))
    (sspai--write-state file state 'draft)))

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
(defun sspai-sync ()
  "Push the current local source according to its publication status.
Local content is authoritative.  Never replace it with remote article content."
  (interactive)
  (let* ((file (sspai--current-source-file))
         (state (sspai--state file)))
    (sspai--write-state file state
                        (sspai--action-from-meta (plist-get state :meta)))))

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

(defun sspai--cached-banner-pair (file meta)
  "Return a verified cached banner pair for FILE and META, or nil."
  (let ((banner (plist-get meta :banner))
        (key (plist-get meta :banner-key))
        (id (or (plist-get meta :banner-id) 0)))
    (when (and banner key (> id 0))
      (cond
       ((string-match-p "\\`https://" banner)
        (and (string-equal
              key (or (sspai--cdn-key-from-url banner) ""))
             (cons key id)))
       (t
        (let ((pair
              (sspai--image-bytes-and-mime
                banner
                (file-name-directory
                 (expand-file-name file)))))
          (and (not (eq pair 'external))
               (string-equal
                (secure-hash 'sha256 (cdr pair))
                (or (plist-get meta :banner-hash) ""))
               (cons key id))))))))

;;;###autoload
(defun sspai-show-payload ()
  "Show a token-redacted article payload for the current source.
This preview converts the body but performs no image upload.  A changed local
banner therefore appears empty until a real write obtains a new attachment id."
  (interactive)
  (let* ((file (sspai--current-source-file))
         (source (sspai--read-source file))
         (meta (car source))
         (raw-body (cadr source))
         (html (sspai--source-to-html file raw-body))
         (banner-pair (sspai--cached-banner-pair file meta))
         (remote
          (and (plist-get meta :id)
               (sspai--article-get
                (plist-get meta :id))))
         (action (sspai--action-from-meta meta))
         (payload
          (if remote
              (sspai--full-update-payload
               remote meta html banner-pair action)
            (sspai--article-add-payload
             meta html banner-pair))))
    (when (sspai--object-member-p payload 'token)
      (setq payload
            (sspai--object-set
             payload 'token "<redacted>")))
    (with-current-buffer
        (get-buffer-create "*sspai-payload*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert
         (json-serialize
          payload :null-object nil
          :false-object :json-false))
        (json-pretty-print-buffer)
        (goto-char (point-min))
        (special-mode)
        (display-buffer (current-buffer))))))

;;;###autoload
(defun sspai-open-remote ()
  "Open the tracked article's public SSPAI URL."
  (interactive)
  (pcase-let* ((file (sspai--current-source-file))
                (`(,meta ,_body)
                 (sspai--read-source file))
                (url (plist-get meta :url)))
    (unless url
      (user-error "sspai: 源稿尚无远端 article id"))
    (browse-url url)))

;;;###autoload
(defun sspai-open-preview ()
  "Open the tracked article in SSPAI's web editor."
  (interactive)
  (pcase-let* ((file (sspai--current-source-file))
                (`(,meta ,_body)
                 (sspai--read-source file))
                (id (plist-get meta :id)))
    (unless id
      (user-error "sspai: 请先创建远端草稿"))
    (browse-url
     (sspai--site-url (format "/write/%d" id)))))

;;;; Creating and importing sources

(defun sspai--new-meta (&optional title)
  "Return fresh source metadata with optional TITLE."
  (list
   :id nil
   :url nil
   :status "draft"
   :title (or title "")
   :banner nil
   :tags nil
   :allow-comment t
   :benefits-statement-on nil
   :benefits-statement-id 0
   :banner-id 0
   :banner-key nil
   :banner-hash nil
   :image-cache (make-hash-table :test #'equal)))

;;;###autoload
(defun sspai-new-article (file &optional title)
  "Create a new Markdown or Org SSPAI source FILE with optional TITLE."
  (interactive
   (list
    (read-file-name
     "少数派源稿（.md/.markdown/.org）: "
     default-directory nil nil)))
  (sspai--create-source
   file (sspai--new-meta title) "")
  (message "sspai: 已创建文章源稿：%s" file))

;;;###autoload
(defun sspai-import-article (id file)
  "Import existing SSPAI article ID into new source FILE."
  (interactive
   (list
    (read-number "少数派 article id: ")
    (read-file-name
     "导入到（.md/.markdown/.org）: "
     default-directory nil nil)))
  (let* ((remote (sspai--article-get id))
         (meta
          (sspai--meta-apply-remote
           (sspai--new-meta) remote))
         (body
          (sspai--remote-html-to-source
           file (plist-get remote :body))))
    (sspai--create-source file meta body)
    (message "sspai: 已导入 article %d：%s" id file)))

(provide 'sspai)

;;; sspai.el ends here
