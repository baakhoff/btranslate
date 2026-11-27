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
| `Checks.swift` | Checks of the shortcut's parts, for `tests/run.sh` |

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
- **The pack's model** is two Core ML programs, an encoder and a decoder, with 8-bit weights. The app has its own tokenizer for it (checked against Meta's on 60 texts) and searches for the translation with a beam of four. The model is loaded for a translation and let go right after it.
  - macOS prepares the models for the Neural Engine the first time they are loaded, and again after an update of itself. That takes a quarter of a minute and leaves a gigabyte and a half in the process that did it, so BTranslate has it done in a process of its own (`--pack-prepare`).
  - What macOS prepared, about 1 GB, it keeps among the app's caches, and would keep for every version of itself. BTranslate removes it with the pack, and what was prepared for an earlier macOS when it prepares anew. The pieces of the reader of pictures, which lie in the same folder under names that say nothing, are told from the pack's by their size and left there.
  - [tools/nllb](../tools/nllb/README.md) says how the pack is made and what the conversion had to get around.
- **The language of a text** has to be told on the Mac, and the pack writes nonsense when told a wrong one. The pack's detector, the Mac's own recognizer, a few letters and words of Latvian, Serbian and their neighbours, and your own languages all have a say; when together they are not sure, the popup says what the text may be and asks for the pencil.
- `BTranslate --offline` says whether a Mac has the method and which languages.

## The rest

- **BTranslate's own language** is chosen the way macOS chooses it for any app: the first of your languages that the app comes in. The choice in the settings is stored as the app's own `AppleLanguages` preference, which is also what System Settings → Language & Region → Applications sets. An app's language is fixed when it starts, so BTranslate then starts itself anew in the background.
- **The app is signed ad hoc** (no Apple developer account), which is why the installer builds it on your Mac instead of downloading a binary that Gatekeeper would block.
  - macOS ties a permission to the exact build of such an app, so the shortcut's permissions have to be given again after an update.
  - `tools/local-signing.sh` makes a certificate of this Mac's own, and the installer signs with it from then on: every build is then the same app to macOS. `BTRANSLATE_SIGN_IDENTITY` names another identity to sign with.
- **API keys** are read and written through `/usr/bin/security`, so an update (a new signature) does not bring up a Keychain prompt. The key is read once and remembered while the app runs.
- **The log of the shortcut,** `~/Library/Logs/BTranslate.log`, says which of its three things it did in which app, and how long a window's reading and translating took. It never holds a text: only its length.
