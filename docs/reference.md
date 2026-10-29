# Lip Service reference

This page describes what Lip Service does, every setting, and how to build, test, and sign it. The [README](../README.md) covers downloading and installing the app.

## How it works

Everything runs on the Mac. Parakeet TDT v2, through [FluidAudio](https://github.com/FluidInference/FluidAudio) v0.17.7, turns the audio into text. A second, smaller model boosts the names in your vocabulary file, so a name the speech model spells its own way comes out the way you spell it. A fixed set of rules removes filler words and fixes capitals and punctuation. Audio stays in memory and is never written to disk or sent anywhere.

## Dictate

- To dictate, hold a dictation key, speak, and release it. The text is pasted at the cursor. The dictation keys are fn and Right Control until you change them on the Dictation page.
- To dictate without holding the key, tap it twice. Press it once more to stop and insert the text. Press Escape to stop without inserting.
- A tap shorter than 0.3 s does nothing. A shortcut such as fn+Delete is not a dictation. Another key pressed while you hold a dictation key cancels it.
- To paste your last dictation again, press Control+Command+V, or the shortcut you set, in any app. Before your first dictation the bar says so.

## The bar

While you speak, a dark bar at the edge of the screen shows a small waveform that follows your voice and the words heard so far. The words update about three times a second, and the bar grows with them. A long dictation shows its newest words, with the start fading out. The text that gets inserted is transcribed again from the whole recording when you let go, with your vocabulary, so it can differ slightly from the words in the bar.

In hands-free mode the bar also has a stop button, which inserts the text, and a cancel button, which throws the recording away. Clicking them does not take focus from the app you are typing in.

When you let go, the last words stay in the bar, dimmed, until the text is inserted. The bar also shows the model's progress while it downloads or prepares. The bar never takes focus.

Short messages appear just above the bar, or below it when the bar is at the top of the screen. Each has a title, a second line that says why, and an icon that is green for information, amber for a problem Lip Service works around, and red for a failure:

- **Copied. Press ⌘V to paste.** Lip Service could not paste, so the text is on the clipboard. The second line says why: Accessibility access is off, a password field has secure input on, focus moved to another app or field before the text was ready, or the text waited more than 10 s for the model.
- **_Name_ isn't connected.** _Name_ is the microphone you chose. It is unplugged, so dictations use the system default until it is back, and the second line names the one in use. It shows on the first dictation without it, and again only if it comes back and goes missing later.
- **Nothing to paste yet** appears for the paste shortcut before your first dictation.
- A failure, such as a model that could not load. A dictation waiting on a failed model shows **The speech model didn't load** with the reason and a **Retry** button.

Every dictation also goes into **Recent Dictations** in the menu, and clicking one copies it again. The list holds the last 20 dictations and lives in memory only, so it empties when the app quits. The history on the Home page keeps every dictation across launches.

The bar sits at the bottom center of the screen that has the mouse. To move it, drag it while you dictate, or drag the small idle bar. Dashed outlines mark the four places it can go: bottom center, top center, left middle, and right middle. Let go near one and the bar snaps there and stays there. On the left or right edge the bar is centered vertically and grows away from that edge.

When **Hide bar when idle** is off, a small dark pill stays at the bar's place between dictations. It is on by default, so the bar shows only while you dictate.

A short sound plays when the bar appears, another when the text is on its way, and a third when you cancel. A shortcut such as fn+Delete ends before the bar appears, so it makes no sound. **Interaction sounds** in Settings turns them off.

With **Smart spacing** on, the pasted text fits the text before the cursor:

- After a word, a digit, or punctuation, it starts with a space. After a space, a line break, an opening bracket, or an opening quote, it does not.
- After a letter, a digit, or a comma, the sentence continues, so the first word is lowercased. "I", words such as "I'm", all-capital words such as "OK", words with a capital inside such as "YouTube", vocabulary terms, and weekday and month names keep their capitals.
- When the app does not expose the text before the cursor, as in Ghostty and other terminals, the text is pasted unchanged.

To read that text in Electron and Chromium apps such as T3 Code, Lip Service asks each app to turn on its accessibility tree when the app comes to the front. Other apps ignore the request.

The first launch downloads the speech model, about 460 MB, and prepares it for the chip. Preparing takes about a minute. Later launches load the model in about a second. A dictation made while the model loads waits and is inserted when the model is ready. The boosting model, about 100 MB more, downloads the first time your vocabulary has a word.

## The Lip Service window

The window opens on first launch. To open it later, open the app again from Spotlight, Raycast, or the Finder, or choose **Open Lip Service…** in the menu. While the window is open, the app has a Dock icon and menus. When you close the window, the app goes back to the menu bar only. If **Show menu bar icon** is off, a launch other than at login also opens the window, so the app never starts invisibly.

The window is always dark and follows the Tesla center screen: one dark canvas, flat tiles, blue for a setting that is on, a gray fill for the chosen one of several, and messages in rounded bars with a colored icon. A list of pages runs down the left. A black strip along the bottom shows the microphone dictation would use now, with a green dot, or an amber dot when the chosen one is unplugged; the keys to hold; and **Copy last**, which copies your last dictation.

- **Home** starts with a message for anything setup still needs: microphone access, Accessibility access, and, when fn is a dictation key, Keyboard > **Press fn key to** set to **Do Nothing**. Each has a button to the right System Settings pane, and they update every 2 s. Below them are four numbers: words in the last 7 days, large, then total words, average words per minute (words over the audio minutes of the dictations whose audio length is known), and the streak of days with a dictation, which counts today or, until today has one, yesterday. Then come your dictations, newest first. Each shows the text, the app, and when, such as "Today at 4:12 PM". Click one to see all of its text. Hover over it to copy or delete it. The search field filters them by text and app.
- **Dictation** sets the dictation keys, the bar position, **Sounds**, **Smart spacing**, **Vocabulary boost**, **Hide bar when idle**, **Launch at login**, and **Show menu bar icon**, described in the Settings section below.
- **Microphone** lists System Default and every input. Click one to dictate with it. A chosen microphone that is unplugged stays in the list, marked not connected, under a message naming the one used instead. The input level below moves while you speak. It records only while this page is open, so the menu bar's microphone indicator shows then.
- **Dictionary** shows your vocabulary terms as tiles with their misheard spellings, or "No words yet" when there are none. **Add Word**, and the pencil and trash that appear when you hover over a tile, change the vocabulary file described below. Double-click a tile to edit it.
- **History** has **Keep history**, **Delete All History**, and, when Willow's folder exists, **Import from Willow**.

The history lives in `~/Library/Application Support/Dictation/history.jsonl`, one JSON line per dictation, oldest first. Each line holds the date, the text, the audio length, the word count, and the app. Audio is never written. **Keep history** off stops adding new dictations and keeps the old ones. **Delete All History** removes the file after you confirm.

## Settings

The Dictation page of the window holds most settings, and the Microphone and History pages the rest:

- **Dictation keys**: up to four, each a blue tile. A dictation key can be any key with modifiers, such as ⌥Space or ⌃⌘D; a function key, such as F5; or a modifier key on its own, such as fn, Right Option, or Left Control, held with other modifiers or not. Click a tile, then press the keys. A key with its modifiers records at once, and a modifier key records when you let go of it. Escape cancels, and so does clicking the tile again. **Add Key** adds one, and the × on a tile removes it. At least one stays. A letter, digit, Space, Return, Tab, or Delete needs Control, Option, or Command with it, so it still types, and Caps Lock can't be used. The keys of a shortcut that is not a modifier key on its own never reach the app you are typing in.
- **Paste last dictation**: the shortcut that pastes your last dictation again, ⌃⌘V at first. Record it the same way. It needs a key with modifiers or a function key, not a modifier key on its own. The × turns it off.
- **Bar position**: the edge of the screen the bar sits on. Dragging the bar also sets it.
- **Sounds** plays a sound when dictation starts, ends, and is cancelled. **Smart spacing** is described in the section about the bar. **Vocabulary boost** is described in the Vocabulary file section. **Hide bar when idle** shows the bar only while you talk.
- **Launch at login** adds Lip Service to the system's login items. If macOS asks for approval, the setting says so. **Show menu bar icon** shows or hides the menu bar icon.
- **Microphone**, on its own page, described in the window section.
- **Keep history**, **Delete All History**, and **Import from Willow**, on the History page.

The menu keeps the most used ones: **Dictation Keys**, which lists them and opens the window to change them, **Microphone**, **Vocabulary Boosting**, and **Open Vocabulary File**. Vocabulary boosting off also turns off misheard spellings and the capitals for your terms, but weekday and month names keep their capitals.

In the menu, **Microphone** picks the input to dictate with: **System Default**, which follows the Mac's sound settings, or a device. A chosen device that is unplugged stays checked in the menu, marked not connected, and dictations use the system default until it is back. The bar says so once, not on every dictation.

The app stores every setting as one JSON value under `settings` in the `com.hunterbohm.dictation` defaults domain.

Lip Service needs two permissions. **Microphone** is requested at first launch. **Accessibility** lets the app see the dictation keys and paste. Until it is granted, the app asks for it at each launch and the menu links to the setting.

For fn to work as a dictation key, set System Settings > Keyboard > **Press fn key to** to **Do Nothing**. On a keyboard with a globe key, the setting is called **Press 🌐 key to**. The menu shows a reminder while that setting has any other value.

## Vocabulary file

The vocabulary lives in `~/Library/Application Support/Dictation/vocabulary.txt`. The app creates it on first launch with no words, only comments and two examples that are commented out. It never replaces a file that exists. The Dictionary page edits the file, and **Open Vocabulary File** in the menu or on the Dictionary page opens it in your editor, recreating it if it was deleted. A change saved in an editor applies at the next key press, menu open, or return to the window. A change made on the Dictionary page applies at once.

	# One term per line, spelled the way it should appear.
	@min-similarity 0.7
	Figma
	Siobhan: shivon, chevonne

- Each term is one line, spelled the way the text should show it. Terms go to the boosting model, and the cleanup rules also fix their capitals.
- Misheard spellings follow the term after a colon, separated by commas. After boosting, each one is replaced with the term as a whole word, ignoring case. Add one when a name still comes out wrong with boosting on.
- `@min-similarity` sets how close a heard word must sound to a term before boosting swaps the term in. The range is 0.5 to 1.0, and the default is 0.7. Lower values replace more words, including words that only sound a little alike.
- Lines that start with `#` are comments. Blank lines are ignored.

A vocabulary with no terms turns boosting off and does not load the boosting model. Weekday and month names still get their capitals.

A line that cannot be read, such as a term listed twice, a missing term before a colon, an empty misheard spelling, or an unknown `@` setting, is skipped, and the rest of the file still applies. The menu and the Dictionary page show the first problem with its line number.

When the Dictionary page saves, it rewrites the file: the comment lines at the top first, then `@min-similarity`, then one line per term. Lines that cannot be read are kept at the end, so you can still fix them by hand. Comments further down the file are not kept.

## Import from Willow

If Willow Voice's folder exists, Home offers **Import from Willow** once, and the History page offers it every time. Quit Willow before you dictate with Lip Service, so fn is not answered by two apps. The import reads two things from `~/Library/Application Support/com.seewillow.WillowMac`:

- Every transcript in `Transcripts/*.json` that was not cancelled and has text. Each one keeps Willow's date, audio length, and app. Importing again adds nothing twice, because each entry keeps Willow's id.
- Willow's settings: the dictation hotkeys, interaction sounds, hide bar when idle, smart text insertion, the chosen microphone, the bar position, and the menu bar icon. A setting that Willow's files do not mention stays as it is.

The import never reads `Preferences/cached_account_session.json`, which holds Willow's account tokens, and never copies audio.

To see what an import would do without changing anything, run the app binary with the Willow folder:

	"/Applications/Lip Service.app/Contents/MacOS/Dictation" --import-willow-dry-run ~/Library/Application\ Support/com.seewillow.WillowMac

It prints the number of dictations and words it would add, the skipped transcripts, the top apps, and the settings it would apply.

## Build the app

Build on a Mac with Apple silicon and macOS 26. The Command Line Tools with Swift 6.2 or later are enough. Xcode is not needed, and an SSH session works.

1. Vendor FluidAudio with `scripts/fetch-deps.sh`. The script clones the pinned v0.17.7 commit into `Vendor/FluidAudio` and applies two patches. The first removes its `NemoTextProcessing` binary target, which the app never uses. SwiftPM would download that target with URLSession, and URLSession crashes in an SSH session. The second makes FluidAudio's vocabulary rescoring build a character set once instead of once per word, which cut rescoring a 75 s dictation from 0.15 s to 0.01 s without changing its output. A vendored copy without the second patch is re-vendored on the next run.
2. If you will run the self-test, the bench, or `scripts/e2e.sh` over SSH, cache the models with `scripts/fetch-models.sh`, which downloads them with curl. The app downloads the same models itself on first launch, so a Mac that only runs the app does not need this step.
3. Build and sign the app with `scripts/build-app.sh`. The script runs a release build, assembles `dist/Lip Service.app` beside the previous bundle, copies the license texts into `Contents/Resources/Licenses`, signs the bundle, checks the signature with `codesign --verify --strict`, and renames it into place.

The first release build of FluidAudio takes several minutes. Later builds take seconds.

The license texts are Lip Service's own, FluidAudio's, and the three FluidAudio third-party licenses that cover code in the FluidAudio product: fastcluster, VBx, and the Japanese text frontend. FluidAudio's other third-party licenses cover the binary target that `fetch-deps.sh` removes and text-to-speech model files the app never downloads. The build stops if FluidAudio adds a third-party license that `build-app.sh` does not list yet.

To make a release zip, name it after the version in `Info.plist`:

	ditto -c -k --sequesterRsrc --keepParent "dist/Lip Service.app" dist/Lip-Service-1.0.1.zip

## Test

- `scripts/test.sh` runs the DictationCore unit tests with swift-testing. It covers the hotkey state machine, shortcuts and their recording, the cleanup rules, aliases, punctuation repair after boosting, the clipboard restore, the paste-or-copy decision, the vocabulary parser and writer, the bar state and its messages, the history numbers and captions, smart spacing, and reading Willow's transcripts and settings from small sample files. It fails first if `DictationCore/Sources` imports AppKit, AVFoundation, CoreGraphics, or FluidAudio, so the tests never build FluidAudio.
- `scripts/e2e.sh` tests the built app binary. It runs `--self-test`, then `--bench` over `bench/clips/*.wav`, and scores the results against the bakeoff that chose the engine. It fails if a dictation errors, if vocabulary hits fall below 18 of 20, or if the word error rate on the synthetic clips rises above 3.2%. The bench runs live previews while the simulated key is held, as the app does. The environment variables `ROUNDS`, `HOLD_CAP`, `GAP`, `WARM`, and `PREVIEW` change the bench settings. `bench/make_clips.py` makes the clips. It reads `bench/manifest.jsonl` aloud with the macOS voice Samantha, and it also cuts real clips from a recording listed in `bench/real.json` when that file exists. `bench/real.json` and the recording stay out of the repo.

The app binary has six headless modes. Both scripts use the first two:

	"dist/Lip Service.app/Contents/MacOS/Dictation" --self-test
	"dist/Lip Service.app/Contents/MacOS/Dictation" --bench --rounds 3 --hold-cap 15 bench/clips/*.wav
	"dist/Lip Service.app/Contents/MacOS/Dictation" --list-inputs
	"dist/Lip Service.app/Contents/MacOS/Dictation" --render-bar /tmp/bar
	"dist/Lip Service.app/Contents/MacOS/Dictation" --render-window /tmp/window
	"dist/Lip Service.app/Contents/MacOS/Dictation" --import-willow-dry-run FOLDER

`--render-window` draws every page of the window with sample history, settings, vocabulary, and microphones, and the Dictionary page once more with the vocabulary a new user starts with, to PNG files in the folder. It works over SSH and leaves your settings, history, and vocabulary file alone. `--import-willow-dry-run` is described in the Import from Willow section.

`--self-test` loads the models the way the app does and transcribes `selftest.wav` from the bundle. The clip says "Profit Pilot" and "Bee hive" the way the engine mishears them, so the test exits 1 unless ProfitPilot, Beehiiv, and Friday reach the final text. `--bench` simulates a key press, plays the clip in real time to the live previews, releases after the clip's length or `--hold-cap` seconds, whichever is shorter, and prints one JSON line per clip and round. With a hold cap shorter than the clip, the part before it counts as already captured at the press. `--preview off` skips the previews. Both modes use the 13 terms the bakeoff measured, `Vocabulary.bakeoff`, not your vocabulary file. `--bench --vocabulary PATH` reads the terms from a file instead. Both modes stop with `models missing: run scripts/fetch-models.sh` when the models are not cached. `--self-test --allow-download` downloads them instead. Use it only in a GUI session.

`--list-inputs` prints each audio input's name and UID, then the system default. `--render-bar DIR` draws every state of the bar, in every position, with the app's own views on a stand-in screen, and writes a PNG of each and a close-up into DIR. It needs a user logged in to the Mac's desktop. An SSH session to that Mac works.

Two scripts regenerate test inputs. `scripts/make-cleanup-fixtures.sh` runs `bench/cleanup-inputs.txt` through `bench/cleanup.py`, the Python cleanup that the bakeoff measured, and writes the expected outputs as a Swift test fixture. `scripts/make-selftest-clip.sh` rebuilds `Resources/selftest.wav` with `say`.

Two more regenerate the app's resources. `scripts/make-icon.sh` builds `Resources/AppIcon.icns` from `Resources/AppIcon-1024.png` with `sips` and `iconutil`. `scripts/make-sounds.py Resources` writes the three cues, `start.wav`, `stop.wav`, and `cancel.wav`.

## Signing

The app is signed with a self-signed code-signing certificate. `scripts/sign.sh` generates it on the first build and keeps it on the Mac that builds, in `~/.config/dictation/signing`, as `identity.p12` and `identity.pass`, both mode 600.

macOS ties the Microphone and Accessibility permissions to the app's designated requirement, which is the bundle identifier plus that certificate. Every rebuild signed with the same certificate keeps the permissions. An ad hoc signature would lose them on every build, because its requirement is a hash of the binary. Releases are signed with the author's certificate, so a downloaded update keeps them too. A build signed with your own certificate is a different app to macOS, so switching between it and a release needs both permissions again.

If the signing folder is lost, the next build generates a new certificate, and every Mac that runs the new build grants Microphone and Accessibility again, once. The README's install prompt also checks the certificate's SHA-256, so a new certificate needs its new hash there:

	codesign -d --extract-certificates=cert "dist/Lip Service.app" && shasum -a 256 cert0

The certificate is not from Apple and the app is not notarized, so macOS blocks a downloaded copy until you allow it. The README's install steps cover that. A copy that never had the quarantine flag, such as one you built or copied with `rsync`, opens without the block.

To see the requirement of a build:

	codesign -dr - "dist/Lip Service.app"

## Install your own build on another Mac

Build on one Mac, then copy the bundle over SSH. A copy made with `rsync` carries no quarantine flag, so Gatekeeper does not block the self-signed app. `other-mac` stands for the SSH host of the Mac that runs the app:

	rsync -a --delete "dist/Lip Service.app" other-mac:Applications/

On that Mac, open `~/Applications/Lip Service.app`, then grant the permissions and set the fn key as the README's install steps describe.

To update, rebuild and run the same `rsync`. The certificate is unchanged, so the permissions stay.
