# Development conventions

- Target the latest Emacs only. Do not add compatibility code or test matrices
  for older Emacs releases.
- CI follows the latest Emacs development snapshot. Keep the package's minimum
  Emacs version aligned with the current development baseline (currently 31.1).
- Local Org or Markdown files are authoritative. Publication pushes local
  content; do not add bidirectional synchronization or remote conflict checks.
- Keep source metadata minimal. Do not persist values that can be derived from
  the article ID or package configuration.
- Run `make check` before publishing changes. Tests must stay offline and must
  not read real Firefox cookies or publish real articles.
