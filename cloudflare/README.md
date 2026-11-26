# A private Cloudflare archive for SITO

SITO works without a cloud account. If you'd like a second copy of your reading history, this folder contains a small **Cloudflare Worker + D1** backend you can deploy for yourself. You don't have to use the developer's server, and you don't have to share a database with other SITO users.

This version uses **D1 on the Workers Free plan**, not R2. You can set it up without entering a credit card. The free tier has hard limits; when you reach them, database operations fail instead of silently switching to paid usage. **Do not upgrade to Workers Paid if you want that protection.** Cloudflare's terms and limits can change; check their documentation when setting up your account.

The iPhone encrypts all available article text, metadata, bookmarks and optional manually saved PDFs using AES-256-GCM *before* upload. Cloudflare stores ciphertext and cannot read your articles. Image files are excluded by default; optional saved PDFs contain the original page and its images. The private Worker checks a token, and the recovery key stays on your device.

## One-time setup (about ten minutes)

1. Create a free [Cloudflare account](https://dash.cloudflare.com/) if you don't already have one. Stay on **Workers Free**. On your Mac, open Terminal in this repository's `cloudflare` directory:

   ```bash
   cd cloudflare
   cp wrangler.example.toml wrangler.toml
   npx wrangler login
   ```

   Wrangler may ask permission to install its command-line package.

2. Create your free SQLite database:

   ```bash
   npx wrangler d1 create sito-private-archive
   ```

   Copy the **database_id** (a UUID) from the result. If Wrangler asks whether to automatically add the binding to `wrangler.toml`, you can choose **No** and do step 3 manually.

3. Open your local `wrangler.toml`. Uncomment the four D1 binding lines, paste your UUID, and keep the binding name exactly **ARCHIVE**. The real configuration is ignored by Git so it can't accidentally be committed with your database settings:

   ```toml
   [[d1_databases]]
   binding = "ARCHIVE"
   database_name = "sito-private-archive"
   database_id = "your-real-uuid-from-step-2"
   ```

   If you accepted Wrangler's automatic binding in step 2, edit that binding to use `ARCHIVE` instead, and **do not add a duplicate**.

4. Create the tables remotely (once, before uploading):

   ```bash
   npx wrangler d1 execute sito-private-archive --remote --file=./schema.sql
   ```

5. Deploy your Worker:

   ```bash
   npx wrangler deploy
   ```

   Copy the HTTPS address ending in `.workers.dev`. The Worker has no public listing and refuses all access without your private token.

6. Generate a long, random access token:

   ```bash
   openssl rand -hex 32
   ```

   Save it in a password manager. Add it as a private Cloudflare secret:

   ```bash
   npx wrangler secret put SITO_TOKEN
   ```

   Paste the random token when prompted. **Never put it in a source file, GitHub issue, screenshot, or `wrangler.toml`.** The secret protects access to your personal endpoint; it is *not* your Cloudflare account credential.

## Connect your phone

1. Open **SITO → Settings → Advanced Options → Storage & Backups**.
2. Paste your HTTPS Worker URL, then paste the access token and tap **Save access token**. SITO keeps the token in iOS Keychain.
3. Tap **Generate recovery key** and copy the displayed Base64 key to your password manager, **outside the phone**. It is separate from the access token and is needed to decrypt your data.
4. Leave **Include saved PDFs** off for the first small test, or switch it on if you have space for complete offline page copies. Tap **Back Up Now**. Keep the app open while testing the first upload; LiveContainer may restrict background tasks.
5. Tap **Back Up Now**. The app then runs an end-to-end, read-only integrity check on the encrypted texts and optional PDFs. The verification result counts full texts in the cloud independently of the local count. You can repeat it under **More cloud actions**. Ideally test **Restore from Cloud** on a second device before removing local history.
6. Enable **Automatic backup** if you want later backups while using the app. iOS may occasionally allow background work, but it does not guarantee a schedule.

For a replacement device, enter the same Worker URL and access token, **import the same recovery key**, then choose **Restore from Cloud**. SITO merges history into the local archive. An older encrypted manifest is also available via **Restore previous cloud backup**.

If you lose the key and the original device is gone, **the encrypted cloud copy cannot be recovered**. If you lose only the access token, you can replace the Worker secret from your Cloudflare account.

## Storage and privacy

- D1 Free allows **500 MB per database** and enforces daily read/write quotas. This Worker has an additional conservative **360 MB logical-ciphertext ceiling** to allow room for SQLite bookkeeping, retries and partially uploaded chunks. Backup stops with an error if this budget is exhausted; it doesn't charge you or delete the local archive.
- Saved PDFs are optional. An individual PDF can be up to roughly 35 MB; the iPhone transfers large encrypted files in **separate 1 MB requests**, which the Worker stores as 1 MB BLOBs to fit both D1's 2 MB row limit and Workers Free's short CPU budget. Before a manifest references the file, the app downloads and checks its complete ciphertext. For years of articles, text backups are generally much smaller than PDF backups.
- Immutable encrypted article/PDF objects remain in D1 even after a later manifest stops referencing them. The Worker never automatically deletes cloud data or old history. A future garbage collector would need to honor the previous-manifest recovery path.
- Local history cleanup does not affect cloud storage. If you ever need to erase **all** cloud history, you can delete your D1 database from your own Cloudflare account. Be aware that this is permanent and breaks the existing Worker binding until you create and bind a new database.
- No passwords, access tokens or encrypted articles belong in the repository. Keep your local `wrangler.toml`, recovery key and `.sitobackup` files out of Git. The Worker exposes only known, authenticated object routes, not directory browsing.
- PDFs of publishers' pages can contain copyrighted material. Backups are intended for private personal use; respect publisher terms and don't redistribute your archive.

Official details: [D1 limits](https://developers.cloudflare.com/d1/platform/limits/), [D1 free-plan behavior](https://developers.cloudflare.com/d1/reference/faq/), [Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/).

## Running the tests

From this `cloudflare` folder:

```bash
node --test worker.test.mjs
```

Node.js 22+ provides the built-in SQLite module used by these tests. The tests exercise the real SQL schema in memory, SHA checks, multi-request PDF storage, manifest rollback and free-tier limits. They do **not** prove that a particular Cloudflare account is configured or that iOS/LiveContainer will run uploads in the background. Test a small backup and restore on your own account first.
