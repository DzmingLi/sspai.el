;;; sspai-test.el --- Offline regression tests for sspai.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dzming Li
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; These tests never contact SSPAI or Qiniu.  Network boundaries are mocked so
;; credentials, payloads, and ambiguous-write behavior can be checked exactly.

;;; Code:

(require 'cl-lib)
(require 'ert)

(setq load-prefer-newer t)
(add-to-list
 'load-path
 (file-name-directory
  (directory-file-name
   (file-name-directory (or load-file-name buffer-file-name)))))
(require 'sspai)

(defconst sspai-test--hash-a (make-string 64 ?a))
(defconst sspai-test--hash-b (make-string 64 ?b))

(defun sspai-test--with-temp-file (suffix contents callback)
  "Create a temporary SUFFIX file with CONTENTS and call CALLBACK with it."
  (let ((file (make-temp-file "sspai-test-" nil suffix)))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert contents))
          (funcall callback file))
      (when-let* ((buffer (find-buffer-visiting file)))
        (with-current-buffer buffer
          (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (ignore-errors (delete-file file)))))

(defun sspai-test--read-text (file)
  "Return FILE contents as a string."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun sspai-test--response (status body &optional _headers _url)
  "Build a synthetic HTTP response with STATUS and BODY."
  (sspai--make-response :status status :body body))

(defun sspai-test--metadata (title)
  "Return minimal normalized metadata for TITLE."
  (car (sspai--org-meta-and-body (format "#+TITLE: %s\n\n" title))))

(defun sspai-test--plist-with (plist &rest pairs)
  "Return a copy of PLIST updated with PAIRS."
  (let ((copy (copy-sequence plist)))
    (while pairs
      (setq copy (plist-put copy (pop pairs) (pop pairs))))
    copy))

(defun sspai-test--article-object (&optional type)
  "Return a synthetic raw Matrix article object of TYPE."
  (copy-tree
   `((id . 42)
     (token . "ARTICLE-TOKEN")
     (type . ,(or type 4))
     (free . t)
     (title . "Published title")
     (title_last . "Draft title")
     (body . "<p>Published body</p>")
     (body_last . "<p>Draft body</p>")
     (words_count . 2)
     (words_count_last . 2)
     (banner . "attachments/old-banner.png")
     (banner_id . 8)
     (allow_comment . t)
     (tags . (((id . 101) (title . "Official"))))
     (custom_tags . ("Custom"))
     (delete_status . :json-false)
     (created_at . 100)
     (released_at . 90)
     (body_updated_at . 120)
     (benefits_statement_on . :json-false)
     (benefits_statement_id . 0)
     (future_server_field . "preserve-me"))
   t))

(ert-deftest sspai-test-org-uses-only-generic-banner-keyword ()
  (sspai-test--with-temp-file
   ".org"
   (concat
    "#+TITLE: Canonical\n"
    "#+BANNER: ./canonical.png\n"
    "#+COVER: ./old-generic-cover.png\n"
    "#+ZHIHU_BANNER: ./platform-zhihu.png\n"
    "#+SSPAI_BANNER: ./platform-sspai.png\n"
    "\n"
    "Body\n")
   (lambda (file)
     (pcase-let ((`(,meta ,body) (sspai--read-source file)))
       (should (equal (plist-get meta :banner) "./canonical.png"))
       (should (equal (string-trim body) "Body"))))))

(ert-deftest sspai-test-org-does-not-fallback-to-cover-or-platform-banner ()
  (sspai-test--with-temp-file
   ".org"
   (concat
    "#+TITLE: No generic banner\n"
    "#+COVER: ./old-generic-cover.png\n"
    "#+ZHIHU_BANNER: ./platform-zhihu.png\n"
    "#+SSPAI_BANNER: ./platform-sspai.png\n"
    "\n"
    "Body\n")
   (lambda (file)
     (pcase-let ((`(,meta ,_body) (sspai--read-source file)))
       (should-not (plist-get meta :banner))))))

(ert-deftest sspai-test-org-uses-only-banner-checkpoint-field-names ()
  (sspai-test--with-temp-file
   ".org"
   (concat
    "#+TITLE: Banner checkpoint\n"
    "#+SSPAI_STATUS: draft\n"
    "#+SSPAI_BANNER_ID: 9\n"
    "#+SSPAI_BANNER_KEY: attachments/banner.png\n"
    "#+SSPAI_BANNER_HASH: " sspai-test--hash-a "\n"
    "#+SSPAI_COVER_KEY: attachments/old.png\n"
    "#+SSPAI_COVER_HASH: " sspai-test--hash-b "\n"
    "\n"
    "Body\n")
   (lambda (file)
     (pcase-let ((`(,meta ,body) (sspai--read-source file)))
       (should (equal (plist-get meta :banner-key)
                      "attachments/banner.png"))
       (should (equal (plist-get meta :banner-hash)
                      sspai-test--hash-a))
       (sspai--write-source file meta)
       (let ((text (sspai-test--read-text file)))
         (should (string-match-p "^#\\+SSPAI_BANNER_KEY: " text))
         (should (string-match-p "^#\\+SSPAI_BANNER_HASH: " text))
         (should (string-match-p "^#\\+SSPAI_COVER_KEY: " text))
         (should (string-match-p "^#\\+SSPAI_COVER_HASH: "
                                 text)))))))

(ert-deftest sspai-test-org-checkpoint-preserves-unowned-keywords ()
  (sspai-test--with-temp-file
   ".org"
   (concat
    "#+TITLE: Before\n"
    "#+BANNER: ./banner.png\n"
    "#+AUTHOR: Alice\n"
    "#+PROPERTY: header-args :eval never\n"
    "#+SSPAI_STATUS: draft\n"
    "\n"
    "Original body\n")
   (lambda (file)
     (pcase-let ((`(,meta ,body) (sspai--read-source file)))
       (setf (plist-get meta :title) "After"
             (plist-get meta :id) 42)
       (sspai--write-source file meta)
       (let ((text (sspai-test--read-text file)))
         (should (string-match-p "^#\\+TITLE: Before$" text))
         (should (string-match-p "^#\\+BANNER: ./banner.png$" text))
         (should (string-match-p "^#\\+AUTHOR: Alice$" text))
         (should (string-match-p
                  "^#\\+PROPERTY: header-args :eval never$" text))
         (should (string-match-p "^#\\+SSPAI_ID: 42$" text))
         (should
          (=
           (with-temp-buffer
             (insert text)
             (goto-char (point-min))
             (how-many "^#\\+SSPAI_STATUS:"))
           1)))))))

(ert-deftest sspai-test-org-nonempty-image-cache-roundtrips ()
  (sspai-test--with-temp-file
   ".org"
   (concat
    "#+TITLE: Cached image\n"
    "#+SSPAI_STATUS: draft\n"
    "#+SSPAI_IMAGE_CACHE: {\""
    sspai-test--hash-a
    "\":\"https://cdnfile.sspai.com/a.png\"}\n"
    "\n"
    "Body\n")
   (lambda (file)
     (pcase-let ((`(,meta ,body) (sspai--read-source file)))
       (should
        (equal
         (gethash sspai-test--hash-a
                  (plist-get meta :image-cache))
         "https://cdnfile.sspai.com/a.png"))
       (sspai--write-source file meta)
       (pcase-let ((`(,roundtrip ,roundtrip-body)
                    (sspai--read-source file)))
         (should
          (equal
           (gethash sspai-test--hash-a
                    (plist-get roundtrip :image-cache))
           "https://cdnfile.sspai.com/a.png"))
         (should (equal (string-trim roundtrip-body) "Body")))))))

(ert-deftest sspai-test-atomic-checkpoint-rejects-symbolic-link ()
  (let* ((target (make-temp-file "sspai-target-" nil ".org" "original\n"))
         (link (concat target ".link")))
    (unwind-protect
        (progn
          (make-symbolic-link target link)
          (should-error
           (sspai--atomic-write-text link "replacement\n")
           :type 'user-error)
          (should (equal (sspai-test--read-text target) "original\n")))
      (ignore-errors (delete-file link))
      (ignore-errors (delete-file target)))))

(ert-deftest sspai-test-api-envelope-returns-data ()
  (cl-letf (((symbol-function 'sspai--http)
             (lambda (&rest _)
               (sspai-test--response
                200 "{\"error\":0,\"data\":{\"id\":42}}"))))
    (should
     (equal (sspai--api-data "GET" "/test")
            '((id . 42))))))

(ert-deftest sspai-test-json-empty-array-remains-an-array ()
  (let* ((object (sspai--parse-json "{\"tags\":[]}"))
         (tags (alist-get 'tags object)))
    (should (vectorp tags))
    (should
     (equal
      (json-serialize object :null-object nil :false-object :json-false)
      "{\"tags\":[]}"))))

(ert-deftest sspai-test-api-envelope-error-is-not-http-success ()
  (cl-letf (((symbol-function 'sspai--http)
             (lambda (&rest _)
               (sspai-test--response
                200 "{\"error\":1001,\"msg\":\"denied\",\"data\":null}"))))
    (should-error
     (sspai--api-request "GET" "/test")
     :type 'sspai-api-error)))

(ert-deftest sspai-test-api-rejects-http-error-and-empty-success ()
  (cl-letf (((symbol-function 'sspai--http)
             (lambda (&rest _)
               (sspai-test--response
                500 "{\"error\":500,\"msg\":\"broken\"}"))))
    (should-error
     (sspai--api-request "GET" "/test")
     :type 'sspai-api-error))
  (cl-letf (((symbol-function 'sspai--http)
             (lambda (&rest _)
               (sspai-test--response 204 ""))))
    (should-error
     (sspai--api-request "GET" "/test")
     :type 'sspai-api-error)))

(ert-deftest sspai-test-editor-status-mapping ()
  (should (equal (sspai--type-status 4) "draft"))
  (should (equal (sspai--type-status 5) "published"))
  (should (equal (sspai--type-status 2) "audit")))

(ert-deftest sspai-test-normalize-article-prefers-editor-last-fields ()
  (let ((article
         (sspai--normalize-article
          (sspai-test--article-object))))
    (should (= (plist-get article :id) 42))
    (should (equal (plist-get article :token) "ARTICLE-TOKEN"))
    (should (equal (plist-get article :title) "Draft title"))
    (should (equal (plist-get article :body) "<p>Draft body</p>"))
    (should
     (equal
      (alist-get 'future_server_field (plist-get article :raw))
      "preserve-me"))))

(ert-deftest sspai-test-article-get-uses-single-info-and-keeps-token-in-memory ()
  (let (observed)
    (cl-letf
        (((symbol-function 'sspai--api-data)
          (lambda (method path &optional query payload)
            (setq observed (list method path query payload))
            (sspai-test--article-object))))
      (let ((article (sspai--article-get 42)))
        (should
         (equal
          observed
          '("GET"
            "/matrix/editor/article/single/info/get"
            ((id . 42))
            nil)))
        (should (equal (plist-get article :token)
                       "ARTICLE-TOKEN"))))))

(ert-deftest sspai-test-article-add-payload-is-exact-and-tags-are-custom ()
  (let* ((meta
          (sspai-test--plist-with
           (sspai-test--metadata "New article")
           :tags '("Official-looking" "Custom")
           :allow-comment nil))
         (payload
          (sspai--article-add-payload
           meta "<p>Body</p>" '("attachments/banner.png" . 9))))
    (should
     (equal
      payload
      `((type . 4)
        (banner . "attachments/banner.png")
        (banner_id . 9)
        (title . "New article")
        (title_last . "New article")
        (body . "<p>Body</p>")
        (body_last . "<p>Body</p>")
        (allow_comment . :json-false)
        (tags . ,[])
        (custom_tags . ,["Official-looking" "Custom"])
        (delete_status . :json-false))))))

(ert-deftest sspai-test-article-create-ambiguous-result-is-never-retried ()
  (let ((calls 0))
    (cl-letf
        (((symbol-function 'sspai--api-data)
          (lambda (&rest _arguments)
            (setq calls (1+ calls))
            (signal 'sspai-api-error '("network failed")))))
      (should-error
       (sspai--article-add '((type . 4)))
       :type 'sspai-create-result-unknown)
      (should (= calls 1))))
  (let ((calls 0))
    (cl-letf
        (((symbol-function 'sspai--api-data)
          (lambda (&rest _arguments)
            (setq calls (1+ calls))
            (signal 'sspai-api-error
                    '("invalid article" 422 "/article/add" http)))))
      (should-error
       (sspai--article-add '((type . 4)))
       :type 'sspai-api-error)
      (should (= calls 1)))))

(ert-deftest sspai-test-auto-save-payload-is-exact ()
  (let ((remote
         (sspai--normalize-article
          (sspai-test--article-object))))
    (cl-letf (((symbol-function 'float-time)
               (lambda (&optional _time) 1234.9)))
      (should
       (equal
        (sspai--article-auto-save-payload
         remote "Edited" "<p>Edited</p>")
        '((id . 42)
          (token . "ARTICLE-TOKEN")
          (title_last . "Edited")
          (body_last . "<p>Edited</p>")
          (update_at . 1234)))))))

(ert-deftest sspai-test-full-update-preserves-standard-tags-and-unknown-fields ()
  (let* ((remote
          (sspai--normalize-article
           (sspai-test--article-object 5)))
         (meta
          (sspai-test--plist-with
           (sspai-test--metadata "Local title")
           :tags '("Official" "New custom")))
         (payload
          (sspai--full-update-payload
           remote meta "<p>Local body</p>"
           '("attachments/new-banner.png" . 17)
           'audit)))
    (should (= (alist-get 'type payload) 2))
    (should (equal (alist-get 'token payload)
                   "ARTICLE-TOKEN"))
    (should (equal (alist-get 'title payload)
                   "Published title"))
    (should (equal (alist-get 'body payload)
                   "<p>Published body</p>"))
    (should (equal (alist-get 'title_last payload)
                   "Local title"))
    (should (equal (alist-get 'body_last payload)
                   "<p>Local body</p>"))
    (should
     (equal
      (append (alist-get 'tags payload) nil)
      '(((id . 101) (title . "Official")))))
    (should
     (equal
      (append (alist-get 'custom_tags payload) nil)
      '("New custom")))
    (should (equal
             (alist-get 'future_server_field payload)
             "preserve-me"))))

(ert-deftest sspai-test-community-and-audit-update-different-fields ()
  (let* ((remote
          (sspai--normalize-article
           (sspai-test--article-object 4)))
         (meta (sspai-test--metadata "Local title"))
         (community
          (sspai--full-update-payload
           remote meta "<p>Local body</p>" nil 'community))
         (audit
          (sspai--full-update-payload
           remote meta "<p>Local body</p>" nil 'audit)))
    (should (= (alist-get 'type community) 5))
    (should (equal (alist-get 'title community)
                   "Local title"))
    (should (equal (alist-get 'body community)
                   "<p>Local body</p>"))
    (should (= (alist-get 'type audit) 2))
    (should (equal (alist-get 'title audit)
                   "Published title"))
    (should (equal (alist-get 'body audit)
                   "<p>Published body</p>"))))

(ert-deftest sspai-test-firefox-token-is-url-scoped-and-refreshed ()
  (let ((calls 0))
    (cl-letf (((symbol-function 'firefox-cookies-get)
               (lambda (url)
                 (should (equal url "https://sspai.com/api/v1/test"))
                 (list (cons "sspai_jwt_token"
                             (format "JWT%%2E%d" (cl-incf calls)))
                       '("sspai_cross_token" . "DO-NOT-USE")))))
      (should (equal (sspai--access-token "https://sspai.com/api/v1/test") "JWT.1"))
      (should (equal (sspai--access-token "https://sspai.com/api/v1/test") "JWT.2")))))

(ert-deftest sspai-test-firefox-missing-or-invalid-login-stops-before-request ()
  (dolist (value '(nil "" "  " "%20" "JWT%0D%0AX-Evil%3Ayes"))
    (cl-letf (((symbol-function 'firefox-cookies-get)
               (lambda (_) (list (cons "sspai_jwt_token" value))))
              ((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest _) (ert-fail "sent request without login"))))
      (should-error (sspai--http "GET" "https://sspai.com/api/v1/test" :auth t)
                    :type 'user-error))))

(ert-deftest sspai-test-unauthenticated-upload-never-reads-firefox ()
  (cl-letf (((symbol-function 'firefox-cookies-get)
             (lambda (_) (ert-fail "read browser"))))
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest _)
                 (should-not (assoc-string "Authorization"
                                           url-request-extra-headers t))
                 (should-not (assoc-string "Cookie"
                                           url-request-extra-headers t))
                 (let ((buffer (generate-new-buffer " *sspai-upload-test*")))
                   (with-current-buffer buffer
                     (insert "HTTP/1.1 204 No Content\r\n\r\n")
                     (setq-local url-http-response-status 204)
                     (setq-local url-http-end-of-headers (point-max)))
                   buffer))))
      (should (= (sspai--response-status
                  (sspai--http "POST" "https://upload.qiniup.com/"))
                 204)))))

(ert-deftest sspai-test-http-adds-bearer-only-for-authorized-api ()
  (let ((test-token "ACCOUNT-BEARER")
        observed)
    (cl-letf
        (((symbol-function 'sspai--access-token) (lambda (_) test-token))
         ((symbol-function 'url-retrieve-synchronously)
          (lambda (url &rest _arguments)
            (setq observed
                  (list
                   :url url
                   :method url-request-method
                   :headers url-request-extra-headers))
            (let ((buffer (generate-new-buffer " *sspai-http-test*")))
              (with-current-buffer buffer
                (insert
                 "HTTP/1.1 200 OK\r\n"
                 "Content-Type: application/json\r\n"
                 "\r\n"
                 "{\"error\":0,\"data\":{}}")
                (setq-local url-http-response-status 200)
                (goto-char (point-min))
                (search-forward "\r\n\r\n")
                (setq-local url-http-end-of-headers (point)))
              buffer))))
      (let ((response
             (sspai--http
              "GET" "https://sspai.com/api/v1/test" :auth t)))
        (should (= (sspai--response-status response) 200))
        (should (equal (plist-get observed :url)
                       "https://sspai.com/api/v1/test"))
        (should
         (equal
          (cdr
           (assoc-string
            "Authorization" (plist-get observed :headers) t))
          "Bearer ACCOUNT-BEARER"))))))

(ert-deftest sspai-test-firefox-auth-preserves-chinese-request-bytes ()
  (let* ((data (encode-coding-string "{\"title\":\"数码编年史\"}" 'utf-8 t)))
    (cl-letf (((symbol-function 'firefox-cookies-get)
               (lambda (_) (list (cons "sspai_jwt_token"
                                       (string-to-multibyte "BROWSER-JWT")))))
              ((symbol-function 'url-retrieve-synchronously)
               (lambda (url &rest _)
                 (with-temp-buffer
                   (setq-local url-http-target-url (url-generic-parse-url url)
                               url-http-method url-request-method
                               url-http-data url-request-data
                               url-http-extra-headers url-request-extra-headers
                               url-http-proxy nil
                               url-http-referer nil
                               url-http-extensions-header nil)
                   (let ((request (url-http-create-request)))
                     (should (= (length request) (string-bytes request)))
                     (should (string-suffix-p data request))
                     (should (string-match-p
                              (format "Content-length: %d" (length data)) request))))
                 (let ((buffer (generate-new-buffer " *sspai-unicode-test*")))
                   (with-current-buffer buffer
                     (insert "HTTP/1.1 204 No Content\r\n\r\n")
                     (setq-local url-http-response-status 204)
                     (setq-local url-http-end-of-headers (point-max)))
                   buffer))))
      (sspai--http "POST" "https://sspai.com/api/v1/test" :auth t
                   :content-type "application/json" :data data))))

(ert-deftest sspai-test-http-isolates-ambient-cookie-jars ()
  (let ((test-token "ACCOUNT-BEARER")
        (url-cookie-file "/tmp/must-not-load-cookies")
        (url-cookie-storage '(("sspai.com" "ambient-cookie")))
        (url-cookie-secure-storage '(("sspai.com" "ambient-secure-cookie")))
        observed)
    (cl-letf
        (((symbol-function 'sspai--access-token) (lambda (_) test-token))
         ((symbol-function 'url-retrieve-synchronously)
          (lambda (_url &rest _arguments)
            (setq observed
                  (list
                   url-cookie-file
                   url-cookie-storage
                   url-cookie-secure-storage))
            (let ((buffer (generate-new-buffer " *sspai-cookie-test*")))
              (with-current-buffer buffer
                (insert "HTTP/1.1 204 No Content\r\n\r\n")
                (setq-local url-http-response-status 204)
                (setq-local url-http-end-of-headers (point-max)))
              buffer))))
      (sspai--http "GET" "https://sspai.com/api/v1/test" :auth t)
      (should (equal observed '(nil nil nil))))))

(ert-deftest sspai-test-cross-origin-auth-is-rejected-before-token-read ()
  (let (token-read transport-called)
    (cl-letf
        (((symbol-function 'sspai--access-token)
          (lambda ()
            (setq token-read t)
            "ACCOUNT-BEARER"))
         ((symbol-function 'url-retrieve-synchronously)
          (lambda (&rest _arguments)
            (setq transport-called t)
            (error "transport must not run"))))
      (should-error
       (sspai--http "GET" "https://evil.example/steal" :auth t))
      (should-not token-read)
      (should-not transport-called))))

(ert-deftest sspai-test-transport-error-redacts-account-bearer ()
  (let ((test-token "DO-NOT-LEAK"))
    (cl-letf
        (((symbol-function 'sspai--access-token) (lambda (_) test-token))
         ((symbol-function 'url-retrieve-synchronously)
          (lambda (&rest _arguments)
            (error
             "connection failed with Authorization: Bearer DO-NOT-LEAK"))))
      (let ((message-text
             (condition-case err
                 (progn
                   (sspai--http
                    "GET" "https://sspai.com/api/v1/test" :auth t)
                   "")
               (sspai-api-error (error-message-string err)))))
        (should-not (string-match-p "DO-NOT-LEAK" message-text))
        (should (string-match-p "<redacted>" message-text))))))

(ert-deftest sspai-test-transport-error-redacts-article-token-in-payload ()
  (let ((test-token "ACCOUNT-BEARER")
        (article-token "ARTICLE-TOKEN-MUST-NOT-LEAK"))
    (cl-letf
        (((symbol-function 'sspai--access-token) (lambda (_) test-token))
         ((symbol-function 'url-retrieve-synchronously)
          (lambda (&rest _arguments)
            (error "transport dumped request token %s" article-token))))
      (let ((message-text
             (condition-case err
                 (progn
                   (sspai--api-request
                    "POST" "/matrix/editor/article/auto/save"
                    :payload
                    `((id . 42)
                      (token . ,article-token)
                      (title_last . "Title")
                      (body_last . "<p>Body</p>")
                      (update_at . 1)))
                   "")
               (sspai-api-error (error-message-string err)))))
        (should-not (string-match-p
                     (regexp-quote article-token) message-text))))))

(ert-deftest sspai-test-qiniu-never-receives-account-bearer ()
  (let ((test-token "ACCOUNT-BEARER-MUST-NOT-LEAVE-SSPAI")
        seen)
    (cl-letf
        (((symbol-function 'sspai--http)
          (lambda (method url &rest arguments)
            (setq seen (list method url arguments))
            (sspai-test--response
             200 "{\"key\":\"attachments/image.png\",\"hash\":\"etag\"}"
             nil url))))
      (let ((result
             (sspai--qiniu-upload
              "image.png" "image/png"
              (encode-coding-string "PNG" 'binary t)
              '((token . "SHORT-LIVED-QINIU-TOKEN")
                (key . "attachments/image.png")
                (id . 9)))))
        (should (equal (plist-get result :key)
                       "attachments/image.png"))
        (should (equal (car seen) "POST"))
        (should (equal (cadr seen) "https://upload.qiniup.com/"))
        (should-not (plist-get (caddr seen) :auth))
        (should-not
         (string-match-p
          (regexp-quote test-token)
          (decode-coding-string
           (plist-get (caddr seen) :data) 'utf-8 t)))))))

(ert-deftest sspai-test-local-upload-first-gets-credential-then-uses-qiniu ()
  (let (calls)
    (cl-letf
        (((symbol-function 'sspai--attachment-token)
          (lambda (filename)
            (push (list 'credential filename) calls)
            '((token . "SHORT-LIVED")
              (key . "attachments/image.png")
              (id . 9))))
         ((symbol-function 'sspai--qiniu-upload)
          (lambda (filename mime bytes credential)
            (push
             (list 'qiniu filename mime bytes credential)
             calls)
            (list
             :url "https://cdnfile.sspai.com/attachments/image.png"
             :key "attachments/image.png"
             :id 9
             :hash "etag"))))
      (let ((result
             (sspai--upload-image-bytes
              (encode-coding-string "PNG" 'binary t)
              "image/png" "test")))
        (setq calls (nreverse calls))
        (should (equal (mapcar #'car calls)
                       '(credential qiniu)))
        (should
         (equal
          (nth 4 (cadr calls))
          '((token . "SHORT-LIVED")
            (key . "attachments/image.png")
            (id . 9))))
        (should (= (plist-get result :id) 9))))))

(ert-deftest sspai-test-upload-mime-contract-matches-current-editor ()
  (should (equal (sspai--mime-extension "image/png") "png"))
  (should (equal (sspai--mime-extension "image/jpeg") "jpg"))
  (should (equal (sspai--mime-extension "image/gif") "gif"))
  (should-error (sspai--mime-extension "image/avif")
                :type 'user-error)
  (should-error (sspai--mime-extension "image/apng")
                :type 'user-error))

(ert-deftest sspai-test-banner-upload-checkpoints-key-id-and-content-hash ()
  (sspai-test--with-temp-file
   ".png" "synthetic-png-bytes"
   (lambda (image)
     (let ((meta (sspai-test--metadata "Banner"))
           (uploads 0)
           (checkpoints 0))
       (setf (plist-get meta :banner) image)
       (cl-letf
           (((symbol-function 'sspai--upload-image-bytes)
             (lambda (_bytes mime context)
               (setq uploads (1+ uploads))
               (should (equal mime "image/png"))
               (should (equal context "题图"))
               (list
                :url "https://cdnfile.sspai.com/attachments/banner.png"
                :key "attachments/banner.png"
                :id 27
                :hash "etag"))))
         (should
          (equal
           (sspai--prepare-banner
            "/tmp/article.org"
            meta
            (lambda ()
              (setq checkpoints (1+ checkpoints))
              (should
               (equal
                (plist-get meta :banner-key)
                "attachments/banner.png"))
              (should (= (plist-get meta :banner-id) 27))))
           '("attachments/banner.png" . 27)))
         (should (= uploads 1))
         (should (= checkpoints 1))
         (should (equal (plist-get meta :banner-key)
                        "attachments/banner.png"))
         (should (= (plist-get meta :banner-id) 27))
         (should
          (string-match-p
           "\\`[[:xdigit:]]\\{64\\}\\'"
           (plist-get meta :banner-hash)))
         ;; The same bytes must use the checkpoint rather than upload again.
         (should
          (equal
           (sspai--prepare-banner
            "/tmp/article.org" meta
            (lambda () (setq checkpoints (1+ checkpoints))))
           '("attachments/banner.png" . 27)))
         (should (= uploads 1))
         (should (= checkpoints 1))
         ;; The path is not the identity: changed bytes must upload again.
         (with-temp-file image
           (insert "different-synthetic-png-bytes"))
         (let ((old-hash (plist-get meta :banner-hash)))
           (should
            (equal
             (sspai--prepare-banner
              "/tmp/article.org" meta
              (lambda () (setq checkpoints (1+ checkpoints))))
             '("attachments/banner.png" . 27)))
           (should-not
            (equal old-hash (plist-get meta :banner-hash))))
         (should (= uploads 2))
         (should (= checkpoints 2)))))))

(ert-deftest sspai-test-body-image-is-cached-before-upload-checkpoint ()
  (let* ((bytes (encode-coding-string "PNG" 'binary t))
         (hash (secure-hash 'sha256 bytes))
         (cache (make-hash-table :test #'equal))
         checkpoint-called)
    (cl-letf
        (((symbol-function 'sspai--upload-image-bytes)
          (lambda (actual-bytes mime context)
            (should (equal actual-bytes bytes))
            (should (equal mime "image/png"))
            (should (equal context "正文图片"))
            (list
             :url "https://cdnfile.sspai.com/attachments/body.png"
             :key "attachments/body.png"
             :id 3))))
      (let ((rewritten
             (sspai--rewrite-body-images
              "<p><img src=\"data:image/png;base64,UE5H\"></p>"
              "/tmp/"
              cache
              (lambda ()
                (setq checkpoint-called t)
                (should
                 (equal
                  (gethash hash cache)
                  "https://cdnfile.sspai.com/attachments/body.png"))))))
        (should checkpoint-called)
        (should
         (string-match-p
          "src=\"https://cdnfile\\.sspai\\.com/attachments/body\\.png\""
          rewritten))))))

(ert-deftest sspai-test-body-image-cache-hit-does-not-upload-or-checkpoint ()
  (let* ((bytes (encode-coding-string "PNG" 'binary t))
         (hash (secure-hash 'sha256 bytes))
         (url "https://cdnfile.sspai.com/attachments/cached.png")
         (cache (make-hash-table :test #'equal))
         checkpoint-called)
    (puthash hash url cache)
    (cl-letf
        (((symbol-function 'sspai--upload-image-bytes)
          (lambda (&rest _arguments)
            (error "cached bytes must not upload"))))
      (let ((rewritten
             (sspai--rewrite-body-images
              "<img src=\"data:image/png;base64,UE5H\">"
              "/tmp/" cache
              (lambda () (setq checkpoint-called t)))))
        (should (string-match-p (regexp-quote url) rewritten))
        (should-not checkpoint-called)))))

(ert-deftest sspai-test-body-external-http-images-remain-external ()
  (let ((cache (make-hash-table :test #'equal))
        checkpoint-called)
    (cl-letf
        (((symbol-function 'sspai--upload-image-bytes)
          (lambda (&rest _arguments)
            (error "external image must not upload"))))
      (let ((rewritten
             (sspai--rewrite-body-images
              (concat
               "<p><img src=\"http://images.example/a.png\">"
               "<img src=\"https://images.example/b.png\"></p>")
              "/tmp/" cache
              (lambda () (setq checkpoint-called t)))))
        (should (string-match-p
                 "src=\"http://images\\.example/a\\.png\"" rewritten))
        (should (string-match-p
                 "src=\"https://images\\.example/b\\.png\"" rewritten))
        (should-not checkpoint-called)
        (should (= (hash-table-count cache) 0))))))

(ert-deftest sspai-test-upload-checkpoint-failure-has-dedicated-error ()
  (should-error
   (sspai--checkpoint-upload
    (lambda () (error "disk full"))
    "https://cdnfile.sspai.com/attachments/already-uploaded.png")
   :type 'sspai-image-uploaded-but-not-checkpointed))

(ert-deftest sspai-test-state-only-tracks-article-identity ()
  (let* ((file "/tmp/offline-sspai-test.org")
         (meta (sspai-test--metadata "Local"))
         (remote (sspai--normalize-article (sspai-test--article-object 4))))
    (cl-letf (((symbol-function 'sspai--read-source)
               (lambda (_) (list meta "Local body\n")))
              ((symbol-function 'sspai--article-get)
               (lambda (&rest _) remote)))
      (should (eq (plist-get (sspai--state file) :status) 'new))
      (setq meta (plist-put meta :id 42))
      (should (eq (plist-get (sspai--state file) :status) 'tracked))
      ;; Changing the remote title does not introduce a conflict state.
      (setf (plist-get remote :title) "Edited in browser")
      (let ((state (sspai--state file)))
        (should (eq (plist-get state :status) 'tracked))
        (should (equal (plist-get (plist-get state :meta) :title) "Local"))
        (should (equal (plist-get state :raw-body) "Local body\n")))
      (setq remote nil)
      (should (eq (plist-get (sspai--state file) :status) 'remote-deleted)))))

(ert-deftest sspai-test-concurrent-local-edit-blocks-checkpoint ()
  (sspai-test--with-temp-file
   ".org" "#+TITLE: Original\n\nBody\n"
   (lambda (file)
     (let ((meta (car (sspai--read-source file))))
       (should-not (sspai--assert-source-unchanged file meta))
       (with-temp-file file (insert "#+TITLE: Changed\n\nBody\n"))
       (should-error (sspai--assert-source-unchanged file meta)
                     :type 'sspai-source-changed)))))

(ert-deftest sspai-test-unsaved-buffer-edit-blocks-checkpoint ()
  (sspai-test--with-temp-file
   ".org" "#+TITLE: Original\n\nBody\n"
   (lambda (file)
     (let ((meta (car (sspai--read-source file))))
       (with-current-buffer (find-file-noselect file)
         (goto-char (point-max))
         (insert "Unsaved edit\n"))
       (should-error (sspai--write-source file meta)
                     :type 'sspai-source-changed)
       (should (equal (sspai-test--read-text file)
                      "#+TITLE: Original\n\nBody\n"))))))

(ert-deftest sspai-test-remote-write-checkpoint-failure-is-distinct ()
  (let ((meta
         (sspai-test--plist-with
          (sspai-test--metadata "Draft title")
          :id 42))
        (remote
         (sspai--normalize-article
          (sspai-test--article-object 4))))
    (cl-letf
        (((symbol-function 'sspai--assert-source-unchanged)
          (lambda (&rest _arguments) nil))
         ((symbol-function 'sspai--write-source)
          (lambda (&rest _arguments)
            (error "disk full"))))
      (should-error
       (sspai--checkpoint-pushed
        "/tmp/offline-sspai-test.org"
        meta remote)
       :type 'sspai-published-but-not-checkpointed))))

(ert-deftest sspai-test-write-always-publishes-local-content ()
  (let* ((remote (sspai--normalize-article (sspai-test--article-object 4)))
         (meta (sspai-test--plist-with (sspai-test--metadata "Local") :id 42))
         (state (list :status 'tracked :meta meta :raw-body "Local body\n"
                      :remote remote))
         calls)
    (cl-letf (((symbol-function 'sspai--prepare-write-assets)
               (lambda (_file actual-meta body)
                 (should (equal (plist-get actual-meta :title) "Local"))
                 (should (equal body "Local body\n"))
                 (push 'assets calls)
                 (list "<p>Local body</p>" nil)))
              ((symbol-function 'sspai--auto-save-confirmed)
               (lambda (actual-remote title html)
                 (should (equal title "Local"))
                 (should (equal html "<p>Local body</p>"))
                 (push 'autosave calls) actual-remote))
              ((symbol-function 'sspai--full-update-confirmed)
               (lambda (_remote payload _action)
                 (should (equal (alist-get 'title_last payload) "Local"))
                 (should (equal (alist-get 'body_last payload)
                                "<p>Local body</p>"))
                 (push 'update calls) remote))
              ((symbol-function 'sspai--checkpoint-pushed)
               (lambda (&rest _) (push 'checkpoint calls))))
      (sspai--write-state "/tmp/offline-sspai-test.org" state 'community)
      ;; Even a second save and browser-side changes use local content.
      (setf (plist-get remote :title) "Edited in browser")
      (sspai--write-state "/tmp/offline-sspai-test.org" state 'community)
      (should (equal (nreverse calls)
                     '(assets autosave update checkpoint
                              assets autosave update checkpoint))))))

(ert-deftest sspai-test-publication-checkpoint-keeps-local-editorial-fields ()
  (sspai-test--with-temp-file
   ".org" "#+TITLE: Local\n\nLocal body\n"
   (lambda (file)
     (pcase-let* ((`(,meta ,body) (sspai--read-source file))
                  (remote (sspai--normalize-article (sspai-test--article-object 4))))
       (sspai--checkpoint-pushed file meta remote)
       (pcase-let ((`(,saved ,saved-body) (sspai--read-source file)))
         (should (equal (plist-get saved :title) "Local"))
         (should (equal saved-body body))
         (should (= (plist-get saved :id) 42)))
       (should-not (string-match-p "BASE_HASH\\|SOURCE_HASH"
                                   (sspai-test--read-text file)))))))

(ert-deftest sspai-test-invalid-remote-blocks-publication-before-assets ()
  (dolist (change '((:type 2 user-error)
                    (:free nil user-error)
                    (:delete-status t user-error)
                    (:token nil sspai-api-error)))
    (let* ((remote (sspai--normalize-article (sspai-test--article-object 5)))
           (state (list :status 'tracked :meta (sspai-test--metadata "Local")
                        :raw-body "Local body\n" :remote remote)))
      (setf (plist-get remote (car change)) (cadr change))
      (cl-letf (((symbol-function 'sspai--prepare-write-assets)
                 (lambda (&rest _) (ert-fail "uploaded assets for invalid article"))))
        (should-error (sspai--write-state "/tmp/offline-sspai-test.org" state 'community)
                      :type (caddr change))))))

(ert-deftest sspai-test-auto-save-recovery-checks-new-remote-state ()
  (let* ((remote (sspai--normalize-article (sspai-test--article-object 5)))
         (fetched (copy-sequence remote)))
    (cl-letf (((symbol-function 'sspai--article-auto-save)
               (lambda (_) (signal 'sspai-api-error '("timeout"))))
              ((symbol-function 'sspai--article-get) (lambda (_) fetched)))
      (should (eq (sspai--auto-save-confirmed
                   remote (plist-get remote :title) (plist-get remote :body))
                  fetched))
      (setf (plist-get fetched :type) 2)
      (should-error (sspai--auto-save-confirmed
                     remote (plist-get remote :title) (plist-get remote :body))
                    :type 'user-error)
      (setf (plist-get fetched :type) 5
            (plist-get fetched :token) nil)
      (should-error (sspai--auto-save-confirmed
                     remote (plist-get remote :title) (plist-get remote :body))
                    :type 'sspai-api-error))))

(ert-deftest sspai-test-new-publish-checkpoints-id-before-follow-up-update ()
  (let* ((created
          (sspai--normalize-article
           (sspai-test--article-object 4)))
         (published
          (sspai--normalize-article
           (let ((object (sspai-test--article-object 5)))
             (setf (alist-get 'title object) "Local"
                   (alist-get 'title_last object) "Local"
                   (alist-get 'body object) "<p>Body</p>"
                   (alist-get 'body_last object) "<p>Body</p>")
             object)))
         (meta
          (sspai-test--plist-with
           (sspai-test--metadata "Local")
           :status "published"))
         (state
          (list
           :status 'new
           :meta meta
           :raw-body "Body\n"
           :remote nil))
         calls)
    (cl-letf
        (((symbol-function 'sspai--prepare-write-assets)
          (lambda (&rest _arguments)
            (push 'assets calls)
            (list "<p>Body</p>" nil)))
         ((symbol-function 'sspai--article-add)
          (lambda (payload)
            (push (list 'add
                        (alist-get 'type payload))
                  calls)
            created))
         ((symbol-function 'sspai--auto-save-confirmed)
          (lambda (remote _title _html)
            (push 'autosave calls)
            remote))
         ((symbol-function 'sspai--full-update-confirmed)
          (lambda (_remote payload action)
            (push
             (list
              'update action
              (alist-get 'type payload))
             calls)
            published))
         ((symbol-function 'sspai--checkpoint-pushed)
          (lambda (_file metadata remote)
            (push (if (= (plist-get remote :type) 4)
                      'interim-checkpoint 'final-checkpoint) calls)
            (sspai-test--plist-with metadata :id (plist-get remote :id)))))
      (sspai--write-state
       "/tmp/offline-sspai-test.org"
       state 'community)
      (should
       (equal
        (nreverse calls)
        '(assets
          (add 4)
          interim-checkpoint
          autosave
          (update community 5)
          final-checkpoint))))))

(ert-deftest sspai-test-community-publication-can-be-routed-to-audit ()
  (let ((payload (sspai-test--article-object 5)))
    (dolist (type '(1 2 5))
      (let* ((object (copy-tree payload))
             (_ (setf (alist-get 'type object) type))
             (remote (sspai--normalize-article object)))
        (cl-letf (((symbol-function 'sspai--article-update) (lambda (_) nil))
                  ((symbol-function 'sspai--article-get) (lambda (_) remote)))
          (should (eq (sspai--full-update-confirmed remote payload 'community)
                      remote)))
        (when (memq type '(1 2))
          (should (string-match-p "尚未公开"
                                  (sspai--write-result-label 'community remote)))
          (should-not (sspai--update-matches-p remote payload 'audit)))))))

(ert-deftest sspai-test-audit-transition-still-rejects-content-differences ()
  (let ((payload (sspai-test--article-object 5)))
    (dolist (field '(title title_last body body_last))
      (let ((object (copy-tree payload)))
        (setf (alist-get 'type object) 2
              (alist-get field object) "Changed remotely")
        (let ((remote (sspai--normalize-article object)))
          (cl-letf (((symbol-function 'sspai--article-update) (lambda (_) nil))
                    ((symbol-function 'sspai--article-get) (lambda (_) remote)))
            (should-error (sspai--full-update-confirmed remote payload 'community)
                          :type 'sspai-published-but-not-checkpointed)))))
    (let ((object (copy-tree payload)))
      (setf (alist-get 'type object) 4)
      (should-not (sspai--update-matches-p
                   (sspai--normalize-article object) payload 'community)))))

(ert-deftest sspai-test-public-write-commands-select-correct-action ()
  (let (actions)
    (cl-letf (((symbol-function 'sspai--current-source-file)
               (lambda () "/tmp/offline-sspai-test.org"))
              ((symbol-function 'sspai--state) (lambda (_) '(:status tracked)))
              ((symbol-function 'sspai--write-state)
               (lambda (_file _state action) (push action actions))))
      (sspai-publish-community)
      (sspai-submit-for-review)
      (should (equal (nreverse actions) '(community audit))))))

(ert-deftest sspai-test-rejects-non-org-source-files ()
  (dolist (suffix '(".md" ".markdown" ".txt"))
    (let ((file (concat (make-temp-name (expand-file-name "sspai-reject-"
                                                          temporary-file-directory))
                        suffix)))
      (with-temp-buffer
        (setq buffer-file-name file)
        (should-error (sspai-publish-community) :type 'user-error))
      (should-error (sspai--create-source file "Title")
                    :type 'user-error)
      (should-not (file-exists-p file)))))

(ert-deftest sspai-test-native-org-export-preserves-article-content ()
  (let* ((directory (make-temp-file "sspai-export-" t))
         (file (expand-file-name "article.org" directory))
         (image (expand-file-name "asset.png" directory)))
    (unwind-protect
        (progn
          (with-temp-file image (insert "test image"))
          (cl-letf (((symbol-function 'executable-find)
                     (lambda (&rest _) (ert-fail "export searched for an external program"))))
            (let ((html
                   (sspai--source-to-html
                    file
                    (concat "* 标题\n中文 *加粗* [[https://example.com][链接]]\n\n"
                            "[[file:asset.png]]\n\n"
                            "#+begin_src text\n<tag>&value\n#+end_src\n"))))
              (should (string-match-p "<h2[^>]*>标题</h2>" html))
              (should (string-match-p "中文" html))
              (should (string-match-p "<\\(?:b\\|strong\\)>加粗</" html))
              (should (string-match-p "href=\"https://example.com\"" html))
              (should (string-match-p "<img[^>]*src=\"asset.png\"" html))
              (should (string-match-p "&lt;tag&gt;&amp;value" html))
              (should-not (string-match-p "<html\\|<head\\|table-of-contents\\|section-number" html)))))
      (delete-directory directory t))))

(ert-deftest sspai-test-native-org-export-never-executes-babel ()
  (let ((org-export-use-babel t))
    (cl-letf (((symbol-function 'org-babel-execute-src-block)
               (lambda (&rest _) (ert-fail "executed a source block"))))
      (let ((html (sspai--source-to-html
                   "/tmp/article.org"
                   "#+begin_src emacs-lisp :exports both\n(message \"must not execute\")\n#+end_src\n")))
        (should (string-match-p "must not execute" html))))))

(ert-deftest sspai-test-empty-title-is-rejected-before-assets ()
  (cl-letf (((symbol-function 'sspai--prepare-write-assets)
             (lambda (&rest _) (ert-fail "prepared assets for empty title"))))
    (dolist (title '(nil "" "   "))
      (should-error
       (sspai--write-state "/tmp/article.org"
                           (list :status 'new :meta (list :title title))
                           'community)
       :type 'user-error))))

(ert-deftest sspai-test-org-checkpoint-is-idempotent ()
  (sspai-test--with-temp-file
   ".org" "#+TITLE: Title\n#+AUTHOR: Alice\n\n* Heading\n\nBody\n"
   (lambda (file)
     (pcase-let ((`(,meta ,body) (sspai--read-source file)))
       (sspai--write-source file meta))
     (let ((once (sspai-test--read-text file)))
       (pcase-let ((`(,meta ,body) (sspai--read-source file)))
         (sspai--write-source file meta))
       (should (equal once (sspai-test--read-text file)))))))

(ert-deftest sspai-test-new-article-only-creates-a-local-org-file ()
  (let* ((directory (make-temp-file "sspai-local-" t))
         (file (expand-file-name "article.org" directory)))
    (unwind-protect
        (cl-letf (((symbol-function 'sspai--http)
                   (lambda (&rest _) (ert-fail "new local file contacted server"))))
          (sspai-new-article file "Local article")
          (pcase-let ((`(,meta ,body) (sspai--read-source file)))
            (should (equal (plist-get meta :title) "Local article"))
            (should-not (plist-get meta :id))
            (should-not (plist-get meta :status))
            (should (string-empty-p (string-trim body)))))
      (when-let* ((buffer (find-buffer-visiting file)))
        (kill-buffer buffer))
      (delete-directory directory t))))

(ert-deftest sspai-test-checkpoints-preserve-exact-editorial-text ()
  (dolist (text '("#+title:  Title  \n#+AUTHOR: Alice\n\n"
                  "#+title:  Title  \n\n  Indented body\n\n"
                  "#+TITLE: Title\n\nBody without final newline"))
    (sspai-test--with-temp-file
     ".org" text
     (lambda (file)
       (let ((meta (car (sspai--read-source file))))
         (setf (plist-get meta :id) 42
               (plist-get meta :status) "published")
         (sspai--write-source file meta)
         (let ((saved (sspai-test--read-text file)))
           (should (equal saved
                          (concat "#+SSPAI_STATUS: published\n#+SSPAI_ID: 42\n" text)))
           (sspai--write-source file meta)
           (should (equal saved (sspai-test--read-text file)))))))))

(ert-deftest sspai-test-interrupted-first-publication-reuses-id-and-image-cache ()
  ;; Exercise actual export, checkpoints and retry through a mocked API boundary.
  (dolist (action '(community audit))
    (let* ((directory (make-temp-file "sspai-publish-" t))
           (file (expand-file-name "article.org" directory))
           (asset (expand-file-name "image.png" directory))
           (creates 0) (uploads 0) (fail-save t) remote)
      (unwind-protect
          (progn
            (with-temp-file asset (insert "fake PNG bytes"))
            (with-temp-file file
              (insert "#+TITLE: 本地文章\n\n[[file:image.png]]\n\n正文。\n"))
            (cl-letf
                (((symbol-function 'sspai--upload-image-bytes)
                  (lambda (&rest _)
                    (cl-incf uploads)
                    '(:url "https://cdnfile.sspai.com/attachments/image.png"
                           :key "attachments/image.png" :id 9)))
                 ((symbol-function 'sspai--api-data)
                  (lambda (method path &optional _query payload)
                    (pcase path
                      ("/matrix/editor/article/add"
                       (should (equal method "POST"))
                       (cl-incf creates)
                       (setq remote (append '((id . 42) (token . "EDIT") (free . t))
                                            (copy-tree payload t))))
                      ("/matrix/editor/article/single/info/get"
                       (copy-tree remote t))
                      ("/matrix/editor/article/auto/save"
                       (should (= (plist-get (car (sspai--read-source file)) :id) 42))
                       (when fail-save
                         (signal 'sspai-api-error (list "rejected" 403 path 'http)))
                       (setf (alist-get 'title_last remote) (alist-get 'title_last payload)
                             (alist-get 'body_last remote) (alist-get 'body_last payload)))
                      ("/matrix/editor/article/update"
                       (setq remote (copy-tree payload t)))
                      (_ (ert-fail (format "Unexpected API path: %s" path)))))))
              (should-error (sspai--write-state file (sspai--state file) action)
                            :type 'sspai-api-error)
              (let ((meta (car (sspai--read-source file))))
                (should (= (plist-get meta :id) 42))
                (should (equal (plist-get meta :status) "draft"))
                (should (= (hash-table-count (plist-get meta :image-cache)) 1)))
              (setq fail-save nil)
              (sspai--write-state file (sspai--state file) action)
              (should (= creates 1))
              (should (= uploads 1))
              (should (= (alist-get 'type remote) (if (eq action 'community) 5 2)))
              (should (string-match-p "https://cdnfile.sspai.com/attachments/image.png"
                                      (alist-get 'body_last remote)))
              (should (string-match-p "\\[\\[file:image.png\\]\\]"
                                      (sspai-test--read-text file)))
              (should (equal (plist-get (car (sspai--read-source file)) :status)
                             (if (eq action 'community) "published" "audit")))))
        (delete-directory directory t)))))

(provide 'sspai-test)

;;; sspai-test.el ends here
