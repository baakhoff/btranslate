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
- **Setup window:** which methods to use, the AI provider, model and API key (with a Test button and the provider's live model list), and which method a popup opens with. It opens after the install, from Spotlight or Finder, and from the gear in the popup.
- **37 languages to translate into,** the Mac's own languages first; Serbian in Latin and Cyrillic script. The source language is detected and shown.
- **The popup:** copy button and ⌘C; Esc, ⌘W or a click anywhere else closes it; it can be dragged and stays where you put it.
- **API keys in the login Keychain,** one per provider.
- **One-line installer** that builds the app on your Mac (no sudo), and an uninstaller.
- **Tests without network or keys:** a mock server for both AI protocols and Google, and an off-screen drawing of the popup and the settings window.

[1.0.0]: https://github.com/baakhoff/btranslate/releases/tag/v1.0.0
