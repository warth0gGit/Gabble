# Warble

Warble is a Mac app for two jobs:

1. **Dictation.** Switch it on from the menu bar, talk, and your words appear wherever your cursor is (Claude, Word, Teams chat), cleaned up as you go.
2. **Call transcription.** When a Teams, Zoom or similar call starts, Warble asks "Transcribe this call?", recognises who is speaking, and files the transcript into a folder that works with Obsidian.

Everything runs on your Mac. Nothing you say is sent to the cloud.

## Installing the latest build

You don't need Xcode or any developer tools. GitHub builds Warble automatically every time the code changes.

1. Open the [latest build](https://github.com/warth0gGit/Gabble/releases/tag/latest-build) and download **Warble.zip**.
2. Double-click the zip, then drag **Warble** into your **Applications** folder.
3. Open Warble. macOS will warn that it can't check the developer, because Warble isn't signed with a paid Apple account yet. Click **Done**, then go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to Warble.
4. Warble opens on its **Permissions** page. Click each **Allow** button and switch Warble on in the window that appears.

After each update, macOS may ask you to approve the permissions again. That stops once Warble is signed with an Apple Developer account.

## Status

See [docs/PLAN.md](docs/PLAN.md) for the build plan and [docs/LEXICON.md](docs/LEXICON.md) for how Warble learns your jargon.

## For developers

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
xcodegen generate
open Warble.xcodeproj
```

Requires macOS 26 and Xcode 26.
