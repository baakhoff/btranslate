# How BTranslate works

One native app of under 2 MB, written in Swift against macOS's own frameworks. There is no
Xcode project and there are no dependencies: `swiftc` compiles the files in `Sources/`.

| File | What is in it |
|---|---|
| `main.swift` | The app itself: the Services menu item, what the shortcut does, and the command line |
| `Popup.swift` | The popup |
| `Translate.swift` | Google Translate and the AI providers |
| `OnDevice.swift` | The Offline method: Apple's translation, and telling a text's language on the Mac |
| `NLLB.swift`, `Detect.swift` | The language pack: its download, tokenizer, translator and language detector |
| `Config.swift`, `Languages.swift` | The settings, the providers, the Keychain; the table of languages |
| `SettingsWindow.swift`, `LanguageList.swift` | The settings window and its language lists |
| `Speech.swift` | Reading aloud |
| `Hotkey.swift`, `Focus.swift` | The shortcut, and what it reads from the app in front |
| `TypeIn.swift` | Typing in another language |
| `Picture.swift`, `PictureWindow.swift` | A window, translated |
| `Localization.swift`, `LoginItem.swift` | BTranslate's own language; opening at login |
| `Updates.swift` | Looking for a newer version, and updating |
| `Checks.swift` | Checks of the shortcut's parts and of the updates, for `tests/run.sh` |

## The menu item and the popup

- **The menu item** is a macOS Service the app declares in its `Info.plist`. macOS hands it the selected text; no accessibility or screen permission is involved.
- **The popup** is a panel that does not activate its app, so your app keeps the front. The app stays running in the background after its first use, so later popups open at once.
- **One BTranslate runs at a time.** macOS sees to that for one copy of the app; a second copy in another folder, which would answer the shortcut too, finds a lock held and ends.

## The shortcut

A hot key macOS itself listens for and tells the app about; that part needs no permission.
It is a key by its place on the keyboard, so it is the same key in every layout.

- **What is selected,** and whether the cursor is in a text field, the app asks of the app in front through the Accessibility interface, with half a second's patience.
  - Where an app does not say what is selected, its own Copy command is chosen in its menu (never a key press), and the clipboard is put back.
  - Apps built with Electron show their text fields only once an assistive app asks for them. BTranslate asks, and waits up to a second.
- **Typing** writes into the field through the same interface, in one of two ways, and reads the field back to see that the text arrived.
  - A Mac's own field has the text before selected and replaced, from the first letter that differs.
  - A web page's field says yes to that and does nothing. There the field's whole text is set anew, with the cursor put back behind what was written. That is done only where it can do no harm: in a one-line field, or in a box that was empty. A box with text in it can't be told from a formatted editor, which a whole new text would flatten, so there the translation is pasted on Return.
  - Before each writing the field is read: it is written into only while it still holds what was put there, give or take a correction of the app's own. Another text in its place (another chat's draft, in an app that uses one field for all of them) is left alone.
  - A paste goes only to the app the panel was opened for, and only on Return. The clipboard is put back unless something was copied meanwhile.
  - `BTranslate --ax-check` does all this against a window of its own: a Mac text view, and a web page's `<input>`, `<textarea>` and editable `<div>`, empty and not.
- **A window's picture** comes from `SCContentSharingPicker`, the picker of ScreenCaptureKit, and `SCScreenshotManager`. The picker alone is not enough for macOS: on macOS 27 the picture is refused until the app may record the screen.
  - Vision reads the lines, in a process of its own that the app starts for each picture, so what the reading needs in memory goes with it. A window is read in a fifth to half of a second.
  - macOS prepares that reader for each program once (and again after an update of itself), in five pieces of some twelve seconds each, which it keeps among the app's caches. Three it prepares at the first picture; two more only at a picture with text that is hard to read, as every real window has somewhere. So BTranslate has all five prepared ahead, when it is installed and each time it starts, with a picture of its own drawing that brings them all on (`--prepare-reading`). Without that, the first full window takes half a minute.
  - Lines of a paragraph are put together (a full line of several words, with the next right under it), while the rows of a list stay apart.
  - The texts go to Google forty to a request, each from its own language, and three requests at a time; an AI provider gets them as numbered lines, twenty-five to a request and four at a time (a server of your own: sixty, one at a time).
  - Offline, the texts macOS's own translation can do go to it a language at a time, and the language pack's model stays in memory until the window's last text. macOS takes about a fifth of a second over each text, whatever is tried.
  - Each translation is painted over its original in letters of the same size (judged by the line's width, which macOS gives exactly) and colour, on the colour that was behind it.

## Translating

- **Google Translate** is reached through the public endpoints Google's own pages and Chrome use. They are not an official API. When the first one limits requests, the second takes over.
- **An AI model** is told the languages in English and in the language's own name, whatever BTranslate's language is, and that a change of alphabet is not a translation: without that, a small model asked for Russian hands Serbian back in Cyrillic letters.
- **Nothing is kept:** every request goes through one session without a cache and without cookies.
- **"No connection"** is what a failed request says, not a guess made beforehand. A local AI server that does not answer is reported as that, not as missing internet.
- **Waiting for the connection:** macOS tells when a network is back. With a network up and only the server out of reach (a router without internet, a VPN changing hands) nothing tells, so the popup asks the server every ten seconds, without any text, and translates when it answers.
- **Serbian in two alphabets:** Google writes Serbian in Cyrillic only, and hands a Serbian text back unchanged. So BTranslate changes the alphabet itself, in both directions.
  - Going to Cyrillic, it leaves in Latin what looks foreign: words with q, w, x or y, abbreviations such as STL, names like GitHub, and English in brackets or with a hyphen ("open-source").
  - A foreign name that nothing marks as foreign is converted letter by letter. The AI method does better with those.

## The Offline method

Apple's Translation framework, which translates on the Mac, and the language pack for what
Apple lacks.

- **Apple has about 25 languages,** and not Latvian, Serbian or Croatian: those need the language pack (or an AI model of your own on the Mac: the Custom provider with Ollama, LM Studio or oMLX runs without internet too).
- **Some Macs have all of Apple's languages ready:** on the one BTranslate was written on (macOS 27) none needed a download. On others each language is a download; macOS keeps them under System Settings → General → Language & Region → Translation Languages.
- **The pack's model** is two Core ML programs, an encoder and a decoder, with 8-bit weights. The app has its own tokenizer for it (checked against Meta's on 60 texts) and searches for the translation with a beam of four. The model is loaded for a translation and let go right after it; for a window's texts, after the last of them.
  - macOS prepares the models for the Neural Engine the first time they are loaded, and again after an update of itself. That takes a quarter of a minute and leaves a gigabyte and a half in the process that did it, so BTranslate has it done in a process of its own (`--pack-prepare`).
  - What macOS prepared, about 1 GB, it keeps among the app's caches, and would keep for every version of itself. BTranslate removes it with the pack, and what was prepared for an earlier macOS when it prepares anew. The pieces of the reader of pictures, which lie in the same folder under names that say nothing, are told from the pack's by their size and left there.
  - [tools/nllb](../tools/nllb/README.md) says how the pack is made and what the conversion had to get around.
- **The language of a text** has to be told on the Mac, and the pack writes nonsense when told a wrong one. The pack's detector, the Mac's own recognizer, a few letters and words of Latvian, Serbian and their neighbours, and your own languages all have a say; when together they are not sure, the popup says what the text may be and asks for the pencil.
- `BTranslate --offline` says whether a Mac has the method and which languages.

## Updates

- **The update is the installer again.** BTranslate has no developer signature, so a downloaded binary would be blocked by Gatekeeper; the installer builds from source on the Mac, and already knows how to replace a running app and keep its settings. An update runs `curl -fsSL https://raw.githubusercontent.com/baakhoff/btranslate/main/install.sh | bash`, the same line as the first install.
- **The check** asks for `VERSION` on `main` (`raw.githubusercontent.com`), the file the installer of that line takes its version from. A version is three numbers, compared number by number (1.10.0 is newer than 1.9.0); an answer that is not one is a failed check. A newer version counts only once `HEAD` of its source archive (`github.com/baakhoff/btranslate/archive/refs/tags/vX.Y.Z.tar.gz`) answers 200: the tag is pushed some minutes after `VERSION` changes, and until then the installer would fail.
  - Both requests go through the same session as every other, without cache or cookies, fifteen seconds at most together.
  - A last check dated in the future (the clock was set back) counts as none, so it does not hold off the next.
  - **When:** while the setting `checkForUpdates` is on, half a minute after the app starts and then every hour, if the last successful check (kept as `lastUpdateCheck`) is a day old. The Mac sleeps and the app runs for days, so the day is kept by that date rather than by one long timer. Also when the About page opens and the last check is more than an hour old, and whenever **Check Now** is clicked.
  - A check that fails says so only on the About page.
- **One object holds the state** (`Updater` in `Updates.swift`): never checked, checking, up to date, a version available, could not check, updating, the update failed, installed. The About page and the gears follow it.
- **Running the installer:** `/bin/bash -c` with the command, as a process of its own, with `BTRANSLATE_PACK=no` and `BTRANSLATE_AUTOUPDATE=keep` in its environment, so that it asks nothing and changes neither choice. Its output is appended to `~/Library/Logs/BTranslate-update.log`, and it reads nothing. The shell runs with `pipefail`: when the download fails, `bash` reads an empty script and ends with 0, and the update must end with curl's failure instead. The installer gets none of the app's own `BTRANSLATE_*` variables, and the app itself takes none of the stand-ins of the checks (`BTRANSLATE_UPDATE_*`, `BTRANSLATE_VERSION`, `BTRANSLATE_DISK_VERSION`, `BTRANSLATE_SIGNED`): a copy in use has no switch that runs another command or fetches another script.
  - The installer ends the app (`pkill -a -x BTranslate`) before it replaces it, and starts the new one. The `-a` is what makes that work from the app's own Update: `pkill` leaves its own ancestors alone unless told otherwise, and the app that started the installer is its ancestor. The installer of 1.1.0 had no `-a`: the first real update, 1.0.0 to 1.1.0, installed the new version and left the old copy running.
  - The update's process outlives the app: it is not a BTranslate process (pkill matches the name exactly), it has no terminal that could hang it up, and once the app is gone macOS makes it a child of launchd. It writes into a file, never into a pipe the app holds, which would kill it with a broken pipe once the app is gone. A check holds that with a stand-in for the app: the built program under another name starts the installer's ending step the way the app does, is ended by it, and the step's shell goes on.
  - The app does not count on the installer alone: when the installer ends well and this copy still runs while the version on disk is the one aimed at (or a newer one), the copy ends itself and opens the one on disk in the background. The note below stays, so the new copy says that it is installed.
  - Before it starts, the app notes in its settings what it started (`updateFrom`, `updateTo`, `updateAsked`). At the next start the note goes; if that start is the version aimed at and the update was the user's, the settings open on the About page saying that it is installed. If it is not, the About page says that the update did not finish, with the log's last line. These, `lastUpdateCheck` and `autoUpdateFailed` are written by the app itself, not by **Save**, and only by the app: every command-line mode keeps them in memory.
  - Otherwise, if the installer ends while the app still runs, it replaced nothing. Ended with a failure (no Command Line Tools, no network, a build that failed), the About page shows its last line and the log's path; ended well, **Update** stays on offer.
- **Automatic updates:** with `autoUpdate` on, a version found is installed as soon as no popup, typing panel, translated window, window picker or settings window of BTranslate is showing; until then the app looks again every minute. When an automatic update fails, its version is kept as `autoUpdateFailed` and is not tried again by itself (on a Mac without the Command Line Tools it would fail the same way every day); **Update** still offers it, and a newer version is tried again.
- **The installer's question** about automatic updates comes once, when `autoUpdate` has never been set and there is a terminal to ask on. It is asked before the download and the build, and the answer is stored as that setting only once the new app is in place, so an installer stopped at the question has changed nothing. Its default is yes where the Mac has the certificate "BTranslate (this Mac)" and no where it has not: every update of a copy signed ad hoc takes the shortcut's permissions away.
- **How the app is signed** it asks of macOS (`SecCodeCopySigningInformation`, the ad hoc flag), to say on the About page what an update does to the permissions.

## The rest

- **BTranslate's own language** is chosen the way macOS chooses it for any app: the first of your languages that the app comes in. The choice in the settings is stored as the app's own `AppleLanguages` preference, which is also what System Settings → Language & Region → Applications sets. An app's language is fixed when it starts, so BTranslate then starts itself anew in the background.
- **The app is signed ad hoc** (no Apple developer account), which is why the installer builds it on your Mac instead of downloading a binary that Gatekeeper would block.
  - macOS ties a permission to the exact build of such an app, so the shortcut's permissions have to be given again after an update.
  - `tools/local-signing.sh` makes a certificate of this Mac's own, and the installer signs with it from then on: every build is then the same app to macOS. `BTRANSLATE_SIGN_IDENTITY` names another identity to sign with.
- **API keys** are read and written through `/usr/bin/security`, so an update (a new signature) does not bring up a Keychain prompt. The key is read once and remembered while the app runs.
- **The log of the shortcut,** `~/Library/Logs/BTranslate.log`, says which of its three things it did in which app, and how long a window's reading and translating took. It never holds a text: only its length.
