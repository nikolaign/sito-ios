# SITO

A quiet news reader for iPhone and Android, built around the simple idea that reading the news should feel like reading, not fighting an interface.

SITO brings together reporting from Serbia and around the world. You choose the publishers, the topics and how much you want to see. The default layout uses comfortable, book-like typography, with a compact view when you just want to scan the headlines.

## What you get

- A balanced news feed with thumbnails when publishers provide them.
- Serbian and English interface, light and dark themes, and two scrolling styles.
- Topic filters and the option to follow a single publisher at a time.
- Built-in RSS/Atom/JSON Feed support, plus a searchable directory of feeds you can add with one tap. You can bring your own OPML, JSON or text directory, too.
- Articles opened at the original publisher's website. iOS requests Safari Reader when available; Android offers a darkened WebView.
- Bookmarks, searchable local history and optional offline PDFs.
- An encrypted portable backup you can save wherever you like, or an optional private Cloudflare Worker and D1 backup.

Everyday controls are kept small. Source management, archive cleanup and backup settings live under **Advanced Options**.

## Sources and privacy

The initial selection includes N1, Danas, Nova.rs, KRIK, CINS, BBC World, DW English and The Guardian, alongside entries from Raspad Sistema. None of these is mandatory; you can remove them or add your own. Inclusion isn't a guarantee that every article is accurate, and some feeds may occasionally be unavailable.

The six built-in directory collections use community-maintained OPML lists from [Plenary](https://github.com/plenaryapp/awesome-rss-feeds). The directory is for discovery, not an endorsement of every publisher on a list.

## Advanced options

Open **Advanced Options** when you need more control. The source library offers News, Technology, Science, Business, Environment and Books. Choose a collection, tap a publisher to add it, and use the small region selector beside it to decide whether it appears under Serbia or World. For example, you can add a Serbian `.rs` feed to Serbia or place an international science feed under World. The app remembers your subscriptions; updating a collection never adds sources on its own.

Archive & Backup keeps everyday actions visible and puts connection details, recovery keys, integrity checks and cleanup controls behind expandable rows. You can export an encrypted `.sitobackup` through Files or Android's file picker to any storage provider. Direct automatic cloud sync currently supports **your own Cloudflare Worker backed by D1**, hosted by Cloudflare rather than self-hosted. Manual cloud backups run a full integrity check automatically; you can repeat it from the extra actions if needed.

There are no SITO accounts, ads or analytics. Normal reading needs no SITO server. The app connects to the news sites and directories you use; cloud backup is entirely optional and uses your own account.

History is stored on your phone in SQLite. SITO keeps available article text and metadata without downloading images into the regular archive. Some publishers only provide previews or block extraction, so **a saved record isn't always a complete article**. If you need an original page with images, save it manually as a PDF. On Android, use the system's **Save as PDF** print destination, then **Attach PDF** to include it in SITO's archive and backup. Backups are encrypted on the phone before being shared or uploaded. Keep the recovery key somewhere safe.

More detail: [backup and restore](BACKUP.md) · [set up your own Cloudflare archive](cloudflare/README.md).

## Build it

### iOS

You'll need a Mac with Xcode 15.4 or later. SITO targets **iOS 17+**.

1. Open `Sito.xcodeproj` in Xcode.
2. Choose your development team and, if needed, your own bundle identifier under Signing & Capabilities.
3. Select an iPhone or simulator and press **Run**.

For an unsigned IPA intended for a compatible sideloading setup such as LiveContainer, run this from the project directory:

```bash
./build-ipa.command
```

The resulting file is `build/SITO-0.9.4-unsigned.ipa`. It is **not** an App Store or normally signed iOS package.

### Android

The Android project is in `android/` and supports Android 8.0+. Clone with `git clone --recurse-submodules` (the included LZFSE decoder reads iOS backups), then open that directory in Android Studio with JDK 17. You can also install Android SDK 36 and Gradle 8.13 and run:

```bash
gradle -p android :app:assembleDebug
```

The installable test APK appears at `android/app/build/outputs/apk/debug/app-debug.apk`. Debug APKs are signed with the builder's debug certificate; for a distributable release with seamless future updates, use your own persistent release signing key. Android builds are checked in GitHub Actions on emulators.

On a Mac with Gradle and the Android SDK already installed, you can also double-click `build-apk.command`; it copies the APK into `build/` for easy access.

You can also download unsigned IPAs from [Releases](https://github.com/nikolaign/sito-ios/releases) when a tagged build succeeds. For maintainers, the **iOS unsigned IPA** workflow can be run manually from GitHub Actions; creating a matching `v0.9.4` tag builds and publishes a release automatically.

The optional Cloudflare Worker is in `cloudflare/`. You don't need it to build or read news. Its tests can be run with `node --test cloudflare/worker.test.mjs` on Node.js 22 or later.

## A note on articles

SITO is a reader, not a news publisher or fact-checking service. Headlines, article text, photographs and linked pages belong to their respective publishers. Respect their terms, and don't distribute personal archives of copied articles.

The project is still evolving. Bug reports and thoughtful contributions are welcome.

Licensed under [MIT](LICENSE). Developed by seraphi.
