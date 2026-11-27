# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### A window, translated
- **Its texts can be selected and copied as text** (version at release: 1.2.0). A click selects a text, ⇧-click or ⌘-click adds one or takes it out, a drag selects every text it touches, ⌘A selects them all, and Esc takes the selection away (with nothing selected, it closes the window, as before). A selected text is highlighted where the picture shows it, and the pointer is a text cursor over a text.
- **Copy** and ⌘C copy the selected texts while there are some, and the picture while there are none; the bar and the button's tooltip say which (an error, or that texts were not translated, stays in the bar). What is copied is what the picture shows of each text (its translation, or its original where it stayed as it was or while **Original** is on), from the top down and left to right, one text to a line. A right-click on the selection also offers **Copy the Original** or **Copy the Translation**, and **Select All**.
- The selection stays when the window is translated anew and when **Original** is switched.

## [1.1.0] - 2026-11-27

### Updates
- **BTranslate looks for a newer version** once a day (half a minute after it starts, then hourly whether the last check is a day old): one small request to GitHub for `VERSION` on `main`, and one for whether that version's release is there. Nothing of the user's goes with them. **Check for updates once a day** on the new About page turns it off.
- **An About page,** the fifth of the settings: the version, the project's address and licences, whether there is a newer version with **Check Now** or **Update**, the two ticks, what a check sends and what an update does, the install line to copy, and, where the app is signed ad hoc, that each update takes the shortcut's permissions away.
- **Update** runs the installer again, as a process of its own that outlives the app, with its output in `~/Library/Logs/BTranslate-update.log`. When it fails, the About page shows its last line. After an update the user asked for, the settings open on the About page saying that the new version is installed.
- **Install updates automatically** (off unless turned on): a version found is installed as soon as nothing of BTranslate is on the screen. A version whose automatic update failed is not tried again by itself; **Update** still offers it.
- **The gears** of the popup, the typing panel and the translated window are tinted while a newer version waits, and open the About page.
- **The installer asks once** whether to install updates automatically: yes by default on a Mac with the certificate "BTranslate (this Mac)", no elsewhere, saying why. `BTRANSLATE_AUTOUPDATE=yes|no` answers beforehand. `uninstall.sh` also removes the updates' log.

## [1.0.0] - 2026-11-27

The first release.

### The popup
- **Services menu item "BTranslate":** select text in any app, right-click it and choose Services → BTranslate. The translation shows in a floating popup next to the mouse pointer, and the app you are in stays in front.
- **Three translation methods,** switchable in the popup:
  - **Google Translate,** free and without a key. When Google's first public endpoint limits requests, the second one takes over.
  - **An AI model** with your own API key: Anthropic (Claude), OpenAI, Google Gemini, DeepSeek, OpenRouter, or any OpenAI-compatible server such as Ollama, LM Studio or oMLX. The answer streams into the popup. It is offered only once it is set up: without an API key (or, for a server of your own, its address) it is left out of the popup's methods.
  - **Offline,** on the Mac itself: see below.
- **Several languages at once:** **+** in the popup adds another language of the list; each has its own row with a language menu, speaker, copy and ×, and its own translation. Long results scroll.
- **A second default language:** a text that is in the default language already is translated into the second default instead. Serbian in the other alphabet still counts as a translation.
- **A pencil next to the detected language:** when the guess is wrong, pick the language of the original from a searchable list (the ones picked lately come first), and the popup translates again.
- **Reading aloud:** a speaker button for the original and one for the translation. The Mac's own voices read, offline; the Croatian voice also reads Serbian and Bosnian. For a language macOS has no voice for, such as Latvian, Google Translate's voice reads the text, unless that is turned off in the settings.
- **Copy button and ⌘C;** Esc, ⌘W or a click anywhere else closes the popup; it can be dragged and stays where you put it.

### The shortcut
- **One shortcut for every app, ⌃⌥T unless another is chosen,** that does what fits. It needs macOS's Accessibility permission, which the Shortcut page of the settings asks for.
- **Text is selected:** its translation in the popup, by the text.
- **The cursor is in a text field:** a small panel opens under the cursor. What is typed there, in any language, is translated sentence by sentence while it is typed and written into the field. Return keeps it, Esc takes it out again. Where an app can't be written into, the panel shows the translation and Return pastes it. A field is written into only while it still holds what was put there. The panel has a menu for the language and the popup's selector for the method, for that one time, and a gear that opens the settings.
- **Neither:** a window is chosen in macOS's own picker (macOS asks for the permission to record the screen the first time). Its texts are read on the Mac, each is translated from whatever language it is in into one language, and the window's picture is shown with the translations painted over the originals. Under the picture, a language menu and the method selector translate it anew, and a gear opens the settings.
- **A window is read in under half a second:** macOS makes its reader of pictures ready for an app once, which takes about a minute, and BTranslate has that done in the background at the install and at each start. The texts then go to Google three requests at a time and to an AI provider four at a time; offline, a language's texts go to macOS's translation together and fill the window in as they come.
- **Opening at login,** so that the shortcut is there: ticked on a first setup.
- **A signing certificate of the Mac's own** (`tools/local-signing.sh`, optional) keeps the shortcut's permissions over updates.

### Without internet
- **The Offline method:** the translation built into macOS (Apple's Translation framework, macOS 26 or later). It needs no internet and the text stays on the Mac. About 25 languages; the lists in the settings mark which, and **Download** fetches one that macOS has not got yet.
- **A language pack for it:** NLLB-200 by Meta AI, converted to run on the Neural Engine (never the GPU), as an optional download of 906 MB (about 1.9 GB on disk with what macOS prepares of it). It adds about 140 languages macOS can't translate offline, Latvian and Serbian among them. The model is loaded for a translation and let go right after it. Non-commercial licence (CC-BY-NC 4.0); the recipe is in `tools/nllb`.
- **The pack where it is needed:** the installer asks whether to download it (a Mac with Apple silicon; Enter says yes), and a popup that can't translate offline for want of it shows a button that downloads it, at once or as soon as there is a connection, and then translates.
- **Languages told on the Mac:** the pack brings a detector of its own, Meta's language-identification model for NLLB-200's languages, made small (20 MB). With it BTranslate tells the language of 97 of 100 sentences right over the pack's languages; without it 35, the Mac's own recognizer knowing 53 languages. When BTranslate is not sure, it asks for the pencil and names what the text may be.
- **The popup goes over to the Offline method by itself** when there is no connection. A language that method has not got, or everything when the method is off, waits with a plain message and is translated as soon as the connection is back: also where the Mac has a network and only the server is out of reach, which the popup then asks again every ten seconds. A local AI server that does not answer is reported as that.
- **Reading aloud:** where only Google's voice could read a text, a note under the speaker button says that it can't be read aloud now, and why.

### Languages
- **Your own list of languages to translate into:** any of the 249 languages Google Translate knows, added with a searchable picker. Arrows or dragging put them in your order; **Make Default** and **Make Second** mark the two a popup opens with. The list starts with the Mac's own languages.
- **Defaults for each of the three things BTranslate translates,** on the Defaults page of the settings: the method for selected text, and the method and the language for what you type in a text field and for a window. Until the settings are saved, typing and windows use the popup's method, typing the second default language and a window the default one; saving keeps what the page shows.
- **Serbian in Latin and in Cyrillic script,** and from one alphabet into the other with every method. Going to Cyrillic, words that look foreign (GitHub, STL, "open-source") stay in Latin.
- **AI translations that really translate:** the model is told the language in English and in the language itself, and that changing the alphabet is not a translation, so Serbian → Russian comes out in Russian and not in Serbian Cyrillic.
- **BTranslate in English and in Russian:** every window, menu, tooltip and message, the names of all 249 languages and the installer. BTranslate follows the Mac's language, or the one set for it on the Languages page.

### Setup and install
- **Settings window,** in four pages, each short enough for a 13-inch screen: Translation (the methods, the AI provider, model and API key, with a Test button and the provider's live model list), Languages, Defaults and Shortcut. It opens after the install, from Spotlight or Finder, and from the gear in the popup, in the typing panel and under a translated window.
- **API keys in the login Keychain,** one per provider.
- **Nothing kept:** no history, no cache of what was sent or answered, no cookies. The shortcut's log holds no text: only what it did, in which app, and how long a window's reading and translating took.
- **One-line installer** that builds the app on your Mac (no sudo), and an uninstaller that takes away everything the app put there.
- **One BTranslate at a time:** a second copy, or a mistyped option on the command line, ends instead of answering the shortcut twice.
- **Tests without network or keys:** a mock server for both AI protocols and Google, an off-screen drawing of every window in both languages (with a check that no text is cut short), stand-ins for the other app's text field and for a window's picture, and speech made without sound. CI runs them on macOS 15 and macOS 26.

[1.1.0]: https://github.com/baakhoff/btranslate/releases/tag/v1.1.0
[1.0.0]: https://github.com/baakhoff/btranslate/releases/tag/v1.0.0
