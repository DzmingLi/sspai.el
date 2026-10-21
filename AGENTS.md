# Development conventions

- Target the latest Emacs only. Do not add compatibility code or test matrices
  for older Emacs releases.
- CI follows the latest Emacs development snapshot. Keep the package's minimum
  Emacs version aligned with the current development baseline (currently 31.1).
- Only Org mode source files are supported; do not add Markdown/YAML support.
- Local Org files are authoritative. Publication pushes local
  content; do not add bidirectional synchronization or remote conflict checks.
- Use the built-in Org HTML exporter; do not add external conversion tools.
- Writing and saving stay local. Keep only explicit community publication and
  editorial submission flows; do not add remote draft saving, generic sync,
  payload inspection, article import, or browser-opening commands.
- Keep source metadata minimal. Do not persist values that can be derived from
  the article ID or package configuration.
- Authenticate directly through `firefox-cookies.el`. Keep service endpoints
  fixed; do not add alternate credential providers or configurable API hosts.
- Checkpoint only article identity/status and image caches. Preserve editorial
  text and formatting, and do not insert omitted optional settings.
- Explicit publishing commands submit without a confirmation prompt. Always
  upload local body images. Use one internal constant for the 5 MB image upload
  limit; do not add a 2 MB recommendation threshold or warning.
- Export body headings starting at h2; the article title occupies h1.
- Run `make check` before publishing changes. Tests must stay offline and must
  not read real Firefox cookies or publish real articles.
