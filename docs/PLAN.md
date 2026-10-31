# Gabble build plan

Agreed with Jonny on 31 Oct 2026. Target: Apple Silicon Mac on macOS 26 (Tahoe). Everything runs on-device.

## 1. Build pipeline and app shell (done)
- GitHub Actions builds and tests the app on a cloud Mac and publishes a downloadable `Gabble.zip`.
- One app with a full settings window (opened from the Dock) and a menu bar toggle for dictation.
- Permissions setup page: microphone, speech recognition, accessibility, call audio.
- Word List (lexicon) storage and learning logic, with a settings page.

## 2. Dictation (built, in testing)
- Global shortcut and menu bar toggle; live on-device recognition with Apple's SpeechAnalyzer.
- Text is typed into the focused app (Claude, Word, chat windows) through the Accessibility API, with a paste fallback.
- Cleanup to Wispr Flow standard using Apple's on-device Foundation Models: filler removal, mid-sentence corrections, punctuation, lists, tone matched to the app, Word List applied.
- Learns new terms when you correct what it typed (see LEXICON.md).
- Model picker: Apple on-device now; Hugging Face models (Whisper, Parakeet) later.

## 3. Call capture and speaker recognition
- Detects when Teams, Zoom, Meet, Webex, Slack or FaceTime starts using the mic and asks "Transcribe this call?".
- Records your mic and the call audio (ScreenCaptureKit, covered by the "Screen & System Audio Recording" permission).
- Speaker recognition from voiceprints plus context clues (calendar attendees, names said aloud, recurring meetings).
- Live "Who is talking?" prompt only for voices it doesn't know; answers are remembered for future calls.

## 4. Smart filing
- Each call saved as Markdown with YAML front matter (date, attendees, category, tags) in a master folder, ideally inside an Obsidian vault.
- Suggests a folder from attendees, recurrence (e.g. Mondays 12:00) and content; asks when unsure and learns from answers.
- Help setting up Obsidian for the Claude + Obsidian second brain.
