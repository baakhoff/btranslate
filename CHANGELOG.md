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
- **Setup window:** which methods to use, the AI provider, model and API key (with a Test button and the provider's live model list), the languages to translate into, and which method a popup opens with. It opens after the install, from Spotlight or Finder, and from the gear in the popup.
- **Your own list of languages to translate into:** any of the 249 languages Google Translate knows, added with a searchable picker, removable and reorderable. It starts with the Mac's own languages. Serbian comes in Latin and Cyrillic script. The source language is detected and shown.
- **AI translations that really translate:** the model is told the language in English and in the language itself, and that changing the alphabet is not a translation, so Serbian → Russian comes out in Russian and not in Serbian Cyrillic.
- **The popup:** copy button and ⌘C; Esc, ⌘W or a click anywhere else closes it; it can be dragged and stays where you put it.
- **API keys in the login Keychain,** one per provider.
- **One-line installer** that builds the app on your Mac (no sudo), and an uninstaller.
- **Tests without network or keys:** a mock server for both AI protocols and Google, and an off-screen drawing of the popup, the settings window and the language picker.

[1.0.0]: https://github.com/baakhoff/btranslate/releases/tag/v1.0.0
