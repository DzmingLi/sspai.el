# sspai.el

在 Emacs 里撰写、保存与发布少数派文章，以本地稿件为准。支持 Markdown
与 Org 源稿，通过 `firefox-cookies.el` 使用 Firefox 中已有的登录状态。

## 安装

本包只面向最新版 Emacs，不维护旧版本兼容；当前最低版本声明为 31.1。
使用内置的 `package-vc-install` 依次安装依赖和本包：

```elisp
(require 'package-vc)
(package-vc-install "https://github.com/zkry/yaml.el")
(package-vc-install "https://github.com/DzmingLi/firefox-cookies.el")
(package-vc-install "https://github.com/DzmingLi/sspai.el")
```

然后加载并配置 Firefox profile：

```elisp
(require 'sspai)
(setq firefox-cookies-profile-directory "~/.config/mozilla/firefox/default/")
```

需要系统中可用的 Pandoc；读取 Firefox Cookie 还需要 Emacs 支持 SQLite
（`M-: (sqlite-available-p)` 应返回非 `nil`）。

## 功能

- 新建 Markdown 或 Org 稿件
- 保存草稿、直接发布到 Matrix 社区、提交少数派审核
- 把已有文章导入新文件，之后以本地稿件为准单向更新远端
- 上传正文图片与题图，并缓存已上传图片
- 通过 `firefox-cookies.el` 使用 Firefox 中的少数派登录状态

这个包不模拟登录；请先在自己配置的 Firefox profile 中登录少数派。

## 依赖

- 最新版 Emacs（当前版本声明为 31.1）
- [yaml.el](https://github.com/zkry/yaml.el) 1.2.4 或更高版本
- [firefox-cookies.el](https://github.com/DzmingLi/firefox-cookies.el) 0.1.0 或更高版本
- [Pandoc](https://pandoc.org/)（发布与导入正文时用于 Markdown/Org 和
  HTML 之间的转换）

将仓库加入 `load-path`，然后：

```elisp
(require 'sspai)
```

## 认证

默认通过 `firefox-cookies-get` 读取 `sspai_jwt_token` Cookie，转换为 API
所需的 Bearer token。先配置 Firefox profile（不会自动扫描或猜测）：

```elisp
(setq firefox-cookies-profile-directory "~/.config/mozilla/firefox/default/")
```

在该 profile 中登录 [少数派](https://sspai.com)，然后直接运行发布命令。
每次 API 请求都会重新读取 Cookie，Firefox 登录更新后无需复制 token 或
重启 Emacs。`firefox-cookies-origin-attributes` 可选择 Firefox 容器。
仅登录 token 会用于认证，其他 Cookie 不会发送给 API 或图片上传服务。

如需使用加密的 `auth-source` 后端，可设置
`(setq sspai-cookie-function nil)`，并在 `~/.authinfo.gpg` 中加入：

```text
machine sspai.com login sspai.el port https password YOUR_BEARER_TOKEN
```

也可以只为当前 Emacs 会话设置（优先于 Firefox 和 `auth-source`）：

```elisp
(setq sspai-access-token "YOUR_BEARER_TOKEN")
```

`sspai.el` 不会把账户 Bearer token 或单篇文章的编辑 token 写入源稿。
图片上传使用独立的短期七牛 token；账户 Bearer 只发送给配置的少数派
API base，不会发送到七牛域名。

包的默认服务地址如下，只需在全局配置中设置，稿件不保存 API 地址：

```elisp
(setq sspai-api-base-url "https://sspai.com/api/v1"
      sspai-site-base-url "https://sspai.com"
      sspai-upload-url "https://upload.qiniup.com/"
      sspai-cdn-base-url "https://cdnfile.sspai.com")
```

## 快速开始

运行：

```text
M-x sspai-new-article
```

选择 `.md`、`.markdown` 或 `.org` 文件后开始写作。常用命令：

| 命令 | 行为 |
| --- | --- |
| `sspai-save-draft` | 新建或更新远端草稿 |
| `sspai-publish-community` | 发布到 Matrix 社区 |
| `sspai-submit-for-review` | 提交少数派编辑审核 |
| `sspai-sync` | 按稿件的 `status` 单向推送本地内容 |
| `sspai-status` | 查看文章关联状态和远端编辑状态 |
| `sspai-show-payload` | 只读预览 payload；已有文章会先 GET 最新对象，但不写入或上传 |
| `sspai-import-article` | 将已有文章导入新文件，不覆盖现有源稿 |
| `sspai-open-remote` | 打开已发布文章 |
| `sspai-open-preview` | 打开当前稿件的网页预览 |
| `sspai-upload-image-file` | 单独上传一张图片并复制其 URL |

对已经发布的文章运行 `sspai-save-draft`，会保存新的编辑版本，但不会把
远端文章从已发布状态降回草稿；只有 `sspai-publish-community` 才会把该
编辑版本更新为公开正文。

少数派可能把「立即发布」转入审核。客户端会核对全文与其他字段，保存
服务端实际返回的 `audit` 状态，并明确提示尚未公开；此时不会重复发布。

创建草稿属于非幂等操作：如果请求超时而服务端是否成功未知，
`sspai.el` 会停止并报告“创建结果未知”，不会自动重试，以免生成重复
草稿。请先在少数派后台确认，再决定导入已有草稿或重新创建。

## 稿件格式

### Markdown

```markdown
---
title: "示例文章"
banner: "./images/banner.png"
tags:
  - Emacs
  - 效率
sspai:
  status: "draft"
---

正文从这里开始。
```

### Org

```org
#+TITLE: 示例文章
#+BANNER: ./images/banner.png
#+FILETAGS: :Emacs:效率:
#+SSPAI_STATUS: draft

正文从这里开始。
```

### 通用题图字段

题图属于文章本身，而不属于某个平台的命名空间：

- Markdown 只认顶层 `banner`
- Org 只认 `#+BANNER`

旧的顶层 `cover` / `#+COVER`，以及 `zhihu.banner`、`sspai.banner`、
`#+ZHIHU_BANNER` 或 `#+SSPAI_BANNER` 都不会作为题图读取，也没有旧字段
兼容层。同一份源稿因而可以由知乎与少数派适配器共享题图，各适配器只
负责各自的上传结果和远端 ID。

少数派的发布状态和图片上传缓存保存在 Markdown 的 `sspai` mapping 或 Org 的
`#+SSPAI_*` 关键字中。写回检查点时，其他顶层 YAML 字段、Org 关键字与
正文都会保留。

适合手动设置的少数派字段有：

| Markdown `sspai` 键 | Org 关键字 | 含义 |
| --- | --- | --- |
| `status` | `#+SSPAI_STATUS` | `draft`、`published` 或 `audit` |
| `allow-comment` | `#+SSPAI_ALLOW_COMMENT` | 是否允许评论，省略时默认 `true`；关闭时显式写 `false` |
| `benefits-statement-on` | `#+SSPAI_BENEFITS_STATEMENT_ON` | 是否启用利益相关声明 |
| `benefits-statement-id` | `#+SSPAI_BENEFITS_STATEMENT_ID` | 已有声明的数字 ID |

文章链接由 `id` 和站点地址自动推导，源稿不保存 URL 字段。

`id`、`banner-id`、`banner-key`、`banner-hash` 和上传缓存由客户端维护，
不建议手改。稿件不保存 `BASE_HASH` 或 `SOURCE_HASH`。

源稿中的 `tags` / `#+FILETAGS` 是字符串列表。更新已有文章时，名称匹配的
少数派官方标签会保留服务端返回的完整标签对象与 ID；其余名称作为
`custom_tags` 发送。新稿无法凭名称伪造官方标签 ID，因此默认都作为自定义
标签。

## 图片上传

正文中的本地图片和 `banner` 指向的本地题图会经过三个阶段：

1. 向少数派 API 申请短期上传凭据；
2. 使用短期凭据把文件直传七牛，且不携带账户 Bearer；
3. 正文图片把 CDN URL 写回 HTML；题图把 key 与 attachment ID 写入文章
   的 banner 字段。

第三阶段不是额外的“七牛登记”请求。编辑器另有面向远程图片 URL 的
`attachment/batch/upload` 转存接口，它不属于本地文件直传流程。

源稿保存内容哈希到 CDN URL 的缓存，重复发布未变化的图片不会再次上传。
外部 HTTP(S) 正文图片保持原样。题图需要可供少数派识别的 attachment ID，
因此应使用本地文件或已由当前账户上传并保存过检查点的少数派 CDN 题图。

默认接受 PNG、JPEG 与 GIF，单张上限 5 MB，超过 2 MB 会给出体积提示。
少数派题图的标准尺寸为 1420 × 708；中间的 708 × 708 区域应保留关键
视觉内容，以适应不同裁切方式。

每张图片上传成功后都会立刻保存缓存检查点。如果远端上传已经成功、但
本地文件写回失败，命令会用专门的错误说明“图片已上传但未保存检查点”；
这时不要盲目重试，可先复制错误中的 CDN URL 或修复本地文件权限。

## 以本地稿件为准

保存、发布和 `sspai-sync` 始终把当前本地内容推送到少数派。即使网页上
修改过文章，也会直接用本地稿件更新，无需额外的覆盖选项。

不会自动拉取远端正文，也没有双向同步或内容哈希检查点。
`sspai-import-article` 仅用于把已有文章导入一个新文件；创建本地源稿后，
后续编辑都在本地进行。

发布成功后只更新文章 ID、发布状态和图片上传信息，本地标题、正文、
标签和其他写作设置继续以源文件为准。发布期间若本地稿件发生变化，
会停止写回，避免覆盖刚完成的本地编辑。

单篇文章的编辑 token 仅存在于一次命令的内存中。每次更新都会先读取最新
文章信息，再使用服务端返回的 token，避免把易失凭据长期保存在文件中。

远端已进入精选/审核锁定等不可编辑状态时，客户端会拒绝更新；它不会把
服务端状态强行降回草稿。

## 测试

测试全部离线运行，HTTP、少数派 API 和七牛边界都使用 mock。
依赖位于 Emacs 的 `load-path` 时：

```sh
make check
```

依赖源码位于其他目录时，可以显式传入路径：

```sh
make check EMACSFLAGS='--batch -Q' \
  ELISP_PATH='/path/to/yaml.el /path/to/firefox-cookies.el'
```

`make check` 会运行离线 ERT 测试，并将字节编译警告视为错误。
GitHub Actions 跟随 Emacs 最新开发版（snapshot）运行相同检查。

## 许可

GPL-3.0-or-later。见 [LICENSE](LICENSE)。
