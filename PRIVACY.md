# Privacy Policy

**Audiobook Studio** · Version 2 · 10 October 2026

## In short

- **We collect nothing.** The developer of Audiobook Studio does not collect, receive, store, sell or share any data about you or your use of the app. There are no accounts, no analytics, no telemetry, no advertising, no tracking and no crash reporting.
- **Your books, voices and audiobooks stay on your Mac.** They are never sent to the developer or to anyone else by the app.
- **Narration works offline.** Once the models are downloaded, books are narrated on your own Mac. (Tested: full conversions run with all network access blocked.)
- **Downloads come from other companies.** When you install the app, add a language, download a voice model or check for an update, your Mac connects directly to third-party websites (listed below). Those sites can see your IP address and the request, under their own privacy policies. We do not receive or control that information.

## 1. Who we are

"We", "the developer" and "the app" mean the developer of Audiobook Studio, an open-source application published at https://github.com/MeetVox-AI/audiobook-studio. Questions can be asked in the project's GitHub Issues. Please do not post personal information there.

## 2. Data we do NOT collect

We do not collect or receive any of the following, from the app or from the engine that comes with it:

- your name, email address, or any account or identifier (the app has no accounts);
- the books, text, covers or audiobooks you open or create;
- voice recordings or cloned voices, or what you narrate;
- your settings, usage statistics, device information, location or IP address;
- crash reports, logs, analytics, telemetry or advertising identifiers.

The app and its engine contain no analytics, telemetry, advertising, tracking or crash-reporting code. The libraries that download models have their own telemetry switched off by the app (`HF_HUB_DISABLE_TELEMETRY` and `DO_NOT_TRACK`), and Homebrew's analytics are switched off for the installation the app runs. The update checker is configured not to send a system profile.

## 3. What stays on your Mac

Everything you create or configure is stored locally:

| What | Where |
|---|---|
| Conversion jobs, working files, caches, your reference voices, measured speeds, language choices | `~/Library/Application Support/AudiobookStudio` |
| Downloaded voice models | `~/.cache/huggingface` |
| App settings, accepted terms | the app's macOS preferences (`local.audiobookstudio`) |
| Finished audiobooks | next to the book, or in the folder you chose |

Delete these to remove the data. Notifications are shown by macOS on your Mac and are not sent anywhere. We have no access to any of these files.

## 4. When the app connects to the internet, and to whom

The app connects to the internet only to download or update software, and only in these cases. Your Mac contacts the service directly; the developer is not involved and receives nothing.

| When | Service (hosts) | What it receives |
|---|---|---|
| Daily check for a new version, and downloading an update (can be switched off in Settings → About) | **GitHub** (`github.com`, `objects.githubusercontent.com`, `release-assets.githubusercontent.com`) | Your IP address, the request, and the app's name and version in the standard user-agent. No personal information, no system profile. |
| Installing the app (the DMG), the engine installer script and the engine's source code | **GitHub** (`github.com`, `raw.githubusercontent.com`) | Your IP address and the request. |
| Downloading voice models (Kokoro, Qwen3-TTS, Voxtral, Fish Audio S2 Pro, Whisper) and some reference voices | **Hugging Face** (`huggingface.co` and its content-delivery hosts) | Your IP address and the request (which model). Telemetry is switched off by the app. |
| Downloading some reference voices | **Internet Archive** (`archive.org` and its download hosts) | Your IP address and the request. |
| Installing the tools the engine needs (`uv`, `ffmpeg`, `espeak-ng`) | **Homebrew** (`brew.sh` project; packages from `ghcr.io` and `github.com`) | Your IP address and the request. Homebrew analytics are switched off for the installation the app runs. |
| Installing the engine's Python libraries and Python itself | **Python Package Index** (`pypi.org`, `files.pythonhosted.org`); **GitHub** (`github.com`, for the `uv` Python builds and the spaCy language model) | Your IP address and the request. |

Conversion, voice preview, voice cloning, the speech check and every other feature run on your Mac and make no network connection.

These third parties act independently under their own terms and privacy policies, for example:
GitHub (https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement),
Hugging Face (https://huggingface.co/privacy),
Internet Archive (https://archive.org/about/terms.php),
Homebrew (https://docs.brew.sh/Analytics),
Python Package Index (https://policies.python.org/pypi.org/Privacy-Notice/).
We do not control them and are not responsible for what they collect or how they use it. If you do not want them to see your IP address, use a VPN or install the pieces by another route.

macOS itself may contact Apple, for example to check that downloaded software is notarized, or to send crash reports if you have allowed that in System Settings. That is part of macOS and governed by Apple's privacy policy, not by this app.

## 5. Voices and recordings

Reference clips you add are copied to your Mac and used only to narrate on your Mac. Some library voices are recordings of real people published under open licences; their credits are shown in the app. You are responsible for having the right to use any voice you clone (see the Terms of Use in the app).

## 6. Children

The app has no accounts and collects nothing, from anyone, including children.

## 7. Your rights

Because the developer holds no personal data about you, there is nothing to access, correct, export or delete on our side. Your rights regarding data held by the third parties in section 4 (for example under the GDPR or similar laws) are exercised with them.

## 8. Changes to this policy

If this policy changes, its version number changes and the app asks you to read and accept it again before you continue. Earlier versions remain available in the project's history on GitHub.

## 9. No warranty, limitation of liability

Audiobook Studio and this policy are provided "as is", without warranty of any kind, express or implied. To the fullest extent permitted by law, the developer is not liable for any loss or damage arising from the use of the app, from the practices of the third-party services in section 4, or from reliance on this policy. Nothing in this policy limits any right or liability that cannot be limited by law.

Use Audiobook Studio lawfully: convert only books you own or have the right to use, and clone a voice only with its owner's permission.
