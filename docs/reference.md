# Lip Service reference

This page describes what Lip Service does, every setting, and how to build, test, and sign it. The [README](../README.md) covers downloading and installing the app.

## How it works

Everything runs on the Mac. Parakeet TDT v2, through [FluidAudio](https://github.com/FluidInference/FluidAudio) v0.18.3, turns the audio into text. A second, smaller model boosts the names in your vocabulary file, so a name the speech model spells its own way comes out the way you spell it. A fixed set of rules removes filler words and fixes capitals and punctuation. With **Smart formatting** on, a third model lays the text out, as described under Smart formatting. Audio stays in memory and is never written to disk or sent anywhere.

## Dictate

- To dictate, hold a dictation key, speak, and release it. The text is pasted at the cursor. The dictation keys are fn and Right Control until you change them on the Dictation page.
- To dictate without holding the key, tap it twice. Press it once more to stop and insert the text. Press Escape to stop without inserting.
- A tap shorter than 0.3 s does nothing. A shortcut such as fn+Delete is not a dictation. Another key pressed while you hold a dictation key cancels it.
- To paste your last dictation again, press Control+Command+V, or the shortcut you set, in any app. Before your first dictation the bar says so.

## The bar

While you speak, a dark bar at the edge of the screen shows three soft blue waves that swell as you speak and settle when you pause. The bar is the same size the whole time, and it shows no words. The waves scale themselves to your voice and the room from the last few seconds, so a quiet voice moves them as much as a loud one, and a quiet room keeps them low. They span the 24 dB below your loudest recent sound, never reaching down to within 5 dB of the room, so each syllable changes their height and a pause drops it. The waves follow the voice live: the microphone is measured every 10 ms, and a wave moves within a few hundredths of a second of the sound. Each wave follows a part of the voice more than the rest, the lowest for the low body of a voice, the middle for its vowels, and the highest for the hiss of "s" and "f", so different sounds move different waves. Each sound starts in the middle of the bar and ripples out to both ends over about a seventh of a second, so a word shows as a swell that spreads and a pause calms the middle first. The waves also run faster and glow brighter as you speak up. The text that gets inserted is transcribed again from the whole recording when you let go, with your vocabulary.

Around the bar, a soft rim and a blurred halo in shades of blue turn slowly and glow brighter with your voice while you speak, so the bar stands out on a dark window. A beam of light, deep blue at its tail and near white at its head, runs around the rim at a steady speed. The glow fades in when the bar appears and fades out when you let go. With Reduce Motion on, the rim and halo stay still, with no beam.

In hands-free mode the bar also has a stop button, which inserts the text, and a cancel button, which throws the recording away. Clicking them does not take focus from the app you are typing in.

When you let go, the waves settle to a dim, almost flat line that slowly brightens and dims until the text is inserted. With Reduce Motion on, the waves are still. With Reduce Motion on in System Settings > Accessibility > Display, the bar fades instead of moving. The bar also shows the model's progress while it downloads or prepares. The bar never takes focus.

Short messages appear just above the bar, or below it when the bar is at the top of the screen. Each has a title, a second line that says why, and an icon that is green for information, amber for a problem Lip Service works around, and red for a failure:

- **Copied. Press ⌘V to paste.** Lip Service could not paste, so the text is on the clipboard. The second line says why: Accessibility access is off, a password field has secure input on, focus moved to another app or field before the text was ready, or the text waited more than 10 s for the model.
- **_Name_ isn't connected.** _Name_ is the microphone you chose. It is unplugged, so dictations use the system default until it is back, and the second line names the one in use. It shows on the first dictation without it, and again only if it comes back and goes missing later.
- **Nothing to paste yet** appears for the paste shortcut before your first dictation.
- **Learned _word_** appears when Lip Service added a word from your fix to the dictionary. **Undo** takes it out again.
- A failure, such as a model that could not load. A dictation waiting on a failed model shows **The speech model didn't load** with the reason and a **Retry** button.

Every dictation also goes into **Recent Dictations** in the menu, and clicking one copies it again. The list holds the last 20 dictations and lives in memory only, so it empties when the app quits. The history on the Home page keeps every dictation across launches.

The bar sits at the bottom center of the screen that has the mouse. To move it, drag it while you dictate, or drag the small idle bar. Dashed outlines mark the four places it can go: bottom center, top center, left middle, and right middle. Let go near one and the bar snaps there and stays there. On the left or right edge the bar is centered vertically. When another app keeps a bar along that edge, such as the top bar of a tiling window manager like OmniWM or AeroSpace with SketchyBar, Lip Service sits just inside it instead of under it.

When **Hide bar when idle** is off, a small dark pill stays at the bar's place between dictations. It is on by default, so the bar shows only while you dictate.

A short sound plays when the bar appears, another when the text is on its way, and a third when you cancel. A shortcut such as fn+Delete ends before the bar appears, so it makes no sound. **Interaction sounds** in Settings turns them off. They play as system sounds, at the alert volume, through the output that Sound settings picks for sound effects. macOS treats an app that plays sound while it records as a call, and moves your AirPods from your iPhone to the Mac. A system sound comes from macOS itself, so it doesn't count.

With **Smart spacing** on, the pasted text fits the text before the cursor:

- After a word, a digit, or punctuation, it starts with a space. After a space, a line break, an opening bracket, or an opening quote, it does not.
- After a letter, a digit, or a comma, the sentence continues, so the first word is lowercased. "I", words such as "I'm", all-capital words such as "OK", words with a capital inside such as "YouTube", vocabulary terms, and weekday and month names keep their capitals.
- When the app does not expose the text before the cursor, as in Ghostty and other terminals, the text is pasted unchanged.

To read that text in Electron and Chromium apps such as T3 Code, Lip Service asks each app to turn on its accessibility tree when the app comes to the front. Other apps ignore the request.

The first launch downloads the speech model, about 460 MB, and prepares it for the chip. Preparing takes about a minute. Later launches load the model in about a second. A dictation made while the model loads waits and is inserted when the model is ready. The boosting model, about 100 MB more, downloads the first time your vocabulary has a word.

## The Lip Service window

On first launch the setup window opens instead, described under First run. To open the window later, open the app again from Spotlight, Raycast, or the Finder, or choose **Open Lip Service…** in the menu. While the window is open, the app has a Dock icon and menus. When you close the window, the app goes back to the menu bar only. If **Show menu bar icon** is off, a launch other than at login also opens the window, so the app never starts invisibly.

The window is always dark and follows the Tesla center screen: one dark canvas, flat tiles, blue for a setting that is on, a gray fill for the chosen one of several, and messages in rounded bars with a colored icon. A list of pages runs down the left. A black strip along the bottom shows the microphone dictation would use now, with a green dot, or an amber dot when the chosen one is unplugged; the keys to hold; and **Copy last**, which copies your last dictation.

- **Home** starts with a message for anything setup still needs: microphone access, Accessibility access, and, when fn is a dictation key, Keyboard > **Press fn key to** set to **Do Nothing**. Each has a button to the right System Settings pane, and they update every 2 s. **Set up again…** opens the setup window. Below them are four numbers: words in the last 7 days, large, then total words, average words per minute (words over the audio minutes of the dictations whose audio length is known), and the streak of days with a dictation, which counts today or, until today has one, yesterday. Then come your dictations, newest first. Each shows the text, the app, and when, such as "Today at 4:12 PM". Click one to see all of its text. Hover over it to copy or delete it. The search field filters them by text and app.
- **Dictation** sets the dictation keys, the bar position, **Sounds**, **Smart formatting**, **Smart spacing**, **Vocabulary boost**, **Hide bar when idle**, **Mute other audio**, **Launch at login**, **Show menu bar icon**, **Send an anonymous daily usage count**, and **Check for updates**, described in the Settings section below.
- **Ghostwrite** shows the agent that writes for you and whether it is ready (Ready, Checking, Can't reach with the reason and **Try again**, or Not installed), with **Change**. Below it are the Ghostwrite and Hand off keys, each a tile you click to record a new key; **Show the draft before typing it**, **Learn my voice from my dictations**, and **Send the window's text with hand-offs**; and **Your voice**. **Change** opens **Who writes for you**: the agents you set up, then **Another agent** for the rest. Pick one to make it the default. For the chosen one, **Test** checks that it answers, **Hand off goes to** picks the destination and shows its fields, and **Advanced** holds its name, its command, the Mac it runs on, the names you call it, and **Remove**. With no agent, the page shows **Set up Ghostwrite**, which opens the setup window at its Ghostwrite step.
- **Profiles** sets how dictations read in each group of apps, described in the Profiles section below.
- **Microphone** lists Automatic, System Default, and every input. Click one to dictate with it. Each choice says which microphone it uses now, and a Bluetooth one says it is slow to start. A chosen microphone that is unplugged stays in the list, marked not connected, under a message naming the one used instead. While **Automatic** is chosen, **Automatic order** appears under the choices: the microphones Automatic picks from, numbered, first choice on top, with **In use** on the one it records from now. Drag a row by its handle, or use its arrows, to change the order. **Reset** shows once the order is yours and puts it back; moving the rows into the order Automatic starts with does the same. A microphone you moved stays in the list marked not connected when unplugged, with an × to forget it, and takes its place again when it is back. A microphone you plug in later goes to the bottom until you move it. Virtual devices and iPhones are never listed. The input level below moves while you speak. It records only while this page is open, so the menu bar's microphone indicator shows then.
- **Dictionary** shows your vocabulary terms as tiles with their misheard spellings, or "No words yet" when there are none. **Add Word**, and the pencil and trash that appear when you hover over a tile, change the vocabulary file described below. Double-click a tile to edit it. Below them are **Names from the screen**, **Learn from your fixes**, and your snippets, each described in its own section below.
- **Stats** is counted from your history. **Week**, **Month**, **Year**, and **All** pick the period. The top numbers are the words, the time saved, your speaking speed, the dictations, and your streak. Time saved is how long typing the same words at 40 words a minute would take, minus the time you spent talking; a dictation whose audio length is unknown counts at your measured speed. Below them, short insights say when, where, and how you dictate, each shown only when enough history backs it. Charts show a calendar of the days you talked, your words by week, by weekday and hour, and by app, your dictation lengths, and your speed over time; hover over one for its numbers. **Share** makes a 1600 by 900 image of the period's totals and a calendar of the last 13 weeks, which you can copy or save. It holds no dictated text and no app names. Before the first dictation, or with **Keep history** off and no history, the page says what to do.
- **History** has **Keep history**, **Delete All History**, and, when Willow's folder exists, **Import from Willow**.

The history lives in `~/Library/Application Support/Dictation/history.jsonl`, one JSON line per dictation, oldest first. Each line holds the date, the text, the audio length, the word count, and the app. Audio is never written. **Keep history** off stops adding new dictations and keeps the old ones. **Delete All History** removes the file after you confirm. The history and the vocabulary file are readable by your account only: the app sets its umask to 077 at launch, so it creates them with mode 600, and it makes the `Dictation` folder mode 700 at every launch, which also covers files that 1.0.1 and earlier left at 644.

## Settings

The Dictation page of the window holds most settings, and the Microphone and History pages the rest:

- **Dictation keys**: up to four, each a blue tile. A dictation key can be any key with modifiers, such as ⌥Space or ⌃⌘D; a function key, such as F5; or a modifier key on its own, such as fn, Right Option, or Left Control, held with other modifiers or not. Click a tile, then press the keys. A key with its modifiers records at once, and a modifier key records when you let go of it. Escape cancels, and so does clicking the tile again. **Add Key** adds one, and the × on a tile removes it. At least one stays. A letter, digit, Space, Return, Tab, or Delete needs Control, Option, or Command with it, so it still types, and Caps Lock can't be used. The keys of a shortcut that is not a modifier key on its own never reach the app you are typing in.
- **Paste last dictation**: the shortcut that pastes your last dictation again, ⌃⌘V at first. Record it the same way. It needs a key with modifiers or a function key, not a modifier key on its own. The × turns it off.
- **Bar position**: the edge of the screen the bar sits on. Dragging the bar also sets it.
- **Sounds** plays a sound when dictation starts, ends, and is cancelled. **Smart formatting** is described in its own section below. **Smart spacing** is described in the section about the bar. **Vocabulary boost** is described in the Vocabulary file section. **Hide bar when idle** shows the bar only while you talk.
- **Mute other audio**, off at first, mutes the Mac's sound output while you talk, so music or a video doesn't play over you. It mutes once the start sound has played and turns the sound back on before the stop sound, when you finish, cancel, or a dictation fails. If the output was muted already, it is left muted. It sets the mute switch of the default output device through CoreAudio, the same switch as the mute key, so it works on the built-in speakers, headphones, and AirPods and most USB and Bluetooth audio. Most HDMI and DisplayPort displays have no mute that macOS can set, and there it does nothing. While the sound is muted, Lip Service lists the muted output in a file named `muted-output.txt` in its support folder, one line per output, until that output's sound is back. Quitting the app or ending it with SIGTERM turns the sound back on first, waiting at most a second for macOS. An output that could not be turned back on, because it was unplugged or the app crashed, stays listed and is turned back on at the next launch, when the Mac wakes, or when an audio device is connected or removed. The stop sound plays only after the sound is back.
- **Launch at login** adds Lip Service to the system's login items. If macOS asks for approval, the setting says so. **Show menu bar icon** shows or hides the menu bar icon. **Send an anonymous daily usage count** is on by default. Once a day, when you first finish a dictation, a Ghostwrite or a Hand off, it sends a hashed random install ID, the app version, the macOS version, the UTC date, and which of the three you used first. Turn it off and nothing is sent. The Privacy section of the README lists exactly what it holds. **Check for updates** is on by default. Once a day it asks GitHub for the newest release, with no ID and no cookies, and when that is newer than the running app, the menu bar menu and the Home page say so, with a link to the release. It installs nothing. Turn it off and nothing is sent.
- **Microphone**, on its own page, described in the window section.
- **Keep history**, **Delete All History**, and **Import from Willow**, on the History page.

The menu keeps the most used ones: **Dictation Keys**, which lists them and opens the window to change them, **Microphone**, **Vocabulary Boosting**, and **Open Vocabulary File**. Vocabulary boosting off also turns off misheard spellings and the capitals for your terms, but weekday and month names keep their capitals.

In the menu, **Microphone** picks the input to dictate with: **Automatic**, **System Default**, which follows the Mac's sound settings, or a device. Automatic, the setting new installs start with, uses a wired microphone (USB, Thunderbolt, or a display's) when one is connected, then the Mac's own unless the lid is closed, then a Bluetooth headset. It never picks a virtual device or an iPhone. Among microphones of one kind it takes the system default first. The order can be changed on the Microphone page: microphones you place go first, in your order, and any other connected microphone follows in the order above. Placing nothing, which is how everyone starts, keeps the order above. The lid rule holds for a placed microphone too, so the Mac's own is skipped with the lid closed wherever it sits. Bluetooth comes last because a headset's microphone takes from a quarter of a second to two seconds to start, and while it records, the headset plays in call quality. macOS often makes AirPods the system default when they connect, and Automatic keeps recording from the wired or built-in microphone then.

A chosen device that is unplugged stays checked in the menu, marked not connected, and dictations use the system default until it is back. The bar says so once, not on every dictation. A dictation keeps the microphone it started with until you release the key, even if a better one connects or macOS changes the system default, and moves only when that microphone is unplugged.

Between dictations, Lip Service keeps the next one's microphone set up but switched off, so a key press only switches it on: about 0.04 s on a MacBook's microphone and 0.06 s on a USB one, measured with `--mic-start`. The menu bar's microphone indicator stays off until you press. A Bluetooth microphone is set up at the press instead, because setting one up holds the headset in call quality. A chosen device whose sample rate differs from the system default's works too. Lip Service waits up to 0.15 s for macOS to switch the device while it sets it up, so the engine starts once.

The app stores every setting as one JSON value under `settings` in the `com.hunterbohm.dictation` defaults domain. Automatic's order is `automaticOrder`, whose `devices` list holds each placed microphone's `uid` and `name`, first choice first. A value stored before it existed, or an empty list, means the kind order. An entry that does not read is dropped.

Lip Service needs two permissions. **Microphone** is requested at first launch. The app runs with the hardened runtime, so the microphone also needs the audio-input entitlement, which the signed app holds. **Accessibility** lets the app see the dictation keys and paste. Until it is granted, the app asks for it at each launch and the menu links to the setting.

For fn to work as a dictation key, set System Settings > Keyboard > **Press fn key to** to **Do Nothing**. On a keyboard with a globe key, the setting is called **Press 🌐 key to**. The menu shows a reminder while that setting has any other value.

## Profiles

The app in front when you let go of the dictation key picks a profile group. The Profiles page shows one group at a time: pick it in the row of tabs, then click one of three style cards, each with a sample message. A choice saves at once. Below the cards are **Press Return after the text goes in** and the group's apps. Each group has a style and a **Press Return after the text goes in** switch. The rules are fixed text rules that run on your Mac after cleanup, never a rewrite, so they add no time.

- **Formal** keeps the cleaned text as it is.
- **Casual** leaves off the period at the end of the dictation. A question mark, an exclamation mark, "...", or the period of a final abbreviation such as "U.S.", "e.g.", "i.e.", or "etc." stays.
- **Very casual** does the same and writes every letter in lowercase, except words spelled exactly as in your dictionary and "I", as in "I'm". "i.e." stays as it is.
- **Press Return after the text goes in** presses Return once the pasted text shows in the field, which sends the message in most chat apps. Just before Return, Lip Service checks the focus again and presses it only when the same field still has it, and only when the paste showed up or the field takes typed text: a text field, a text area, a combo box, or editable text in a web page. In an app that shows no focused field, such as some terminals and Electron apps, Return goes only if that app stayed in front and no other app came forward since you let go, 0.2 s after the paste. Return never comes later than 0.6 s after the paste. Past that, or when a check fails, it is skipped. It is off in every group at first. When Lip Service only copies the text, it does not press Return.

The groups and the apps they start with:

| Group | Style | Apps |
| --- | --- | --- |
| Messages | Casual | Messages, WhatsApp, Telegram, Signal, Discord |
| Work chat | Casual | Slack, Microsoft Teams |
| Email | Formal | Mail, Outlook, Spark, Superhuman, Mimestream |
| AI and code | Formal | T3 Code, ChatGPT, Claude, Codex, Cursor, Visual Studio Code, Zed, Xcode, Ghostty, Terminal, iTerm2, Warp |
| Everything else | Formal | Every app not in another group |

The page lists only the group's apps that are installed or that you added. **Edit** opens the full list: **Add App** adds one of the apps that are open, or an app you choose in the Finder, and the × on an app removes it, which puts it in Everything else. An app sits in one group only, so adding it to a second group moves it. A group can list a bundle ID that ends in `*`, which matches every ID that starts with the rest; T3 Code is listed as `com.t3tools.t3code*`, which covers its nightly and beta builds. History keeps the text as it was inserted.

## Names from the screen

With **Names from the screen** on, which it is at first, Lip Service reads the window you are in when you press the dictation key, so a name on the screen comes out spelled the way it is shown. It reads the window's title, the text around the cursor in the focused field, and the text and text fields shown in the window, through Accessibility. The read runs off the main thread, stops after 50 ms, 600 elements, or 40 levels deep in the window, and never reads a password field. It skips 1Password, Bitwarden, Dashlane, LastPass, Proton Pass, KeePassXC, NordPass, Enpass, Keeper, Strongbox, Keychain Access, Passwords, and System Settings, and it skips every app while a password field has secure input on. That list applies to every field Lip Service reads, for smart spacing, Press Return, and learning from your fixes too. It reads a field's length before its text and skips a field longer than 200,000 characters.

From that text it takes up to 30 names, nearest the cursor first: capitalized words, @handles, and words with a capital inside, such as ProfitPilot. Each name is one word, so a full name such as "Sarah Chen" gives Sarah and Chen; boosting the two words together turned a spoken "Sarah, the" into "Sarah Chen" in testing. It leaves out common English words, words with digits, words already in your dictionary, and a capitalized word that only starts a sentence, unless a capitalized word next to it, such as a surname, shows it is a name. The names boost that one dictation on top of your vocabulary and are then forgotten. Nothing is stored, and nothing leaves your Mac.

Names from the screen use the boosting model, so they work when **Vocabulary boost** is on and your dictionary has at least one word. The rescorer for them is built on its own while you hold the key. If it is not ready when you let go, that dictation uses your vocabulary alone, and names that arrive after you let go are dropped, so they never add to the wait after you release. On the mini, with 0.3 s holds, the time from release to text was the same with and without 30 names on screen.

## Smart formatting

With **Smart formatting** on, which it is at first, Lip Service adds paragraph breaks, numbered and bulleted lists, quotation marks, and line breaks in emails where they fit. You don't need to say "new paragraph" or "quote". It works from what you said, how long you paused between words, and the kind of app the text goes into: Messages, Work chat, Email, AI and code, or Everything else, as set on the **Profiles** page.

A model reads each finished dictation once and scores every word: a break before it, a list item starting at it, a quote opening before it or closing after it, a spoken counting word such as "first" or "number two" to drop, and its punctuation. Fixed rules then turn the scores into text. Each change needs enough confidence, quotes open and close inside one paragraph, and a list has at least two items. Breaks other than list items need a dictation of 60 words or more. The rules only add breaks, list markers and quotation marks, change punctuation and capitals, and drop counting words, so every other word goes in as you said it, in order.

The model is RoBERTa-base, fine-tuned for this, and runs on the Mac's Neural Engine through Core ML. It takes about 5 ms per dictation on an M4 Pro. It was trained on made-up dictations written by Claude models, with spoken counting words and commands, and their formatted versions. No real dictation is in its training data.

The formatting model downloads after the speech model, the first time Smart formatting is on, from the `v1.0.10` release of this repository, about 110 MB, and takes about 240 MB on disk once prepared. The app checks the archive's size and SHA-256 hash against the values built into it, unpacks it, and checks every file against its table, before Core ML reads anything. A download that fails is tried again an hour later, at the next dictation. Until the model is ready, and with Smart formatting off, dictation goes in as before.

Snippets match before formatting, so a snippet's cue still works. The group's style from the Profiles page applies after it, so **Casual** still drops the final period and **Very casual** still lowercases. History keeps the text as it was inserted.

A model you trained yourself, with the same files, goes in `Formatter-local` in the support folder. Lip Service then uses it instead of the published one, as it is, without the checks.

## Learn from your fixes

With **Learn from your fixes** on, which it is at first, Lip Service notices when you correct a word it typed. After it pastes into a field that shows its text to Accessibility, it remembers the field's text and where the dictation sits, then reads the field four times a second while you edit. It stops when the field empties, as when you send a chat message, when the field goes away, when you start your next dictation, or a minute after the paste, and looks at the last text that held still for a second, so a word you are halfway through typing when you press Return teaches nothing. If the only change is one word of the dictation replaced by another, with a word of the dictation still next to it, it adds your word to the dictionary, and the bar shows **Learned _word_** with an **Undo** button. That notice stays up through the start of the next dictation. A field whose whole text was replaced, such as a sent message followed by a new one, teaches nothing. The dictionary change takes effect once no dictation is in progress.

It learns only when the new word looks or sounds like the old one, has at least three letters, is not a common English word, and is not in the dictionary already. A change of capitals only, a rewrite of several words, or a change outside the dictation teaches nothing. The old word is kept as a misheard spelling only when macOS's spell checker does not know it, so a real word, such as "more" fixed to "Moore", is never replaced in later dictations. A dictation sent with **Press Return after the text goes in** is not watched, and neither is a snippet. Fields longer than 20,000 characters are not read, and neither are fields in the password apps listed under names from the screen. Nothing leaves your Mac.

## Snippets

A snippet is saved text that a spoken cue stands for, such as "my address" for your full address. When the whole dictation is a cue, Lip Service inserts the snippet's text instead, exactly as you saved it, line breaks included. Case, punctuation, apostrophes, and the spaces around the words don't matter, so "My address." and "my address" both match, but "send my address to Sam" does not. A snippet gets no cleanup, no profile style, and no smart spacing. The profile's **Press Return after the text goes in** still applies. **Paste last dictation** inserts a snippet exactly as saved too.

**Add Snippet** on the Dictionary page adds one. The cue is one line, and the text can be several. Hover over a snippet to edit or delete it, or double-click it to edit it. Two snippets can't share a cue. Snippets are stored with the other settings, under `settings` in the `com.hunterbohm.dictation` defaults domain. A stored snippet, dictation key, profile app, or group rule that can't be read is dropped on its own, and the rest still load.

## First run

On first launch, Lip Service opens a setup window instead of its main window. It offers two ways in.

**Set it up** goes through these steps, with **Back** on each and **Skip** where nothing breaks without it:

1. **Permissions**: Microphone, Accessibility, and Keyboard > **Press fn key to** set to **Do Nothing**. Each has a button to the right System Settings pane, and each row turns to Done once it's granted. **Continue** waits for all three.
2. **Try it**: click the box, hold fn, and talk. It shows the time from letting go to the paste.
3. **How you write**: a style for each group of apps, the same as on the Profiles page.
4. **Ghostwrite**: pick the agent that writes for you. The agents found on this Mac come first, and Hermes is always offered, on this Mac or on another one by its ssh name. The step says what Ghostwrite sends.
5. **Check**: Lip Service asks the agent for one word and shows how long it took, or why it failed, with **Try again**. Below that is where hand-offs go, filled in for the agent you picked.
6. **You're set**: the three keys and what each does.

**Let my agent set it up** shows a prompt to copy into the agent you use. It is described under Set up with your agent. When the agent applies its setup, the window lists what changed, with **Undo**, and goes on to Permissions, which only you can grant.

**Set up again…** on the Home page and in the menu opens the window again.

## Ghostwrite

Hold the Ghostwrite key, ⌃fn at first, and say what you want written, such as "tell her Thursday works, after 3". You can also hold fn and press Control right after. When you let go:

1. Lip Service turns your words into text on your Mac, as for a dictation.
2. It sends the request to your agent. A request holds:
   - your words;
   - the app you're in;
   - what Lip Service can read of the window: its title, the field with the cursor marked, and the text nearest it;
   - up to 8 of your recent dictations from apps in the same profile group, as examples, while **Learn my voice from my dictations** is on;
   - your voice notes.

   It asks for only the text to insert, keeping every detail you asked for, such as times, days, names, and numbers. Each request starts a new conversation with the agent.
3. The bar shows the agent's initial and what it is doing. The draft streams into a card above the bar.

In the card:

- **Return** types the draft into the field you started in.
- Holding the Ghostwrite key again and saying a change, such as "shorter", sends it in the same conversation, and the new draft streams in.
- **Escape** throws the draft away.

The card takes these keys only while the app you started in is in front. Every other key reaches that app as usual. A quick tap of fn over a draft keeps the draft.

- **No tools.** A draft needs none, and the window's text may hold instructions from someone else. Claude Code drafts start with its built-in tools off and none of your MCP servers, and Codex drafts run in its read-only mode, with no network. Every agent's permission requests during a draft are refused without asking you. If the agent starts a tool anyway, Lip Service cancels the turn, never reuses that conversation, and the card says "Hermes tried to use a tool, so Lip Service stopped the draft." An agent that runs a tool without asking may already have started it by then.
- **Failures.** If the agent fails or isn't installed, the card says why, keeps your words, and offers **Retry** and **Copy words**.
- **No text field.** In a window without one, the button reads **Copy it**, and Return copies the draft.
- **No card.** With **Show the draft before typing it** off, the finished draft is pasted as soon as it is done, with no card.
- **Naming an agent.** Start a request with an agent's name, as in "Claude, reply that I'm in", and it goes to that agent instead of the default.

Drafts use the agent's fast model where Lip Service knows it:

| Agent | Draft model |
| --- | --- |
| Hermes | Claude Haiku, low reasoning |
| Claude Code | Haiku, low effort |
| Codex | GPT Luna, low |
| OpenCode | GPT Luna |

Hand-offs and voice notes use the agent's own default model. In testing, Hermes on Claude Haiku showed the first words about 1.4 s after the words were sent; Codex and OpenCode took 5 to 16 s.

**Your voice** on the Ghostwrite page holds a few lines on how you write, sent with every draft. Write them yourself, or click **Build with** your agent to have it write them once from your recent dictations, with its full model. While it does, it may only read, search, and think.

## Hand off

Hold the Hand off key, ⌥fn at first, and say a task. The card shows what was heard and where it is going, with a 5 s countdown: **Send now** or Return sends at once, and Escape or **Cancel** stops it. The message is your words. While **Send the window's text with hand-offs** is on, which it is not in a new install, the window's text follows as one block, up to 4,000 characters. Afterwards the bar says the task left without typing anything.

Where it goes, set per agent under **Hand off goes to**:

- **iMessage** sends from your own Messages to the handle you enter, such as the number where Hermes answers you. The first time, macOS asks you to let Lip Service control Messages.
- **T3 Code** opens a project picker instead of the countdown. Type to filter, and pick a project to send. A new thread starts there with your words, and T3 Code opens on it. Connect it once on the Ghostwrite page: make a pairing code in T3 Code (Settings, Connections), paste it, and click **Connect T3 Code**.
- **Telegram** opens the chat with your bot with the text typed in, for you to send.
- **Slack** posts a direct message to the bot as you, with your Slack user token.
- **Discord** posts through a channel webhook and mentions the bot. Discord caps a message at 2,000 characters.
- **Web address** posts JSON. With a secret, it is signed the way GitHub and Hermes's webhook check:
  - `X-Hub-Signature-256`, an HMAC-SHA256 of the body;
  - `X-Webhook-Signature-V2`, an HMAC of `timestamp.body`, with `X-Webhook-Timestamp`;
  - and `X-Request-ID`.
- **Command** runs a program you choose, without a shell. It gets the JSON on stdin and `LS_TEXT`, `LS_APP`, `LS_TIMESTAMP`, and, when the window text is sent, `LS_CONTEXT_FILE` in its environment.
- **Reply in the card** has the agent do the task itself, and its reply shows in the card.

Tokens and secrets live in the Keychain under the service `com.hunterbohm.dictation.agents`. The app is signed with its own certificate, so after each update macOS asks for your Mac password the first time it reads one.

## Live talk

Double-tap Left Control, on its own, to start a hands-free spoken talk with an agent. Double-tap it again to end. Each tap must be shorter than 0.3 s, with less than 0.4 s between them. Holding Control for a shortcut, a Control-click, or any other key or modifier in between never counts. If a dictation key is Left Control alone, Live talk stays off and the Ghostwrite page says why.

1. An island appears at the top centre of the screen with the pointer, in the style of the iPhone's Dynamic Island, and says it is connecting. A note says how to end. Lip Service starts the agent if it isn't running and opens one session for the whole talk: the session the last talk ended in, for an agent that carries on (see **One conversation** below), or a new one.
2. Talk. After 0.8 s of quiet your turn ends, Parakeet turns it into text on your Mac, and the text goes to the agent with a short note that it is a voice call: answer in short spoken sentences, and put anything meant for the screen in `<show></show>`.
3. The agent's reply is spoken as it streams in. The first piece goes to the voice at the first comma or sentence end once a few words have come, and each next piece is made while the last one plays.
4. Talk over the agent to cut in: the voice stops, the agent's turn is cancelled, and your new turn starts. While the agent's voice plays, only talk clearly louder than its echo cuts in, since the microphone also hears the speakers.

A talk ends when you double-tap Left Control, say goodbye ("goodbye", "bye", "end call", "hang up", "that's all", on their own), click the x on the island, or after 2 minutes with nobody talking. At 100 s the island opens and warns "Still there?". Nothing pops up under the island when a talk starts or is about to end: hover over the island and how to end it is beside the x. A talk has its own two sounds, three rising notes when it starts and the same three falling when it ends, lower and longer than a dictation's, so you can hear which one you started. **Interaction sounds** in Settings turns them off too. While a talk runs, the dictation keys do nothing, since the talk has the microphone. The microphone is the one dictation uses, picked the same way, so Automatic never opens AirPods' microphone when a wired or built-in one is there.

- **The island.** It is black, with a rim of light around its edge and a soft glow in the same color, so it stands out on a black window as well as a light one. The rim takes the globe's color, so it is blue while you can talk, violet while the agent thinks, amber while it speaks and green while a call back rings. Floating, the closed island is 256 by 44 points, a little bigger than the bar a dictation shows; in a notch it is as tall as the notch. On a screen with a notch it grows out of the notch, with its top corners curving into the screen edge; elsewhere it floats just below the top. When another app keeps a bar across the top, such as the top bar of a tiling window manager like OmniWM or AeroSpace with SketchyBar, which would cover it, the island floats just below that bar instead, on a screen with a notch too, with the same small gap as on a screen without one, and its cards hang under it there. Lip Service looks for that bar when the talk starts. Compact, it shows a globe on the left and the voice on the right: five bars that move with whoever is talking, white for you and amber for the agent, or three rising dots while the agent works. While the agent is on a step, the closed island widens to show that step (see **Tools**). The globe is a grid of dots, like ASCII art, that floats and turns, with brighter dots for land. Its colors turn around it and say what is happening: blues while you can talk, violet and pink while the agent thinks, amber while it speaks, green while a call back rings, and greys while the talk connects. It turns faster while the agent works, and the voice swells it, brightens it and sends ripples across it. The island opens when there is something to read: your last words with what the agent is doing while it thinks, the sentence the agent is saying, or the warning that the talk ends soon. Hover over it to open it and show the button that ends the talk; clicks anywhere beside it reach the app under it. With Reduce Motion the globe, bars and dots are still. The dictation bar is hidden during a talk.
- **Tools.** Each tool the agent starts shows on the island as one short line, such as "Running t3-run status", "Loading media-request skill", "Checking Gmail" or "Reading plan.md", with the icon of the app it uses in front: T3 Code for `t3-run` and T3 Code's tools, your browser for a web search, Calendar, Slack, Obsidian for a note in your vault, Terminal for another command, and a colored tile for a service with no Mac app, such as Gmail or Stripe. What the agent does inside itself, like loading a skill, keeps a plain symbol. The step it is on shimmers; up to three earlier steps of the turn stay under it, dimmed, in the past tense with a green check ("Checked Gmail"), or an amber "didn't work" when the tool said it failed. Each step stays up at least 0.9 s. After 5 s on one step a timer counts beside it. After 20 s on the same step the island folds down and carries the step closed: the timer by the globe, and the app's icon with a word or two ("t3-run status") on the other side of the notch, or in the middle on a screen without one. A new step opens it again. The line keeps only a few safe words of the tool's arguments: a command's program and subcommand, a skill's or file's name, a web host, or a short search. Quoted text, flags, values, folders and anything that looks like a key are left out. Lip Service also says the line, at most one every 4 s.
- **Call back, promised.** When the agent runs `call-me-back run`, the step reads "Setting up a call back" and the island opens for 8 s to say "Hermes will call you back when it's done. You can hang up. It rings here."
- **Results.** JSON inside `<show>` becomes a result the island draws itself. Lip Service tells the agent the formats at the start of each talk:
  - `{"type":"flights","from":"AUS","to":"SFO","date":"Fri, Nov 14","note":"nonstop","options":[{"airline":"United","depart":"7:05 AM","arrive":"9:00 AM","duration":"3h 55m","stops":"Nonstop","price":"$214","best":true,"url":"https://…"}],"actions":["Hold the 7:05"]}` draws the route, then up to 4 options one after another, with **Best** on the one marked. Sending the same route again updates the card where it is, so options can come in as the agent finds them; while it is still working, a "Looking for more…" row shimmers under them.
  - `{"type":"task","id":"PP-3","title":"…","status":"…","due":"…","where":"vault","done":false}`, `{"type":"event","title":"…","date":"2026-11-12","time":"3:00 PM","where":"…"}`, `{"type":"email","from":"…","subject":"…","time":"…","snippet":"…"}` and `{"type":"item","title":"…","detail":"…","app":"slack"}` draw rows, alone or up to 4 in a JSON list or `{"type":"list","items":[…]}`: a task with its check circle, a meeting with a date tile, an email with who and what.
  - A row or option with a `"url"` opens it on a click. Only web addresses (`http`, `https`) and an Obsidian link that opens a note (`obsidian://open` with `vault`, `file` or `path`) are kept.
  - `"actions"`, up to 2 labels of at most 28 characters, become buttons. Clicking one sends its label to the agent as your next words, cutting in if it is speaking, and works once.
  - A result holds the island open for 14 s, or 30 s when it has buttons, and stays for 10 minutes under the pointer; while it is folded away, a green dot on the globe says there is one to read. One result shows at a time, with one line beside it. JSON the island can't draw stays a card.
- **Cards.** What the agent wraps in `<show>` is not read out. A short line of plain text, such as a task it just added, shows inside the island with a green check, under whatever the island is showing: a new one opens the island for 6 s, the pointer over the island shows it again, and the two newest stay for 2 minutes or until the talk ends. Anything else appears as a card under the island, in the island's look: a link with **Open**, an image, longer text or code, or a small HTML visual such as a chart. A visual runs no scripts and loads nothing from the network. An image card loads its picture from the address the agent gave, from your Mac. Cards stay until you close them or for 2 minutes, after the talk too.
- **Permissions.** The agent may read, search and think without asking, as for voice notes. For anything else Lip Service asks you on a card and out loud. **Deny** or a spoken "no" refuses it. A spoken "yes" allows only fetching a page and starting a T3 Code thread (see **T3 Code threads** below); running a command, editing, deleting, moving or anything unnamed needs **Allow** clicked on the card. Lip Service only ever picks "allow once". A question left unanswered for 60 s is refused.
- **T3 Code threads.** A talk with Claude Code can start threads in T3 Code: say "start a thread in Lip Service to fix the login", and Claude Code finds the project, and Lip Service asks, out loud and on a card, "Start a T3 Code thread in Lip Service called Fix the login. Say yes or no." The question is built from what Claude Code passes to T3 Code (project, title, task), not from what it says. Say yes or click **Allow** and the thread starts; Claude Code says so in a sentence. Each talk starts in an empty scratch folder, in no project, so the project is always the one you name.
  - It needs T3 Code running and connected (paste a pairing code under **Talk with** on the Ghostwrite page, or in the agent's Hand off settings) and Claude Code running on this Mac. Without that the talk works as before and Claude Code has no way to start a thread.
  - Claude Code reaches T3 Code through `Dictation --t3-mcp`, an MCP server that is Lip Service's own binary, listed in the session's `mcpServers`. It reads the token from the Keychain itself, so the token is never in Claude Code's command line, environment, prompt or logs. It serves four of T3 Code's tools: `t3_project_list`, `t3_thread_launch`, `t3_thread_list` and `t3_thread_read`. Anything else is refused there. A new thread takes only a project, a title and a task, and runs as T3 Code's defaults say, as a hand-off does. Listing and reading go ahead without asking.
  - A talk with these tools sets Claude Code's permission mode to `default` on the session. Left to itself, Claude Code starts in `auto` mode, or the `defaultMode` in its settings, and an MCP call such as starting a thread then goes ahead with no question. If Claude Code refuses the mode, the talk starts without the tools.
- **Agent.** **Talk with** on the Ghostwrite page picks the agent, Hermes or Claude Code or another you have set up, with **Add another agent** when only one is; the default agent unless you pick another. Each agent has its own **Live talk uses** model and effort, set on the session at the start of each talk:

| Agent | Live talk model |
| --- | --- |
| Hermes | Claude Opus 5.5, low reasoning |
| Claude Code | its default model, low effort, with the T3 Code tools when T3 Code is connected |
| Codex, OpenCode, Gemini | their own defaults |

  An agent can also carry a talk note, added to every turn. Hermes's tells it to send you something with `hermes send -t photon` through a quoted heredoc, so nothing in the text runs in the shell. A talk with Hermes shows in Hermes's own history, like any other session.
- **One conversation.** Hermes's talks are one conversation that never ends, like your messages with it in iMessage. The first talk opens a session, Lip Service remembers its id, and each next talk asks Hermes to open that session again (`session/resume`), with everything said before still in it, so Hermes picks up where the last talk left off. The id is kept per agent in `~/Library/Application Support/Dictation/talk-threads.json`, along with the command that started the agent, so another command or another Mac starts a new conversation. An agent that can't open an earlier session (it says so when it starts, in `agentCapabilities`) gets a new session for every talk, as before. Claude Code can open one too, but only Hermes is set to carry on; **Keep one conversation going**, under **Talk with** on the Ghostwrite page, turns it on or off for any agent, and off, every talk is new.
  - **When it starts over.** Only when you say so: **Start a new conversation** under **Talk with**, or **Start a New Talk Conversation** in the menu bar. That is the rule of Hermes's own iMessage chat, which has no timer: its gateway stopped rotating conversations on idle or daily timers (hermes-agent commit `1d5d059410`), and nothing under `session_reset` in `config.yaml` is read, so it starts a new conversation only on `/new` or `/reset`. Talks do the same: a month later the next talk is still in the same conversation. They also start a new one when the agent no longer has the session (its history was cleared) or refuses to open it, when a talk's agent ignored a cut-in so its session can't be trusted (the talk goes on in a new session, which is the conversation from there), and when the agent's command or Mac was changed. The old session stays in the agent's history.
  - **Long conversations.** Hermes compresses a long session by itself when it nears its context limit (`compression:` in `config.yaml`), and the session id Lip Service holds stays the same, so the thread doesn't break. A session compressed to a summary and its last messages, then stopped and opened again, still knew what was said at the start. The agent sends the session's history back as it opens it; Lip Service ignores it, so none of it is said or shown. A conversation that has grown costs more per turn, until it is compressed.
  - **Call backs** join the conversation, since the result is most often about something you asked for in it, and the agent knows what the job was.
  - **Start-up.** An agent keeps running between talks (see **Agents**), and the session stays open in it, so a talk that starts while it does goes on in it with no request at all. After the agent was stopped, or restarted by Lip Service, the talk starts it and opens the session again, which costs about as much as opening a new one.
- **Voice.** **Voice** on the Ghostwrite page picks it. The default is Preston, an American voice from Gradium's Phonon 31M, run by FluidAudio's PocketTTS on the Neural Engine, which makes about 5 s of speech in 0.3 s on a MacBook Pro. Six more Phonon voices are offered, and Kokoro's voices, such as Michael, are still there. The first talk with a Phonon voice downloads its pack, 134 MB, pinned and checked like the speech models (see Speech models). A Kokoro voice downloads Kokoro, about 90 MB, whose files are not pinned or checked. The model stays loaded 10 minutes after a talk so the next one starts at once. **A voice server** sends each piece to a server of your own instead, such as a PC with a GPU: `POST {server}/speak` with JSON `{"text": "...", "voice": "...", "format": "wav"}`, answered with a WAV, 16-bit or 32-bit float, any rate. Another kind of voice, such as a hosted one, can be added behind the same small interface in `Sources/Dictation/TalkVoice.swift`.
- **Speed.** Each turn logs, under the `talk` category, how long after you stopped talking your turn ended, it was transcribed, the agent's first text came, and the voice started, all counted from the end of your speech, so `transcribed` includes the 0.8 s pause. Your words are transcribed 0.5 s into the pause, while it runs out, and that text is used when no words came after it, so the text is ready within 0.03 s of the turn's end. In testing with Hermes on a Mac mini over Tailscale, on Opus 5.5 with low reasoning, the voice started about 3 to 3.5 s after the end of speech: the 0.8 s pause, about 0.03 s more for the text, 1.9 to 2.3 s for Hermes's first words (3.1 s on a session's first turn), up to 0.1 s for the first piece, and 0.15 to 0.25 s for Preston's first audio.
- **Idle.** With no talk running, nothing of it runs: no audio engine, timer or view, and Left Control is watched only as part of the key events Lip Service already sees.

### Call back

An agent can call you back when a background job finishes. Hand it a long task in a talk, hang up, and when the job is done the agent's own script runs `Dictation call` on your Mac with the result:

```sh
"/Applications/Lip Service.app/Contents/MacOS/Dictation" call --from Hermes --about "the flight search" < result.txt
```

1. Lip Service first checks whether you can take a call. It won't ring while the screen is locked, a Focus is on, another app is using the camera, or another app is recording from a microphone, as a Zoom, Meet or FaceTime call does (Siri's always-on listener doesn't count). It also waits while a talk or a dictation is running. It answers `busy` with the reason, so the caller can text you instead and try again later.
2. Otherwise the island rings for 30 s: "Hermes is calling", what it is about, **Decline** and **Answer**, and a talk's start sound twice every 3 s. Double-tap Left Control or click **Answer** to pick up.
3. The voice on your Mac says "Hi, it's Hermes, calling you back about the flight search." while the agent's session opens. Then the result goes to the agent as the talk's first turn, in the same session as any other talk with it, with the usual voice-call note, and the agent says it in a few short sentences, puts links or numbers on a card, and asks if you need anything else. From there it is a normal live talk.

`Dictation call` prints one JSON line per status and exits with the last one's code: `delivered` (0) once the agent's first reply has played to the end or you talked over it; `declined`, `missed` or `hung-up` (3) when the result wasn't said, so the caller should text it; `busy` (4) to try later; `failed` (5) when it couldn't ring, as when Lip Service isn't running or no agent is set up. `--ring 0` starts the talk at once without ringing, `--agent` picks the agent the talk goes to (the one Live talk uses unless given), `--result-file` reads the result from a file, and `call --check` prints whether you look busy now without ringing.

The result travels in a private file in `~/Library/Application Support/Dictation/calls/`, deleted as soon as the app reads it; the notification that wakes the app carries only an id. A request older than a minute is ignored. The Focus check reads `~/Library/DoNotDisturb/DB/Assertions.json`, where a Focus turned on by hand shows; a Focus that only a schedule turns on may not.

## Agents

Lip Service talks to agents over the Agent Client Protocol (ACP), the same way code editors do, so it uses the agent and plan you already have. Built in:

| Agent | Command |
| --- | --- |
| Hermes | `hermes acp` |
| Claude Code | `npx -y @agentclientprotocol/claude-agent-acp` |
| Codex | `npx -y @agentclientprotocol/codex-acp` |
| OpenCode | `opencode acp` |
| Gemini | `gemini --acp` |

**Custom** takes any command.

- The command runs through your login shell, so it finds the same programs your terminal does.
- **Runs on** takes another Mac's ssh name, such as `mini`. The agent then runs there through `ssh -T -o BatchMode=yes`, so the ssh key must work without a prompt. Over Tailscale that is fast.
- One agent is the default. **Change** on the Ghostwrite page picks it.
- Lip Service starts the agent while you are still talking, then keeps it running with a session ready, so the next request skips the start-up. That session is for drafts; a live talk uses its own (see **One conversation**).

## Set up with your agent

The app has a `setup` command that an agent can run:

```sh
"/Applications/Lip Service.app/Contents/MacOS/Dictation" setup show
"/Applications/Lip Service.app/Contents/MacOS/Dictation" setup apply --by "Claude Code" < setup.json
"/Applications/Lip Service.app/Contents/MacOS/Dictation" setup test [AGENT_ID]
```

- `setup show` prints the setup as JSON: the agents and the default one, the three Ghostwrite switches, your voice notes, the style and Return switch of each profile group, and the keys. It also prints `found`, the agents installed on this Mac, and `help`, which describes every field.
- `setup apply` reads the same shape on stdin. Every field is optional, and a field left out stays as it is. It checks everything first. If anything is wrong, it changes nothing, lists the problems, and exits with status 1. Otherwise it keeps your previous settings for Undo and writes the new ones. The running app then shows "*name* set up Lip Service" with the list of changes, **Undo**, and **Got it**. If the app isn't running, the changes take effect when it starts.
- `setup test` asks an agent for one word and prints how long it took.

The command never reads or writes the tokens for Slack, Discord, web addresses, or T3 Code; set those up in the app. It can't grant permissions either. **Copy setup prompt** copies instructions for your agent that use these commands with the app's real path.

## Vocabulary file

The vocabulary lives in `~/Library/Application Support/Dictation/vocabulary.txt`. The app creates it on first launch with no words, only comments and two examples that are commented out. It never replaces a file that exists. The Dictionary page edits the file, and **Open Vocabulary File** in the menu or on the Dictionary page opens it in your editor, recreating it if it was deleted. A change saved in an editor applies at the next key press, menu open, or return to the window. A change made on the Dictionary page applies at once.

	# One term per line, spelled the way it should appear.
	@min-similarity 0.7
	Figma
	Siobhan: shivon, chevonne

- Each term is one line, spelled the way the text should show it. Terms go to the boosting model, and the cleanup rules also fix their capitals. A term that is also an everyday English word, such as Notion or Linear, keeps the capitals it was heard with, so "a vague notion" stays lowercase, and is spelled as the term only where boosting or a misheard spelling put it in.
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

1. Vendor FluidAudio with `scripts/fetch-deps.sh`. The script clones the pinned v0.18.3 commit into `Vendor/FluidAudio` and applies six patches. The first removes its `NemoTextProcessing` binary target, which the app never uses. SwiftPM would download that target with URLSession, and URLSession crashes in an SSH session. The second makes FluidAudio's vocabulary rescoring build a character set once instead of once per word, which cut rescoring a 75 s dictation from 0.15 s to 0.01 s without changing its output. The third adds a `VocabularyRescorer.create` that takes a tokenizer that is already loaded, so the app reads `tokenizer.json` once, from the folder that passed the check, and rebuilding the vocabulary reads no file. The fourth keeps a word the decoder was at least 0.95 sure of when a term spelled differently would replace it, since the CTC check passed nearly every such swap, such as "look" to Loom. Words that already spell the term, such as "post hog", are exempt. FluidAudio v0.18.3 has a similar gate of its own at 0.99, but it lets a close spelling keep its bias, which turned "entry" into Sentry, so the patch stays and acts where FluidAudio decides a replacement. The fifth compares a heard word with a term by sound as well as spelling, merging English spellings of one sound such as ph and f, so "in physical" is a near match for Infisical. The sixth downloads only the files in the pinned model table, refuses any path the server lists that would land outside the model's folder, and ignores a Hugging Face token or registry address from the environment. `Package.swift` turns on FluidAudio's `TTS` trait, for the Phonon text-to-speech voices, and leaves `NemoTextProcessing` off, so the first patch is still needed. A vendored copy made by another version of the script is re-vendored on the next run.
2. If you will run the self-test, the bench, or `scripts/e2e.sh` over SSH, cache the models with `scripts/fetch-models.sh`, which downloads them with curl at the pinned commits and checks every file, as the Speech models section describes. The app downloads the same models itself on first launch, so a Mac that only runs the app does not need this step.
3. Build and sign the app with `scripts/build-app.sh`. The script runs a release build in `/tmp/lip-service-build-` plus a short hash of the checkout's path, which does not name your account and is not shared with another checkout building at the same time, because SwiftPM compiles the build directory into the binary and a release must not carry the builder's home folder. It then assembles `dist/Lip Service.app` beside the previous bundle, copies the license texts into `Contents/Resources/Licenses`, signs the bundle, checks the signature with `codesign --verify --strict`, and renames it into place.

The first release build of FluidAudio takes several minutes. Later builds take seconds. To check a build, `strings "dist/Lip Service.app/Contents/MacOS/Dictation" | grep /Users/` prints nothing.

The license texts are Lip Service's own, FluidAudio's, and the three FluidAudio third-party licenses that cover code in the FluidAudio product: fastcluster, VBx, and the Japanese text frontend. FluidAudio's other third-party licenses cover the binary target that `fetch-deps.sh` removes, text-to-speech model files the app does not ship, and the LuxTTS English G2P tables, which come from GPL-3.0 espeak-ng output and sit in a resource bundle that the `TTS` trait builds but `build-app.sh` never copies into the app. The build stops if one of those files is in the bundle. Live talk downloads its voice's model files at run time, under their own licenses, and the app ships none of them. The build stops if FluidAudio adds a third-party license that `build-app.sh` does not list yet.

To make a release zip, name it after the version in `Info.plist`. Sign a release with the certificate whose fingerprint the README lists, or the README's check fails for everyone who downloads it:

	ditto -c -k --norsrc --noextattr --keepParent "dist/Lip Service.app" dist/Lip-Service-1.0.27.zip

## Speech models

The app downloads two models from Hugging Face on first launch: Parakeet TDT 0.6B v2, and the Parakeet CTC 110M model behind vocabulary boosting, which loads only when the vocabulary has terms. Live talk's Phonon voice pack is downloaded on the first talk with a Phonon voice, and is pinned the same way. All three are pinned to a commit, not to a branch, and every file is checked before Core ML reads it. The download goes to huggingface.co with no token, whatever the environment says, fetches only the files in the table, and refuses any path the server lists that would land outside the model's folder.

- `DictationCore/Sources/DictationCore/PinnedModels.swift` holds the table. Each model has its repository, a full 40-character commit, its folder in FluidAudio's cache, and every file with its size and SHA-256. The commits are the heads of both repositories on 2026-10-25, the files that every benchmark in this repository used.
- Before the app loads a model, `ModelCheck` compares its folder with the table. It reports a missing file, a wrong size, a wrong hash, a listed file that is a link or folder, a file inside a Core ML bundle that the table does not list, and anything it cannot inspect or list, such as a folder it may not open or a bundle that is a link. A failure to look is a failure of the check. A file outside the bundles, such as FluidAudio's `.fluidaudio-revision` marker, is ignored. The check reads the cached files once and added about 0.3 s to a launch on the Mac mini, measured with the files in memory.
- The app points FluidAudio at the pinned commits, downloads with `ModelHub.download`, which does not load anything, checks the folder, and only then loads it. The vocabulary file comes from the pinned commit as well. After a folder passes, the app writes the revision marker FluidAudio reads, which also adopts a cache that 1.0.0 or 1.0.1 downloaded from the main branch when its files are the pinned ones.
- The CTC folder's `tokenizer.json` is read once, right after the check, and kept in memory. The vocabulary terms are tokenized with that copy and the rescorer gets it too, so no step reads FluidAudio's default cache, which other apps share and fill from the main branch.
- A cache that fails the check is deleted and downloaded once more. If the new download fails the check too, the bar shows the first file that differs, and Retry Loading the Model tries again. A download that stopped halfway is kept and resumed instead: files not yet fetched, and the `.partial` files of those. A listed file that is a link or folder, or a `.partial` file left beside its finished file, is damage and not a late download. FluidAudio skips a file it already has, so the leftover would fail every retry.
- Loading runs in FluidAudio's offline mode, so its own recovery from a failed load, which deletes the folder and downloads again, cannot hand Core ML files that nothing checked.
- The voice pack is one folder of `FluidInference/pocket-tts-coreml`, `phonon/phonon-31m-en`, in FluidAudio's text-to-speech models folder, `~/.cache/fluidaudio/Models/pocket-tts`. The table lists what FluidAudio's `PocketTtsSmallManager` reads: the `pocket_state` and `mimi_decoder` Core ML bundles, `arch.json`, `pocket_state.json`, three files of `constants_bin`, the pack's Apache-2.0 `LICENSE`, and the seven voices the settings offer, 134 MB. The reference models, the `.mlpackage` sources, `constants/` and the other 96 voices are never fetched. Only the pack's folder is downloaded, through FluidAudio's subdirectory download, under the same guard. A failed check deletes the pack's folder, never the repository's.

To move to other model files, change the commits in `scripts/pin-models.py` and run it:

	python3 -I scripts/pin-models.py

The script downloads every file the app reads at those commits, compares each with the hash the Hub publishes, and rewrites `PinnedModels.swift` and `scripts/models.lock`. Review the diff. The Phonon voices it pins are listed in the script and must match `OnMacVoice.phononVoices`, which a unit test checks. `scripts/fetch-models.sh` reads `models.lock`, downloads with curl, and checks size and SHA-256. A folder that is already there is checked and never deleted. `MODELS_DIR` replaces FluidAudio's models folder for the script. `scripts/fetch-models.sh --voice` also fetches the voice pack, into `VOICES_DIR` or FluidAudio's text-to-speech models folder, as `--test-talk` over SSH needs.

The self-test and the bench never download or delete. They stop with the files that fail the check. `--models DIR` runs them on another models folder, such as a copy, and `scripts/e2e.sh` passes `MODELS_DIR` along. The app writes the revision marker into the folder it checks, so use a copy to keep a cache untouched.

## Test

- `scripts/test.sh` runs the DictationCore unit tests with swift-testing. It covers the hotkey state machine, shortcuts and their recording, the cleanup rules, aliases, punctuation repair after boosting, the clipboard restore, the paste-or-copy decision, the vocabulary parser and writer, the bar state and its messages, the history numbers and captions, smart spacing, profile styles, snippets, the Press Return checks, the password apps never read, learning from fixes, the mute marker, the auto level, the 10 ms voice analyzer and its three bands, the live voice levels, Automatic's order, and reading Willow's transcripts and settings from small sample files. It fails first if `DictationCore/Sources` imports AppKit, AVFoundation, CoreGraphics, or FluidAudio, so the tests never build FluidAudio.
- `scripts/e2e.sh` tests the built app binary. It runs `--self-test`, then `--bench` over `bench/clips/*.wav`, and scores the results against the bakeoff that chose the engine. It fails if a dictation errors, if vocabulary hits fall below 18 of 20, or if the word error rate on the synthetic clips rises above 3.2%. The bench runs live previews while the simulated key is held, as the app does. The environment variables `ROUNDS`, `HOLD_CAP`, `GAP`, `WARM`, and `PREVIEW` change the bench settings. `bench/make_clips.py` makes the clips. It reads `bench/manifest.jsonl` aloud with the macOS voice Samantha, and it also cuts real clips from a recording listed in `bench/real.json` when that file exists. `bench/real.json` and the recording stay out of the repo.

The app binary has these headless modes, among others. Both scripts use the first two:

	"dist/Lip Service.app/Contents/MacOS/Dictation" --self-test
	"dist/Lip Service.app/Contents/MacOS/Dictation" --bench --rounds 3 --hold-cap 15 bench/clips/*.wav
	"dist/Lip Service.app/Contents/MacOS/Dictation" --list-inputs
	"dist/Lip Service.app/Contents/MacOS/Dictation" --tts-check --pack DIR
	"dist/Lip Service.app/Contents/MacOS/Dictation" --render-bar /tmp/bar
	"dist/Lip Service.app/Contents/MacOS/Dictation" --render-window /tmp/window
	"dist/Lip Service.app/Contents/MacOS/Dictation" --import-willow-dry-run FOLDER
	"dist/Lip Service.app/Contents/MacOS/Dictation" --test-talk --host mini clip1.wav clip2.wav
	"dist/Lip Service.app/Contents/MacOS/Dictation" --t3-mcp

`--render-window` draws every page of the window with sample history, settings, vocabulary, and microphones (the Microphone page also with Automatic chosen, before and after its order is changed), and the Dictionary page once more with the vocabulary a new user starts with, to PNG files in the folder. It works over SSH and leaves your settings, history, and vocabulary file alone. `--import-willow-dry-run` is described in the Import from Willow section.

`--self-test` loads the models the way the app does and transcribes `selftest.wav` from the bundle. The clip says "Profit Pilot" and "Bee hive" the way the engine mishears them, so the test exits 1 unless ProfitPilot, Beehiiv, and Friday reach the final text. `--bench` simulates a key press, plays the clip in real time to the live previews, releases after the clip's length or `--hold-cap` seconds, whichever is shorter, and prints one JSON line per clip and round. With a hold cap shorter than the clip, the part before it counts as already captured at the press. `--preview off` skips the previews. Both modes use the 13 terms the bakeoff measured, `Vocabulary.bakeoff`, not your vocabulary file. `--bench --vocabulary PATH` reads the terms from a file instead. Both modes stop with `models missing: run scripts/fetch-models.sh` when the models are not cached, and with the first file that differs when a cached model fails the check. `--self-test --allow-download` downloads them instead. Use it only in a GUI session.

`--tts-check` says one sentence with FluidAudio's Phonon voice en_us_Preston, through the library the app is built with, and prints the load time, the time to the first audio, the time to the last, and the length of the audio. It exits 1 if no sound came out, which also catches a build without FluidAudio's `TTS` trait. Without options it uses the pack the app uses, checked against the table first, in FluidAudio's text-to-speech models folder or the one `--directory DIR` names, and downloads it when it is missing, which URLSession only does in a GUI session; over SSH, fetch it first with `scripts/fetch-models.sh --voice`. `--pack DIR` loads a `phonon-31m-en` pack folder as it is, unchecked, such as a converter's output.

`--test-talk` holds a whole live talk with no microphone and no speakers, for timing it end to end. Each WAV clip is played into the talk in real time as your next turn, and the agent answers in a real session. The voice is made but not played, and each piece takes as long as it would to play, so the timings are a real talk's. It prints one JSON line per turn, with what was heard, the reply, the tool lines, the cards, and the seconds after the end of speech for `turn_end`, `transcribed`, `first_text`, `first_piece` and `first_audio`, and then one line with the session id, so a test talk can be deleted from the agent's history. `--preset` picks the agent (Hermes by default), `--command` and `--host` override its command and machine, `--voice kokoro:am_michael` or `--voice-server URL [--voice-name NAME]` picks the voice instead of `phonon:en_us_Preston`, which needs `scripts/fetch-models.sh --voice` first over SSH, `--note` replaces the agent's talk note, `--option ID=VALUE` replaces its live-talk session options, `--thread FILE` remembers the talk's session in FILE so the next run with it goes on in it, as the app's talks do with Hermes (`--start-over` forgets it first; without `--thread` every run is a new conversation and nothing is remembered, so a test never moves the real thread), and `--out PATH.wav` writes what the voice said. Make clips with `say -o clip.wav --data-format=LEI16@16000 "What is two plus two?"`. A clip of "goodbye" ends the talk. When the agent asks about a tool, the next clip is your answer, played after the question is said. `LS_SECRETS=FILE`, a JSON object of Keychain item names to values as for `--hand-off`, replaces the Keychain for T3 Code's token, here and in the `--t3-mcp` server the agent starts. `--t3-mcp` reads MCP messages on stdin and answers on stdout, to try the four tools by hand.

`--list-inputs` prints each audio input's name and UID, then the system default, then the microphone Automatic picks now by the saved order. `--mic-start` starts and stops the microphone as a dictation does, with the saved choice or `--microphone automatic`, `default`, or a UID, and prints one JSON line per round: `ready` is the seconds from the start to the first recorded sample, and `lost` is the part of the hold that was not recorded, at the start and at the release. It needs the Microphone permission, so run the app bundle through `open`, as in `open -n -W --stdout out.jsonl "Lip Service.app" --args --mic-start --rounds 10`. `--render-bar DIR` draws every state of the bar, in every position, with the app's own views on a stand-in screen, and writes a PNG of each, a close-up, and the same close-up on a near-black screen into DIR. It needs a user logged in to the Mac's desktop. An SSH session to that Mac works.

Two scripts regenerate test inputs. `scripts/make-cleanup-fixtures.sh` runs `bench/cleanup-inputs.txt` through `bench/cleanup.py`, the Python cleanup that the bakeoff measured, and writes the expected outputs as a Swift test fixture. `bench/cleanup.py` can also send text to a small model for the bakeoff's comparisons. That call needs `ANTHROPIC_API_KEY` for the Anthropic Messages API, and `CLEANUP_ENDPOINT` points it at another server with the same API. The fixtures need neither. `scripts/make-selftest-clip.sh` rebuilds `Resources/selftest.wav` with `say`.

Two more regenerate the app's resources. `scripts/make-icon.sh` builds `Resources/AppIcon.icns` from `Resources/AppIcon-1024.png` with `sips` and `iconutil`. `scripts/make-sounds.py Resources` writes the five cues: `start.wav`, `stop.wav`, and `cancel.wav` for a dictation, and `talk-start.wav` and `talk-end.wav` for a live talk.

## Signing

The app is signed with a self-signed code-signing certificate. `scripts/sign.sh` generates it on the first build and keeps it on the Mac that builds, in `~/.config/dictation/signing`, as `identity.p12` and `identity.pass`, both mode 600.

The signature carries the hardened runtime flag (`--options runtime`). A hardened app records silence unless it holds the audio-input entitlement, so `scripts/sign.sh` signs the app bundle with `Resources/Dictation.entitlements`, which holds `com.apple.security.device.audio-input` and nothing else. The self-test and `scripts/e2e.sh` run the models under the hardened runtime. Neither the flag nor the entitlements change the designated requirement, so a build keeps its permissions. `codesign -dvvv` shows `flags=0x10000(runtime)`, and `codesign -d --entitlements - "dist/Lip Service.app"` shows the entitlement.

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
