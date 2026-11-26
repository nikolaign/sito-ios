# Keeping your SITO archive

I don't want SITO to decide where your reading history belongs. It works entirely on your phone, and you can choose whether to keep another encrypted copy somewhere else.

There are two ways to do that:

1. **Backup anywhere:** create one encrypted `.sitobackup` file and save it to any destination supported by the iPhone share sheet or Files app. No service credentials are given to SITO. This is a manual export.
2. **Private Cloudflare D1:** set up your own Worker and database, then turn on optional backup attempts as SITO is used. This takes a little setup but does not require keeping track of individual export files.

Both methods use the same 256-bit recovery key, stored in iOS Keychain. Backups are encrypted *before* anything is shared or uploaded.

## What actually goes into a backup?

Every record includes the original headline, publisher name and ID, Serbia/World section, original URL, publication date, summary, publisher categories and any external status label. It also preserves the thumbnail **URL**, not the image file, plus available author, canonical URL, language, modification date, text capture dates, and the **complete plain text** where SITO successfully obtained it. Paragraph boundaries survive the backup. Older backups can still be imported.

Normal SQLite history and encrypted backups **do not contain downloaded images**. For an original page with layout and images, manually choose **Save PDF** on that story. Then enable **Include saved PDFs (with images)** in the portable or Cloudflare backup settings. Only PDFs you've explicitly saved are included; this option does not download every image from every article. It can increase backup size significantly.

The **full text / total** counter under Storage & Backups distinguishes credible complete stories from RSS previews. An older SITO version counted some 150-character publisher teasers as complete; version 0.9.2 repairs that status without discarding the snippet. SITO retains substantial article bodies from feeds, attempts missing original pages after refresh, and offers batches of 40 older articles. Unavailable pages, paywalls and JavaScript-only bodies may remain previews. Backups cannot invent missing text, and merges preserve a credible complete copy rather than replacing it with a preview.

**Verify Cloud Archive** is a read-only audit available in Storage & Backups. It decrypts every referenced cloud chunk with the recovery key, checks the ciphertext hash, decoded payload fingerprint, article counts and all optional saved PDFs. It then reports the actual number of credible complete texts in the current cloud snapshot. It does not delete, replace or restore local or cloud records. The Worker never receives unencrypted article text.

## Where can the file go?

| Destination | What you need | How to use it | Backup mode |
| --- | --- | --- | --- |
| On My iPhone | Nothing | Save to Files | Manual; local only |
| iCloud Drive | Apple account; storage plan as needed | Save to Files | Manual |
| Google Drive | Its iPhone app and account | Enable the provider in Files | Manual |
| Dropbox | Its iPhone app and account | Enable the provider in Files | Manual |
| Microsoft OneDrive | Its iPhone app and account | Enable the provider in Files | Manual |
| Box | Its iPhone app and account | Enable the provider in Files | Manual |
| MacBook / AirDrop | Nearby Apple device | Choose AirDrop in Share | Manual |
| USB drive / external SSD | Compatible device and adapter | Save through Files | Manual |
| NAS / SMB share | Your server and credentials | Connect to Server in Files | Manual |
| Nextcloud, WebDAV, S3-compatible or other storage | A suitable Files-compatible client or the provider's own upload tool | Export and upload the encrypted file | Manual |
| Private GitHub repository | GitHub account | Upload a small backup separately, if practical | Manual, **not recommended** for long-term large binary history |
| Cloudflare D1 on Workers Free | Cloudflare account and one-time Worker setup | Connect from SITO's Advanced Options | Automatic attempts + manual backup/restore |

Most cloud providers offer different free and paid storage tiers. You choose the account and plan; SITO does not sell storage or receive your provider credentials. Exactly which share destinations appear depends on the apps and Files providers installed on your iPhone.

For a completely private setup with no third-party account, use an encrypted file on an external disk or your own NAS. For a quick everyday off-device copy, iCloud Drive or another Files provider is straightforward. For automatic backups while using SITO, Cloudflare D1 is the option currently integrated into the app.

## Export a portable backup

1. Open **Settings → Advanced Options → Storage & Backups**.
2. Under **Backup anywhere**, choose whether to include locally saved full-page PDFs.
3. Tap **Save encrypted backup anywhere**.
4. Choose **Save to Files**, AirDrop or another share destination. The output is a single `.sitobackup` file.
5. In **Recovery key for both backups**, reveal and save your Base64 key somewhere safe, ideally in a password manager on another device.

The key is *not* inside the file. Without it, the archive cannot be decrypted, even by the developer.

## Restore on another iPhone

1. Install SITO and open **Settings → Advanced Options → Storage & Backups**.
2. In the recovery-key section, **import the same key** used when the file was made.
3. Tap **Restore from backup file**, choose the `.sitobackup` file from Files, and wait for validation.
4. The archive, bookmarks and saved PDFs are merged into the local collection. Existing local stories are not removed.

SITO checks the encrypted metadata and every included PDF before changing the local archive. A truncated file or incorrect key is rejected. A restore never deletes your previous local data.

## A few practical notes

- SITO backs up all text and metadata actually available, but cannot invent full articles that publishers never supplied. Saved full-page PDFs are included only when opted in.
- Portable exports are manual snapshots. Export again whenever you want a newer copy. Automatic D1 backup is best-effort; iOS and LiveContainer can restrict background activity.
- Files on iCloud Drive or another provider use *that provider's* storage quotas and policies. SITO cannot prevent a third party from charging you for a paid plan you deliberately subscribe to.
- Keep two copies in different places before deleting important local history. Try restoring on a spare device first.
- A private GitHub repository is fine for code. It is a less natural choice for an expanding backup archive with large PDFs and Git history. If you use it anyway, keep the repository private and never upload your recovery key.

The Cloudflare setup is documented separately in [cloudflare/README.md](cloudflare/README.md).
