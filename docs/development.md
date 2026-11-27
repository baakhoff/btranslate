# Building and testing BTranslate

There is no Xcode project and there are no dependencies: `swiftc`, from the Command Line
Tools (`xcode-select --install`), compiles the files in `Sources/`.

```bash
./build.sh        # build/BTranslate.app for this Mac (--universal: Apple silicon + Intel)
tests/run.sh      # the tests: no network, no key, nothing shown on screen
./install.sh      # build, and install into ~/Applications
```

- **`build.sh` signs ad hoc,** or with the identity named in `BTRANSLATE_SIGN_IDENTITY`. `install.sh` uses this Mac's own certificate if `tools/local-signing.sh` has made one.
- **The installer builds on each user's Mac,** with whatever Command Line Tools are there. Anything newer than the macOS 14 SDK has to sit behind `#if compiler(…)` or `canImport`, as the Translation code does, or the install breaks on an older Mac. CI builds on macOS 15 (also with its oldest tools, Xcode 16.0) and macOS 26 for that reason. Tools older than those (Swift 5) were not tried.

## The tests

`tests/run.sh` runs the app's own command-line modes and compares what they print.

- **Nothing of yours is touched,** and nothing of this Mac is counted on: settings are given to each run as `-key value` arguments, the Keychain, the network, the login items and macOS's permissions are stood in for, and the language pack lives in `build/test-pack`.
- **It builds first** when the sources are newer than the app, and ends a run of the app that hangs after four minutes.
- **`tests/mock_server.py`** stands in for Anthropic, the OpenAI-style providers, Google Translate, Google's voice and the language pack's download.
- **`--live`** also uses the real Google Translate (one sentence), the real Keychain (a dummy key is saved, read and deleted), BTranslate's real preferences (its language is chosen, read back and put back), Apple's translation where this Mac has German and English, and the language pack if it is installed.
- **`--screen`** also shows a popup for a few seconds, to check what a picture can't: your app stays in front, and typing reaches the pencil's search field.

What the plain run covers:

- the app's own checks (`BTranslate --selftest`), in English and in Russian;
- that every text of the app has its Russian translation (`tools/check-strings.py`);
- translations through the mock server: streaming, refusals, bad keys, Google's second endpoint, the prompts an AI model gets;
- the popup, the settings window and the language pickers, drawn off screen into `build/uitest/` and, in Russian, `build/uitest-ru/`, with a check that no label or button is cut short;
- popups made off screen (`--popup-check`): the second default, the methods on offer with and without an API key, the offer of the language pack and its download;
- no connection (Google's address stops answering): the popup goes over to the Offline method, waits where it must, and translates when the connection is back. A stand-in answers for Apple's translation, so this runs on any Mac;
- a miniature language pack from the mock server: checksums, a damaged file, a download that goes on from where it stopped; and the installer's question about the pack, with each answer;
- a made-up detector file of a few rows, every answer compared with the Python that wrote it;
- speech made with a Mac voice, without playing it;
- the shortcut as the settings keep it, and its page of the settings window, where a click and three keys record one;
- typing into the panel, with a stand-in for the other app's text field: one that takes every writing, one that takes none, one that stops, one that is slow; Return, Esc and a click elsewhere; another method chosen in the panel;
- a picture that stands for a window: macOS reads it, the mock server translates it, and the check looks at which lines were put together, what was left alone, and the window that shows the result, also with another method chosen in its bar;
- a page of hundreds of texts: how many requests go out at once to Google, to an AI provider and to a server of your own (the mock server's "slow" addresses count them);
- the method and the language each of the three opens with, as the settings give them and as the Defaults page shows them; and that no page of the settings window is taller than a 13-inch screen has room for.

One check is run by hand, because it opens a small window of BTranslate's own for a few
seconds: `BTranslate --ax-check KIND` writes into a real field through Accessibility, as the
typing panel does. KIND is `appkit`, `input`, `textarea-empty`, `textarea`, `editable` or
`editable-full`. It needs the Accessibility permission and an unlocked screen, so run the
installed app:

```bash
open -n -g ~/Applications/BTranslate.app --stdout /tmp/ax.txt --args --ax-check input
```

## The command line

The app's binary, `build/BTranslate.app/Contents/MacOS/BTranslate`, has modes for trying
things. `Sources/main.swift` lists them all; the useful ones:

| | |
|---|---|
| `--print [--engine google\|ai\|device] [--from lv] [--to Russian] "text"` | Prints a translation. `-key value` settings go before the text. |
| `--detect "text"` | What the pack's detector, the Mac's recognizer and both together take a text for |
| `--picture-check FILE [--engine …] [--to …] [--times]` | A picture file read and translated as a window's picture is, with how long each step took |
| `--prepare-reading` | Has macOS make its reader of pictures ready, and says how long that took (a fraction of a second once it is) |
| `--offline [FROM TO]` | Whether this Mac has the Offline method, and which languages |
| `--pack`, `--pack-install`, `--pack-remove` | The language pack: its state, its download, its removal |
| `--speech-check lv "text"` | Which voice would read a text; plays it at volume zero |
| `--models` | The model list of the AI provider in the settings |
| `--login on\|off\|status` | Opening at login |

For one run, the environment can stand in for the world:

| Variable | What it does |
|---|---|
| `BTRANSLATE_LANGUAGE=en\|ru` | BTranslate's own language |
| `BTRANSLATE_GOOGLE_URL`, `BTRANSLATE_GOOGLE_SPEECH_URL` | Another address for Google Translate and its voice |
| `BTRANSLATE_PROVIDER`, `BTRANSLATE_BASE_URL`, `BTRANSLATE_MODEL`, `BTRANSLATE_API_KEY` | The AI provider, without the settings or the Keychain |
| `BTRANSLATE_KEYCHAIN=off` | No saved keys |
| `BTRANSLATE_CONNECTION=on\|off` | As if there were a network, or none, whatever the real one is |
| `BTRANSLATE_OFFLINE=mock` | A stand-in for Apple's translation |
| `BTRANSLATE_PACK_URL`, `BTRANSLATE_PACK_DIR` | Where the language pack is downloaded from, and kept |
| `BTRANSLATE_ACCESSIBILITY`, `BTRANSLATE_SCREEN`, `BTRANSLATE_LOGIN` `=on\|off` | Stand-ins for macOS's permissions and its login items: nothing is asked of macOS |

Any setting can be given for one run as `-key value` (`-defaultEngine google -languages '(en, ru)'`),
which leaves the saved settings alone.

## Odd jobs

- **The icon:** `swift tools/make-icon.swift` draws `Resources/AppIcon.icns`.
- **The language list:** `python3 tools/update-languages.py` rewrites `Sources/Languages.swift` from Google's own list, in English and in Russian (one request each), for when Google adds languages.
- **Another language for BTranslate itself:**
  - The texts are in English in the source, as `L("Save")`. A translation is one file, `Resources/<code>.lproj/Localizable.strings`, with the English text as the key: copy `Resources/ru.lproj` and translate it.
  - Add the language to `interfaceLanguages` in `Sources/Localization.swift`, to `CFBundleLocalizations` in `Resources/Info.plist` and to `LOCALIZATIONS` in `tools/update-languages.py`, then run that tool for Google's names of the languages.
  - `python3 tools/check-strings.py` says which texts are missing, left over, or lost a `%@`.
- **The language pack:** [tools/nllb](../tools/nllb/README.md).

## A release

1. The version, in three places: `VERSION`, `local VERSION=` in `install.sh`, and a section in `CHANGELOG.md`. CI checks that they agree.
2. `tests/run.sh --live`, and `--screen`.
3. A tag `vX.Y.Z` on `main`, and a GitHub release of it with the changelog's section. The one-line installer on `main` downloads the source of the tag its `VERSION` names, so the tag has to be there when that installer is.
4. The language pack is a release of its own, `nllb-200-v1`, and changes only with a new model.
