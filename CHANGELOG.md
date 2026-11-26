# Changelog

## 0.9.5

- Simplified Archive & Backup without hiding recovery and cleanup options entirely.
- Manual cloud backups now run an integrity check after uploading; repeat checks remain available under extra actions.
- Replaced broken and overlapping source collections with six verified OPML category files.
- Let each source choose Serbia or World when being added, with a sensible default based on its URL.
- Refined failure animations, changed symbol memory to sequential reveals and added longer maze dead ends.
- Added iOS compile checks alongside Android build and emulator tests.

## 0.9.4

- Smoother scrolling with large feeds and fewer unnecessary refreshes when adding sources.
- Source directories now load when selected instead of fetching every online collection at once.
- More careful article-text extraction, with a small daily limit on automatic completion attempts.
- Clearer backup status: uploading a backup and fully verifying its contents are separate steps.
- Per-source statistics for article-text capture attempts.

## 0.9.3

- Added a searchable feed directory with one-tap subscriptions and custom OPML, JSON and text lists.
- Added cached directory updates and manual refresh controls.

## 0.9.2

- Corrected the distinction between full article bodies and short RSS previews.
- Added a read-only cloud archive integrity check.
- Improved preservation of complete text during imports, restores and feed refreshes.

## 0.9.0–0.9.1

- Saved available article text and metadata to the local SQLite archive.
- Added encrypted Cloudflare backups and optional original-page PDFs.
- Restored original-publisher reading in Safari Reader.

## Earlier releases

- Established the Serbia/World feeds, custom sources, topic filters, bookmarks, reading layouts and diagnostics.
