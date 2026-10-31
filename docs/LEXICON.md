# How Gabble learns your jargon

The Word List (lexicon) is the set of acronyms, product names, people and jargon Gabble should always get right. The goal is that you rarely have to type anything into it yourself.

## Where new words come from

1. **Your corrections (automatic, strongest signal).** After Gabble types a dictated sentence, it watches that text field for a few seconds. If you change "sass" to "SaaS", it learns both the correct spelling and what it misheard, and gets it right next time. This is the same approach Wispr Flow uses.
2. **Your calls (suggested).** Every transcript is scanned for acronyms (KPI, Q3, O365) and mixed-case product names (SharePoint, watsonx) that keep coming up. They appear under **Suggested** in the Word List, and one click adds each.
3. **Meeting invites.** Attendee names and meeting titles from your calendar are added so names are spelled correctly.
4. **Your documents (optional, one-off).** Point Gabble at a folder, such as your Obsidian vault or a few strategy decks exported to text. It harvests recurring terms as suggestions.
5. **Paste a list.** If your team already has an acronym glossary, paste it in, one term per line, as `KPI - key performance indicator`.

## How the words are used

- **While listening:** confirmed terms are passed to Apple's speech engine as contextual hints, so it is more likely to hear them correctly in the first place.
- **During cleanup:** the on-device cleanup model gets the Word List with each sentence, and known mishearings ("sounds like") are fixed directly.
- **In transcripts:** expansions (meanings) can be added as Obsidian tags or a glossary note, so your second brain knows what each acronym means.

## Status

Storage, import, harvesting and correction-learning logic are built and tested. Watching corrections in other apps arrives with dictation (step 2), and harvesting from calls arrives with step 3.
