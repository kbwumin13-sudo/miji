<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/intro-en-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/assets/intro-en-light.svg">
    <img src="docs/assets/intro-en-light.svg" alt="Miji: Forgot the name? Follow the clues. Find files by pinyin, document text, and words in images." width="100%">
  </picture>
</p>

<p align="center">
  <a href="https://github.com/kbwumin13-sudo/miji/releases/tag/v1.4.1"><img src="https://img.shields.io/badge/release-v1.4.1-087e65" alt="Miji 1.4.1"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-172f2a?logo=apple&logoColor=white" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/Apple_Silicon-arm64-172f2a" alt="Apple Silicon arm64">
  <img src="https://img.shields.io/badge/processing-on--device-087e65" alt="Recognition, indexing and search run on your Mac">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-172f2a" alt="MIT License"></a>
</p>

<p align="center">
  <a href="https://github.com/kbwumin13-sudo/miji/releases/tag/v1.4.1"><b>Download Miji ↗</b></a> &nbsp; · &nbsp;
  <a href="#quick-start">Quick start</a> &nbsp; · &nbsp;
  <a href="#search-syntax">Search syntax</a> &nbsp; · &nbsp;
  <a href="README.md">简体中文</a>
</p>

**Find a file from the part you remember.** Miji is native macOS search for filenames, pinyin, document text and words inside images. Select a result to see its contents. Recognition, indexing and search run on your Mac.

## See the new search window

<p align="center">
  <a href="https://github.com/kbwumin13-sudo/miji/releases/download/v1.4.0/Miji-1.4.0-demo.mp4"><img src="docs/assets/miji-1.4.0-motion.gif" width="900" alt="Miji 1.4.0 in action: open search, enter Files, select a file to reveal its preview, and dismiss the window"></a>
</p>
<p align="center"><sub>Recorded in the release build with fictional files · <a href="https://github.com/kbwumin13-sudo/miji/releases/download/v1.4.0/Miji-1.4.0-demo.mp4">Download the full-resolution MP4</a></sub></p>

### Three modes in one window

| Mode | Shortcut | What you can do |
| --- | --- | --- |
| Applications | `⌘1` | Browse apps by category, select one with the keyboard, and launch it. |
| Files | `⌘2` | Browse recently used files, filter by type, and select a file to preview it on the right. |
| Clipboard | `⌘3` | Opt in to recording, then search and copy items from the current session. History clears when you quit. |

Press `⌘0` to return to all search. The window follows the system's light or dark appearance and uses native Liquid Glass where available.

## A little memory goes a long way

| What you remember | Try | How Miji finds it |
| --- | --- | --- |
| The filename contains 海棠灌溉 | `htgg` / `haitang` | Match Chinese filenames by initials or full pinyin |
| A proposal mentioned 滴灌 | `滴灌 ext:pdf` | Search PDF text, including scanned pages processed by OCR |
| A screenshot said 花园计划 | `花园计划 kind:图片` | Find images containing those words |
| You photographed a bird, but the filename starts with IMG | `鸟 kind:图片` | Search on-device image labels |

## Find it and take a look

- **See if it’s the file you need.** Preview results on the right. See highlighted text, matching PDF pages or code lines, and play supported media.
- **Tell identical names apart.** Results and previews show where each file lives. Narrow a query by type, path or indexed location and remove filters individually.
- **Keep searching after unplugging a drive.** Indexed filenames, extracted text and image labels remain searchable. Reconnect the drive to open the original.

## Built for everyday searching

| Detail | In practice |
| --- | --- |
| **Less typing in Chinese** | Search with Chinese characters, full pinyin or initials. Exact and prefix matches rank higher. |
| **Results as you type** | Name matches arrive first, followed by content matches. Changing the query or closing the panel cancels stale work. |
| **Relevant results first** | Exact names, frequently used prefixes and pinyin matches get priority. Content ranks by phrase matches and term proximity, appearing alongside ordinary name matches. |
| **Pick up where you left off** | Incremental scans follow changed paths. Restarts restore the name cache and replay file events. |
| **Your files stay on your Mac** | No uploads or telemetry. OCR uses the built-in Apple Vision framework; indexing and search are local. |

Indexing starts at `/`, including accessible system folders, hidden files and Library. App bundles and document packages count as single items. Cloud placeholders are indexed by name without triggering downloads. Manage recognition categories and indexed locations in Settings; removing a location does not delete the original files.

## Quick start

**Apple Silicon · macOS 14 or later**

1. [Download Miji 1.4.1](https://github.com/kbwumin13-sudo/miji/releases/tag/v1.4.1), unzip `Miji-1.4.1-macOS-arm64.zip`, and drag 觅迹.app into Applications.
2. **First launch**: Miji is ad-hoc signed and not yet notarized by Apple. If macOS cannot verify the developer, try opening the app once, then choose **Open Anyway** in System Settings → Privacy & Security. If it says the app “is damaged,” confirm the archive came from this repository's Releases, then run:

   ```sh
   xattr -dr com.apple.quarantine /Applications/觅迹.app
   ```

3. Enable 觅迹 in System Settings → Privacy & Security → Full Disk Access, then reopen it to index protected folders such as Documents and Desktop.
4. Press **`⌃⌥Space`** (Control + Option + Space), or click the menu bar magnifier. The first run builds a searchable file-name catalog; image and document content follows in background batches. Check progress in 索引与设置 (Index & Settings).

A SHA-256 checksum file is included on the release page. Upgrades preserve your index, scan scope and settings, with no rebuild required.

Use the buttons beside the search field to switch between Applications, Files and Clipboard. The Files view shows recently used files. Select one to preview supported images, document text and media on the right. Clipboard history is opt-in and is cleared when you quit Miji.

<details>
<summary>All keyboard shortcuts</summary>

| Keys | Action |
| --- | --- |
| `⌃⌥Space` | Show / hide search |
| `⌘1` / `⌘2` / `⌘3` / `⌘0` | Applications / Files / Clipboard / All search |
| `↑` `↓` | Move selection |
| `Return` | Open |
| `⌘Return` / `⌘R` | Reveal in Finder |
| `⌘Y`, or `Space` with the result list focused | Quick Look |
| `⌘C` | Copy the selected file; text editing keeps native copy behavior |
| `⌘⇧C` | Copy path |
| `⌘F` | Return to the search field |
| `⌘,` | Index & Settings |
| `Esc` / `⌘W` | Close the recent file preview, go back, or hide search |

The top tabs filter by file type. The filter menu controls name / content scope, indexed location and sort order.

</details>

<details>
<summary>How adaptive previews work</summary>

Automatic mode keeps metadata-only searches in a compact list and shows the content pane for pictures, documents, code and media. Choose Automatic / Show / Hide from the preview submenu under ⋯. In Recent Files, the pane opens after you select a file and keeps its size as you move between results.

File actions and full-path copying stay visible while text and code scroll independently. Offline results use stored content; previews never automatically unpack, download or re-extract files.

</details>

## Search syntax

Start with a keyword. Add a filter when you need one.

| Query | Effect |
| --- | --- |
| `海棠灌溉` | Search names and content |
| `htgg` / `haitang` | Match names by pinyin initials / full pinyin |
| `花园 滴灌` | Match all words |
| `"alpha beta"` | Exact phrase |
| `ext:pdf` | Filter by extension |
| `path:演示` | Filter by path |
| `花园 -草稿` | Exclude results containing 草稿 |
| `kind:image 海棠` | Images only; also supports `document`, `folder`, `video`, `audio`, `code`, `archive`, `application` and their Chinese names |

Up to 500 results are shown. Narrow them down by type, location or more keywords.

## Supported content

| Content | Search coverage |
| --- | --- |
| Text in images | On-device Vision OCR: PNG, JPEG, HEIC, TIFF, BMP, GIF and WebP; first frame of animations |
| Image content | Vision classification labels and common Chinese aliases, such as bird, flower and beach; not free-form natural-language semantic search |
| PDF | Text extraction, with OCR for pages without a text layer, including scans |
| Word / PowerPoint / Excel | DOCX body, headers and footers; PPTX slides and notes; XLSX cells. Legacy DOC uses system conversion; PPT and XLS use system import |
| Pages / Numbers / Keynote | System parsing first, then embedded PDF or preview images as a fallback; partial extraction is flagged in the UI |
| Text and code | TXT, Markdown, CSV, HTML, RTF / RTFD, EPUB, common source and configuration files |
| External drives | Indexed names, text and labels remain searchable offline; opening or previewing original files requires reconnecting |

<details>
<summary>Extraction limits and preview compatibility</summary>

- Per-file limits: 64 MiB input, 8 MiB extracted text and 128 MiB total ZIP expansion. Files over a limit keep a note and remain searchable by name. Password-protected documents are not decrypted.
- OCR, PDF and iWork parsing run one file at a time in a separate helper process. A file that exceeds 180 seconds is stopped and logged; indexing continues with the next file.
- Older PDFs with a text layer locate matching pages on demand. Older scans retain their OCR text and gain page locations when re-extracted. Stale locations are disabled if a file changes before its index catches up.
- Media formats depend on macOS support. Offline content previews use stored text; original-file previews need the drive online.
- Full-text completeness for modern iWork formats has not been validated against a large real-world sample. Offline and reconnect behavior has been tested with APFS disk images; physical drive unplugging has not been tested systematically.

</details>

## Performance and verification

The 1.4.0 release passed 257 automated tests (2 skipped) and 52 end-to-end checks, covering external APFS volumes, offline indexes, and content search.

1.3.0 checks candidate coverage, ranking and latency on a fixed fictional dataset: 800 files and 24 tasks, including 6 held out. Relevance labels are provisional development labels, without user-validated real-world task judgments.

<details>
<summary>1.3.0 search quality: gains and tradeoffs</summary>

Success@5 means at least one directly relevant document appears in the first five results. Text, paths and modification times stay fixed; only insertion order changes. Both versions use the same labels:

| Insertion order | Previous Success@5 | 1.3.0 Success@5 |
| --- | ---: | ---: |
| Forward | 37.5% | 100.0% |
| Reverse | 37.5% | 100.0% |
| Fixed-seed shuffle | 45.8% | 100.0% |

- **A retained tradeoff**: one multi-document task's nDCG@10 fell from 1.000 to 0.920 while Success@5 stayed unchanged. This metric gives no repeated gain to copies of the same content, exposing room to improve result diversity.
- **CLI latency after review fixes, with warm caches**: median / P95 across all tasks changed from 35.51 / 96.07 ms to 39.94 / 114.63 ms. Name-only median / P95 changed from 0.249 / 0.294 ms to 0.243 / 0.657 ms. Old and new versions alternated for 6 rounds on the same machine and dataset; statistics use the last 5. Core timings exclude name loading, and system caches were not cleared. These are not app-startup or cold-disk measurements.
- **Optimized AppModel evaluation**: across the same 9 successful tasks, P95 time to the first relevant result fell from 94.46 ms to 39.52 ms. Across all tasks, P95 time until the first ten results were stable with snippets ready rose from 145.57 ms to 158.86 ms. This used an optimized, testing-enabled bundle: the last 5 of 6 alternating rounds, 120 task runs per version. It measures model publication, not pixel rendering; old tasks with no relevant result are not recorded as zero latency.
- **Coverage remains bounded**: many duplicates, content indexed in the middle of the sequence, very long documents, or relevant passages late in a file may still be missed or rank lower because of budgets and limited text windows. The results apply to this dataset, not full-index recall or real-user task accuracy.

See the [search quality and interface evaluation](docs/search-quality-review.md) for methods, reproduction steps and limitations (in Chinese).

</details>

**Verification status**: the final full test run contained 231 tests: 228 passed, 2 skipped, and 1 existing isolated-extraction test failed. That test passed on its own, as did all 11 tests in the isolated-extraction suite; the original failure's cause remains unconfirmed. The standard Release after the fixes passed 52/52 end-to-end checks. See the [full report](docs/search-quality-review.md) for details and untested hands-on combinations.

The historical records below retain their original test conditions. They describe earlier index sizes and resource use, not new measurements of 1.3.0.

<details>
<summary>Benchmarks: name queries, memory and index size</summary>

1.1.0 · Apple M5 / 16 GB · 2,479,232 file names · 20 runs per query. P95 ranged from 9.7–77.5 ms across six Chinese, pinyin, initials and English queries. This includes name matching and result reads, not full-text search or initial indexing. Only aggregate results are retained here, without the original query strings.

- **Index size (1.1.0)**: the same index shrank from 51.07 GB to 7.28 GB through SHA-256 text deduplication and lossless LZFSE compression; all 840,123 extracted records were verified during migration.
- **Name cache restore (1.1.5)**: about 0.2–0.6 seconds for 3.54 million files, without a rescan.
- **Main-process resident memory (1.1.5)**: about 25–50 MB on an index of 3.54 million files, excluding per-file OCR / document helpers. The 1.1.4 comparison was 233–373 MB.
- **Scan CPU (1.1.5)**: a quarter to a third of the previous CPU time on the same folder tree, with identical scan results.

</details>

## Under the hood

SwiftUI / AppKit provide the native interface, Apple Vision recognizes images, and SQLite stores the catalog and full-text index. Name and content search return results in parallel; FSEvents drives incremental indexing in the background.

<details>
<summary>Architecture and modules</summary>

| Module | Responsibility |
| --- | --- |
| `MijiApp` | Search panel, menu bar, hotkey, settings, file previews and Quick Look |
| `MijiCore` | Scanning, FSEvents, SQLite / FTS5, extraction, content-evidence ranking and shared result merging |
| `CContentIndex` | `miji_grams` tokenizer: 1–3 character grams recall candidates, then verify against the original text |
| `OilFindCore` / `COilFind` | Oil Find's MIT name core and pinyin tables, extended with compact name columns and binary snapshots |
| `MijiCLI` | CLI and bundled single-file extraction helper `miji-extract` |

The index lives in `~/Library/Application Support/Miji/`, with directory access restricted to your user account. Image recognition, document text and external-drive processing can each be disabled; indexed content is retained.

</details>

<details>
<summary>Build from source</summary>

Building requires Xcode 26 or later with the macOS 26 SDK for the Liquid Glass APIs. The app still runs on macOS 14 and later, using a fallback material on earlier systems.

```sh
git clone https://github.com/kbwumin13-sudo/miji.git
cd miji
swift test                                               # Core and App tests
bash scripts/package.sh                                  # Release build, signing and packaging
python3 scripts/e2e-check.py --cli .build/release/miji-cli   # End-to-end checks
```

Packages are written to `output/`. Source may contain unreleased changes; use Releases for everyday use.

</details>

Missing a file, seeing a preview issue, or have an idea? [Open an issue](https://github.com/kbwumin13-sudo/miji/issues) with your macOS version, Miji version and steps to reproduce. Remove private information from sample files first.

## Credits and license

The name-matching core and pinyin tables come from [Oil Find](https://github.com/oil-oil/oil-find) v1.6.2 (MIT, Copyright © 2026 Lin Zhihuang). See [UPSTREAM.md](Vendor/OilFind/UPSTREAM.md) for the pinned commit and local changes. The panel's interaction design draws on Oil Find and macOS Spotlight.

Miji is open source under the [MIT License](LICENSE). `Vendor/OilFind` retains its [original MIT license](Vendor/OilFind/LICENSE), included in the app bundle.

<p align="center"><b>Less folder digging. More time for what you opened your Mac to do.</b><br><a href="https://github.com/kbwumin13-sudo/miji/releases/tag/v1.4.1">Download Miji ↗</a></p>
