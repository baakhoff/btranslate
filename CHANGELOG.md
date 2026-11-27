# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

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
- **The cursor is in a text field:** a small panel opens under the cursor. What is typed there, in any language, is translated sentence by sentence while it is typed and written into the field. Return keeps it, Esc takes it out again. Where an app can't be written into, the panel shows the translation and Return pastes it. A field is written into only while it still holds what was put there.
- **Neither:** a window is chosen in macOS's own picker (macOS asks for the permission to record the screen the first time). Its texts are read on the Mac, each is translated from whatever language it is in into one language, and the window's picture is shown with the translations painted over the originals.
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
- **A language to write in:** the typing panel opens with the language chosen under **Write into text fields in**; the panel's own menu picks another for that time.
- **Serbian in Latin and in Cyrillic script,** and from one alphabet into the other with every method. Going to Cyrillic, words that look foreign (GitHub, STL, "open-source") stay in Latin.
- **AI translations that really translate:** the model is told the language in English and in the language itself, and that changing the alphabet is not a translation, so Serbian → Russian comes out in Russian and not in Serbian Cyrillic.
- **BTranslate in English and in Russian:** every window, menu, tooltip and message, the names of all 249 languages and the installer. BTranslate follows the Mac's language, or the one set for it on the Languages page.

### Setup and install
- **Settings window,** in three pages: Translation (the methods, the AI provider, model and API key, with a Test button and the provider's live model list), Languages and Shortcut. It opens after the install, from Spotlight or Finder, and from the gear in the popup.
- **API keys in the login Keychain,** one per provider.
- **Nothing kept:** no history, no cache of what was sent or answered, no cookies. The shortcut's log holds no text.
- **One-line installer** that builds the app on your Mac (no sudo), and an uninstaller that takes away everything the app put there.
- **One BTranslate at a time:** a second copy, or a mistyped option on the command line, ends instead of answering the shortcut twice.
- **Tests without network or keys:** a mock server for both AI protocols and Google, an off-screen drawing of every window in both languages (with a check that no text is cut short), stand-ins for the other app's text field and for a window's picture, and speech made without sound. CI runs them on macOS 15 and macOS 26.

[1.0.0]: https://github.com/baakhoff/btranslate/releases/tag/v1.0.0
