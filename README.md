# sspai.el

从本地 Org 文件发布少数派文章。写作和保存都在本地完成，发布时通过
`firefox-cookies.el` 使用 Firefox 中已有的登录状态。

## 安装

只面向最新版 Emacs，不维护旧版本兼容；当前最低版本声明为 31.1。
使用内置的 `package-vc-install` 安装：

```elisp
(require 'package-vc)
(package-vc-install "https://github.com/DzmingLi/firefox-cookies.el")
(package-vc-install "https://github.com/DzmingLi/sspai.el")
```

配置 Firefox profile，然后在该 profile 中登录少数派：

```elisp
(require 'sspai)
(setq firefox-cookies-profile-directory "~/.config/mozilla/firefox/default/")
```

Emacs 需要支持 SQLite（`M-: (sqlite-available-p)` 返回非 `nil`）。
正文使用 Emacs 内置的 `ox-html` 导出，不需要外部转换工具。导出时不会
执行 Org Babel 代码块。

## 使用

打开本地 `.org` 文件，写作后用 `C-x C-s` 保存，再选择发布方式：

| 命令 | 行为 |
| --- | --- |
| `sspai-publish-community` | 立即发布到 Matrix 社区，已有文章则更新本地版本 |
| `sspai-submit-for-review` | 投稿到少数派编辑部 |
| `sspai-status` | 查看文章关联状态和远端编辑状态 |
| `sspai-new-article` | 新建本地 Org 文件 |
| `sspai-upload-image-file` | 单独上传图片并复制其 URL |

新文章不需要预先填写少数派元数据。例如：

```org
#+TITLE: 示例文章

* 标题

正文从这里开始。
```

保存只使用 Org/Emacs 自身的文件保存功能。发布命令始终以当前本地内容
更新远端，即使网页上修改过文章，也会被本地版本覆盖。

少数派可能将“立即发布”的文章转入审核。客户端会核对提交内容，写回
实际的 `audit` 状态并提示尚未公开。远端已进入审核或精选锁定状态时，
需要平台恢复可编辑状态后才能更新。

首次发布会先建立远端文章记录，再完成发布或投稿。客户端会立即保存
新文章 ID；若后续提交失败，重试时更新这条记录，避免重复创建。若创建
请求本身超时且结果无法确认，命令会停止；请先到少数派后台确认结果，
已有记录可将 ID 填入 `#+SSPAI_ID`，不要盲目重试。

## Org 字段

可选的文章设置：

| 关键字 | 含义 |
| --- | --- |
| `#+BANNER` | 本地题图文件路径 |
| `#+FILETAGS` | 文章标签，如 `:Emacs:效率:` |
| `#+SSPAI_ALLOW_COMMENT` | 省略时允许评论；关闭时写 `false` |
| `#+SSPAI_BENEFITS_STATEMENT_ON` | 是否启用利益相关声明，默认 `false` |
| `#+SSPAI_BENEFITS_STATEMENT_ID` | 启用利益声明时选择的声明类型 ID |

发布成功后，客户端维护 `SSPAI_ID`、`SSPAI_STATUS` 和图片上传缓存。
`SSPAI_STATUS` 记录实际发布结果，不决定下一次发布方式；每次操作由所选
命令决定。客户端只更新这些字段，保留本地标题、正文、标签及原有排版。
省略的可选设置不会在发布时自动补入文件。

已有官方标签会保留其服务端 ID；新标签名称作为自定义标签提交。

## 图片

Org 图片链接（如 `[[file:./image.png]]`）和 `#+BANNER` 指定的本地题图，
会在发布时上传。正文链接在提交的 HTML 中替换为 CDN 地址，Org 源稿保持
本地路径。上传缓存按文件内容保存，重复发布未变化的图片不会再次上传。

外部 HTTP(S) 正文图片保持外链。题图必须是本地文件，或带有匹配上传 ID
的少数派 CDN 图片。

支持 PNG、JPEG、GIF，单张上限 5 MB，超过 2 MB 会提示。每张图片上传
成功后立即保存缓存；若图片已上传但本地缓存保存失败，错误会给出 CDN
地址，修复本地文件后再继续。

## 认证

每次 API 请求通过 `firefox-cookies-get` 读取 `sspai_jwt_token`，转换为
Bearer token。不会扫描或猜测 Firefox profile；容器可通过
`firefox-cookies-origin-attributes` 选择。

账户 token、单篇文章编辑 token 和七牛上传凭据只在内存中使用，不写入
Org 文件。账户 Bearer 只发送到少数派 API，图片上传使用独立的七牛凭据。

## 测试

测试全部离线运行，不读取真实 Cookie，不发布文章。依赖已在 `load-path`
中时运行：

```sh
make check
```

或显式传入依赖路径：

```sh
make check EMACSFLAGS='--batch -Q' \
  ELISP_PATH='/path/to/firefox-cookies.el'
```

检查包括 ERT 测试和将编译警告视为错误的字节编译。GitHub Actions 使用
最新版 Emacs 开发快照运行相同检查。

## 许可

GPL-3.0-or-later。见 [LICENSE](LICENSE)。
