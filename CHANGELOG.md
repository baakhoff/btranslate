# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-11-26

The first release.

### Added
- **Services menu item "BTranslate":** select text in any app, right-click it and choose Services → BTranslate. The translation shows in a floating popup next to the mouse pointer, and the app you are in stays in front.
- **Two translation methods,** switchable in the popup:
  - **Google Translate,** free and without a key. When Google's first public endpoint limits requests, the second one takes over.
  - **An AI model** with your own API key: Anthropic (Claude), OpenAI, Google Gemini, DeepSeek, OpenRouter, or any OpenAI-compatible server such as Ollama, LM Studio or oMLX. The answer streams into the popup.
- **A third method, Offline:** the translation built into macOS (Apple's Translation framework, macOS 26 or later). It needs no internet and the text stays on the Mac. About 25 languages; the lists in the setup window mark which, and **Download** fetches one that macOS has not got yet.
- **Without internet** the popup goes over to the Offline method by itself. A language that method has not got, or everything when the method is off, waits with a plain message and is translated as soon as the connection is back. A local AI server that does not answer is reported as that.
- **Setup window,** in two pages. *Translation:* which methods to use, the AI provider, model and API key (with a Test button and the provider's live model list), and which method a popup opens with. *Languages:* the list to translate into and the voice setting. It opens after the install, from Spotlight or Finder, and from the gear in the popup.
- **Your own list of languages to translate into:** any of the 249 languages Google Translate knows, added with a searchable picker and removable. Arrows or dragging put them in your order, and **Make Default** marks the one a popup opens with. The list starts with the Mac's own languages. Serbian comes in Latin and Cyrillic script. The source language is detected and shown.
- **Serbian from one alphabet into the other,** with either method. Google hands a Serbian text back as it is, so with Google the alphabet is changed on the Mac; going to Cyrillic, words that look foreign (Manyfold, STL, "open-source") stay in Latin.
- **Several languages at once:** **+** in the popup adds another language of the list; each has its own row with a language menu, speaker, copy and ×, and its own translation. Long results scroll.
- **AI translations that really translate:** the model is told the language in English and in the language itself, and that changing the alphabet is not a translation, so Serbian → Russian comes out in Russian and not in Serbian Cyrillic.
- **A pencil next to the detected language:** when the guess is wrong, pick the language of the original from a searchable list (the ones picked lately come first), and the popup translates again. Both Google and the AI model are told the language.
- **Reading aloud:** a speaker button for the original and one for the translation. The Mac's own voices read, offline; the Croatian voice also reads Serbian and Bosnian. For a language macOS has no voice for, such as Latvian, Google Translate's voice reads the text, unless that is turned off in the setup window.
- **In English and in Russian:** every window, menu, tooltip and message of BTranslate, the names of all 249 languages (Google's own Russian names; a language is found by its Russian, English or own name) and the installer. BTranslate follows the Mac's language; **BTranslate's language** on the Languages page of the setup window sets it to English or Russian for this app alone.
- **The popup:** copy button and ⌘C; Esc, ⌘W or a click anywhere else closes it; it can be dragged and stays where you put it.
- **API keys in the login Keychain,** one per provider.
- **One-line installer** that builds the app on your Mac (no sudo), and an uninstaller.
- **Tests without network or keys:** a mock server for both AI protocols and Google, an off-screen drawing of the popup, the settings window and the language pickers in both languages (with a check that no text is cut short), a check that every text has its translation, and speech made without sound. An optional on-screen check shows a popup for three seconds and confirms that the app in front stays in front and that typing reaches the pencil's search field.

[1.0.0]: https://github.com/baakhoff/btranslate/releases/tag/v1.0.0
