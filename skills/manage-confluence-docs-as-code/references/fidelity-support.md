<!--
SPDX-FileCopyrightText: 2026 SyuanTsai
SPDX-License-Identifier: Apache-2.0
-->

# Confluence fidelity support

The projection contract deliberately supports a narrow set of Markdown and Confluence storage constructs. Unsupported input remains visible with its location and source evidence; it is never silently discarded.

## Capability matrix

| Construct | Markdown form | Storage form | Capture (storage → Markdown) | Publish (Markdown → storage) | Blocking reason code |
| --- | --- | --- | --- | --- | --- |
| Paragraph break | `a  ` followed by a newline, or controlled `a<br>b` | `p/br` | Hard break | `<br>`, `<br/>`, and `<br />` become `br` | Non-exact raw HTML: `RawHtmlUnsupported` |
| Table-cell break | `a<br>b` in one cell | `td/br` or `th/br` | Literal `<br>` keeps the row on one line | Controlled `br` remains in the cell | Non-exact raw HTML: `RawHtmlUnsupported` |
| Heading break | `## a<br>b` | `h1`–`h6` containing `br` | Literal `<br>` keeps one heading | Controlled `br` remains in the heading | Non-exact raw HTML: `RawHtmlUnsupported` |
| Attribute-bearing `br` | For example `<br class="x">` | Not supported | Not applicable | Rejected | `RawHtmlUnsupported` |
| `code` macro with language | Fenced code with `language {data-confluence-macro=code}` | Root `code` structured macro with one `language` parameter and one plain-text body | Preserved as the marked fence | Preserved as the explicit macro subset | Invalid shape: `UnsupportedMacroParameter`; unrepresentable body: `MacroBodyUnrepresentable` |
| `code` macro without language | A fenced code block whose info string is `{data-confluence-macro=code}` with no language | Root `code` structured macro with one plain-text body | Preserved as the marked fence | Preserved without inventing a language | Invalid shape: `UnsupportedMacroParameter` |
| `code` macro with other parameters | No supported form | For example `title`, `linenumbers`, rich-text body, duplicate or invalid language | Rejected with source evidence | Not emitted | `UnsupportedMacroParameter` |
| Mermaid fence | A fenced code block whose info string is `mermaid`; add `{data-confluence-macro=code}` only to request a code macro | Native `pre/code` by default; explicit marker produces a root `code` macro with language `mermaid` | Native code or the marked macro fence | Native code or the explicit `code` macro | Bad marker or attributes: `UnsupportedAttribute` |
| `mermaid-cloud` macro | A block image bound to a managed `.mmd` `text/plain` asset | Root `mermaid-cloud` macro with exactly `filename` and `revision` | Image link under `assets/`, with revision retained in projection metadata | Content-addressed `.mmd` attachment, revision `1` | `MermaidMacroNotBlock`, `MermaidRevisionUnavailable`, or `MermaidRevisionConflict` |
| `mermaid-cloud` extra parameters or revision mismatch | No supported form | Any parameter beyond `filename` and `revision`, invalid values, or unavailable attachment version | Invalid shape is unsupported; unavailable revision makes capture partial | Conflicting remote revision blocks preview | `UnsupportedMacroParameter`, `MermaidRevisionUnavailable`, or `MermaidRevisionConflict` |
| PDF/text/binary attachment link | A text-only relative link bound to a managed PDF, `text/plain`, or octet-stream asset | `ac:link` with one `ri:attachment` and optional plain-text link body | Link under `assets/`; attachment is recorded | Content-addressed attachment link | `AttachmentLinkLabelUnsupported`, `MacroBodyUnrepresentable`, `LinkProjectionUnsupported`, or an asset validation reason |
| Image | A block or inline image bound to a managed PNG, JPEG, or GIF asset | `ac:image/ri:attachment` | Image under `assets/` | Content-addressed image attachment | `AssetProjectionUnsupported` |
| Unbound asset | Relative image or attachment reference without exactly one mapping asset | No supported form | Unresolved captured attachment makes capture partial | Rejected | `ProjectedImageAttachmentUnresolved`, `AssetProjectionUnsupported`, or `LinkProjectionUnsupported` |
| Unknown macro | No supported form | Any macro other than the root `code` and `mermaid-cloud` subsets | Rejected with source evidence | Not emitted | `UnsupportedMacro` |
| Other raw HTML | No supported form; only exact attribute-free `<br>`, `<br/>`, and `<br />` are exceptions | Not applicable | Not applicable | Rejected | `RawHtmlUnsupported` |

## Adopting or migrating old POC evidence

Existing raw storage snapshots and attachment bytes, their hashes, and recorded page identity and version evidence remain useful and must be retained unchanged. Older captures do not contain the current Mermaid, code-macro, or attachment-link projections; they did not treat `.mmd` as a managed asset and do not bind `mermaid-cloud` revision to the captured attachment version.

Re-capture and manually review pages whose current projection changes. Import review reports `CaptureSourceChanged` when reprojecting their preserved raw storage no longer matches the old candidate. Do not edit only `schemaVersion` to make old data impersonate the new contract. Keep the old evidence unchanged, then create new capture, review, preview, and authorization evidence.

## `mermaid-cloud` limitations

- Image alt text and title are not written to storage.
- A newly managed `.mmd` is uploaded under its content-addressed remote name and bound to revision `1`.
- During capture, the macro revision must equal the current captured attachment version.
- Only the `filename` and `revision` parameters are supported. Other parameters observed in a real Confluence site are reported as unsupported.
- This change has not been validated against a live Confluence site.
