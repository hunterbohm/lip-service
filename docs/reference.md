# Lip Service reference

This page describes what Lip Service does, every setting, and how to build, test, and sign it. The [README](../README.md) covers downloading and installing the app.

## How it works

Everything runs on the Mac. Parakeet TDT v2, through [FluidAudio](https://github.com/FluidInference/FluidAudio) v0.17.7, turns the audio into text. A second, smaller model boosts the names in your vocabulary file, so a name the speech model spells its own way comes out the way you spell it. A fixed set of rules removes filler words and fixes capitals and punctuation. With **Smart formatting** on, a third model lays the text out, as described under Smart formatting. Audio stays in memory and is never written to disk or sent anywhere.

## Dictate

- To dictate, hold a dictation key, speak, and release it. The text is pasted at the cursor. The dictation keys are fn and Right Control until you change them on the Dictation page.
- To dictate without holding the key, tap it twice. Press it once more to stop and insert the text. Press Escape to stop without inserting.
- A tap shorter than 0.3 s does nothing. A shortcut such as fn+Delete is not a dictation. Another key pressed while you hold a dictation key cancels it.
- To paste your last dictation again, press Control+Command+V, or the shortcut you set, in any app. Before your first dictation the bar says so.

## The bar

While you speak, a dark bar at the edge of the screen shows a small halftone print of your voice, drawn in dots, that rises and falls as you speak and runs into the words heard so far. The print scales itself to your voice and the room from the last few seconds, so a quiet voice moves it as much as a loud one, and a quiet room stays dark. It spans the 24 dB below your loudest recent sound, never reaching down to within 5 dB of the room, so each syllable changes its height and a pause drops it. Each new word prints in through a fine dot screen. The words update about three times a second, and the bar grows with them. A long dictation shows its newest words, with the start fading out. The text that gets inserted is transcribed again from the whole recording when you let go, with your vocabulary, so it can differ slightly from the words in the bar.

Around the bar, a ring of small blue dots on a fine grid glows with your voice while you speak. The light starts at the print and spreads outward, so dots farther from it light a moment later and more faintly. The ring fades in when the bar appears and fades out when you let go. With Reduce Motion on, there is no ring.

In hands-free mode the bar also has a stop button, which inserts the text, and a cancel button, which throws the recording away. Clicking them does not take focus from the app you are typing in.

When you let go, the last words stay in the bar, dimmed, and the print settles to a thin line with a light running along it until the text is inserted. With Reduce Motion on in System Settings > Accessibility > Display, the bar fades instead of moving. The bar also shows the model's progress while it downloads or prepares. The bar never takes focus.

Short messages appear just above the bar, or below it when the bar is at the top of the screen. Each has a title, a second line that says why, and an icon that is green for information, amber for a problem Lip Service works around, and red for a failure:

- **Copied. Press ⌘V to paste.** Lip Service could not paste, so the text is on the clipboard. The second line says why: Accessibility access is off, a password field has secure input on, focus moved to another app or field before the text was ready, or the text waited more than 10 s for the model.
- **_Name_ isn't connected.** _Name_ is the microphone you chose. It is unplugged, so dictations use the system default until it is back, and the second line names the one in use. It shows on the first dictation without it, and again only if it comes back and goes missing later.
- **Nothing to paste yet** appears for the paste shortcut before your first dictation.
- **Learned _word_** appears when Lip Service added a word from your fix to the dictionary. **Undo** takes it out again.
- A failure, such as a model that could not load. A dictation waiting on a failed model shows **The speech model didn't load** with the reason and a **Retry** button.

Every dictation also goes into **Recent Dictations** in the menu, and clicking one copies it again. The list holds the last 20 dictations and lives in memory only, so it empties when the app quits. The history on the Home page keeps every dictation across launches.

The bar sits at the bottom center of the screen that has the mouse. To move it, drag it while you dictate, or drag the small idle bar. Dashed outlines mark the four places it can go: bottom center, top center, left middle, and right middle. Let go near one and the bar snaps there and stays there. On the left or right edge the bar is centered vertically and grows away from that edge.

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
- **Microphone** lists Automatic, System Default, and every input. Click one to dictate with it. Each choice says which microphone it uses now, and a Bluetooth one says it is slow to start. A chosen microphone that is unplugged stays in the list, marked not connected, under a message naming the one used instead. The input level below moves while you speak. It records only while this page is open, so the menu bar's microphone indicator shows then.
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

In the menu, **Microphone** picks the input to dictate with: **Automatic**, **System Default**, which follows the Mac's sound settings, or a device. Automatic, the setting new installs start with, uses a wired microphone (USB, Thunderbolt, or a display's) when one is connected, then the Mac's own unless the lid is closed, then a Bluetooth headset. It never picks a virtual device or an iPhone. Among microphones of one kind it takes the system default first. Bluetooth comes last because a headset's microphone takes from a quarter of a second to two seconds to start, and while it records, the headset plays in call quality. macOS often makes AirPods the system default when they connect, and Automatic keeps recording from the wired or built-in microphone then.

A chosen device that is unplugged stays checked in the menu, marked not connected, and dictations use the system default until it is back. The bar says so once, not on every dictation. A dictation keeps the microphone it started with until you release the key, even if a better one connects or macOS changes the system default, and moves only when that microphone is unplugged.

Between dictations, Lip Service keeps the next one's microphone set up but switched off, so a key press only switches it on: about 0.04 s on a MacBook's microphone and 0.06 s on a USB one, measured with `--mic-start`. The menu bar's microphone indicator stays off until you press. A Bluetooth microphone is set up at the press instead, because setting one up holds the headset in call quality. A chosen device whose sample rate differs from the system default's works too. Lip Service waits up to 0.15 s for macOS to switch the device while it sets it up, so the engine starts once.

The app stores every setting as one JSON value under `settings` in the `com.hunterbohm.dictation` defaults domain.

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

With **Learn from your fixes** on, which it is at first, Lip Service notices when you correct a word it typed. After it pastes into a field that shows its text to Accessibility, it remembers the field's text and where the dictation sits. When you start your next dictation, or a minute after the paste, whichever comes first, it reads the field once more. If the only change is one word of the dictation replaced by another, with a word of the dictation still next to it, it adds your word to the dictionary, and the bar shows **Learned _word_** with an **Undo** button. That notice stays up through the start of the next dictation. A field whose whole text was replaced, such as a sent message followed by a new one, teaches nothing. The dictionary change takes effect once no dictation is in progress.

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
- Lip Service starts the agent while you are still talking, then keeps it running with a session ready, so the next request skips the start-up.

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

1. Vendor FluidAudio with `scripts/fetch-deps.sh`. The script clones the pinned v0.17.7 commit into `Vendor/FluidAudio` and applies six patches. The first removes its `NemoTextProcessing` binary target, which the app never uses. SwiftPM would download that target with URLSession, and URLSession crashes in an SSH session. The second makes FluidAudio's vocabulary rescoring build a character set once instead of once per word, which cut rescoring a 75 s dictation from 0.15 s to 0.01 s without changing its output. The third adds a `VocabularyRescorer.create` that takes a tokenizer that is already loaded, so the app reads `tokenizer.json` once, from the folder that passed the check, and rebuilding the vocabulary reads no file. The fourth keeps a word the decoder was at least 0.95 sure of when a term spelled differently would replace it, since the CTC check passed nearly every such swap, such as "look" to Loom. Words that already spell the term, such as "post hog", are exempt. The fifth compares a heard word with a term by sound as well as spelling, merging English spellings of one sound such as ph and f, so "in physical" is a near match for Infisical. The sixth downloads only the files in the pinned model table, refuses any path the server lists that would land outside the model's folder, and ignores a Hugging Face token or registry address from the environment. A vendored copy without all six patches is re-vendored on the next run.
2. If you will run the self-test, the bench, or `scripts/e2e.sh` over SSH, cache the models with `scripts/fetch-models.sh`, which downloads them with curl at the pinned commits and checks every file, as the Speech models section describes. The app downloads the same models itself on first launch, so a Mac that only runs the app does not need this step.
3. Build and sign the app with `scripts/build-app.sh`. The script runs a release build in `/tmp/lip-service-build-` plus a short hash of the checkout's path, which does not name your account and is not shared with another checkout building at the same time, because SwiftPM compiles the build directory into the binary and a release must not carry the builder's home folder. It then assembles `dist/Lip Service.app` beside the previous bundle, copies the license texts into `Contents/Resources/Licenses`, signs the bundle, checks the signature with `codesign --verify --strict`, and renames it into place.

The first release build of FluidAudio takes several minutes. Later builds take seconds. To check a build, `strings "dist/Lip Service.app/Contents/MacOS/Dictation" | grep /Users/` prints nothing.

The license texts are Lip Service's own, FluidAudio's, and the three FluidAudio third-party licenses that cover code in the FluidAudio product: fastcluster, VBx, and the Japanese text frontend. FluidAudio's other third-party licenses cover the binary target that `fetch-deps.sh` removes and text-to-speech model files the app never downloads. The build stops if FluidAudio adds a third-party license that `build-app.sh` does not list yet.

To make a release zip, name it after the version in `Info.plist`. Sign a release with the certificate whose fingerprint the README lists, or the README's check fails for everyone who downloads it:

	ditto -c -k --norsrc --noextattr --keepParent "dist/Lip Service.app" dist/Lip-Service-1.0.11.zip

## Speech models

The app downloads two models from Hugging Face on first launch: Parakeet TDT 0.6B v2, and the Parakeet CTC 110M model behind vocabulary boosting, which loads only when the vocabulary has terms. Both are pinned to a commit, not to a branch, and every file is checked before Core ML reads it. The download goes to huggingface.co with no token, whatever the environment says, fetches only the files in the table, and refuses any path the server lists that would land outside the model's folder.

- `DictationCore/Sources/DictationCore/PinnedModels.swift` holds the table. Each model has its repository, a full 40-character commit, its folder in FluidAudio's cache, and every file with its size and SHA-256. The commits are the heads of both repositories on 2026-10-25, the files that every benchmark in this repository used.
- Before the app loads a model, `ModelCheck` compares its folder with the table. It reports a missing file, a wrong size, a wrong hash, a listed file that is a link or folder, a file inside a Core ML bundle that the table does not list, and anything it cannot inspect or list, such as a folder it may not open or a bundle that is a link. A failure to look is a failure of the check. A file outside the bundles, such as FluidAudio's `.fluidaudio-revision` marker, is ignored. The check reads the cached files once and added about 0.3 s to a launch on the Mac mini, measured with the files in memory.
- The app points FluidAudio at the pinned commits, downloads with `ModelHub.download`, which does not load anything, checks the folder, and only then loads it. The vocabulary file comes from the pinned commit as well. After a folder passes, the app writes the revision marker FluidAudio reads, which also adopts a cache that 1.0.0 or 1.0.1 downloaded from the main branch when its files are the pinned ones.
- The CTC folder's `tokenizer.json` is read once, right after the check, and kept in memory. The vocabulary terms are tokenized with that copy and the rescorer gets it too, so no step reads FluidAudio's default cache, which other apps share and fill from the main branch.
- A cache that fails the check is deleted and downloaded once more. If the new download fails the check too, the bar shows the first file that differs, and Retry Loading the Model tries again. A download that stopped halfway is kept and resumed instead: files not yet fetched, and the `.partial` files of those. A listed file that is a link or folder, or a `.partial` file left beside its finished file, is damage and not a late download. FluidAudio skips a file it already has, so the leftover would fail every retry.
- Loading runs in FluidAudio's offline mode, so its own recovery from a failed load, which deletes the folder and downloads again, cannot hand Core ML files that nothing checked.

To move to other model files, change the commits in `scripts/pin-models.py` and run it:

	python3 -I scripts/pin-models.py

The script downloads every file the app reads at those commits, compares each with the hash the Hub publishes, and rewrites `PinnedModels.swift` and `scripts/models.lock`. Review the diff. `scripts/fetch-models.sh` reads `models.lock`, downloads with curl, and checks size and SHA-256. A folder that is already there is checked and never deleted. `MODELS_DIR` replaces FluidAudio's models folder for the script.

The self-test and the bench never download or delete. They stop with the files that fail the check. `--models DIR` runs them on another models folder, such as a copy, and `scripts/e2e.sh` passes `MODELS_DIR` along. The app writes the revision marker into the folder it checks, so use a copy to keep a cache untouched.

## Test

- `scripts/test.sh` runs the DictationCore unit tests with swift-testing. It covers the hotkey state machine, shortcuts and their recording, the cleanup rules, aliases, punctuation repair after boosting, the clipboard restore, the paste-or-copy decision, the vocabulary parser and writer, the bar state and its messages, the history numbers and captions, smart spacing, profile styles, snippets, the Press Return checks, the password apps never read, learning from fixes, the mute marker, the auto level, and reading Willow's transcripts and settings from small sample files. It fails first if `DictationCore/Sources` imports AppKit, AVFoundation, CoreGraphics, or FluidAudio, so the tests never build FluidAudio.
- `scripts/e2e.sh` tests the built app binary. It runs `--self-test`, then `--bench` over `bench/clips/*.wav`, and scores the results against the bakeoff that chose the engine. It fails if a dictation errors, if vocabulary hits fall below 18 of 20, or if the word error rate on the synthetic clips rises above 3.2%. The bench runs live previews while the simulated key is held, as the app does. The environment variables `ROUNDS`, `HOLD_CAP`, `GAP`, `WARM`, and `PREVIEW` change the bench settings. `bench/make_clips.py` makes the clips. It reads `bench/manifest.jsonl` aloud with the macOS voice Samantha, and it also cuts real clips from a recording listed in `bench/real.json` when that file exists. `bench/real.json` and the recording stay out of the repo.

The app binary has six headless modes. Both scripts use the first two:

	"dist/Lip Service.app/Contents/MacOS/Dictation" --self-test
	"dist/Lip Service.app/Contents/MacOS/Dictation" --bench --rounds 3 --hold-cap 15 bench/clips/*.wav
	"dist/Lip Service.app/Contents/MacOS/Dictation" --list-inputs
	"dist/Lip Service.app/Contents/MacOS/Dictation" --render-bar /tmp/bar
	"dist/Lip Service.app/Contents/MacOS/Dictation" --render-window /tmp/window
	"dist/Lip Service.app/Contents/MacOS/Dictation" --import-willow-dry-run FOLDER

`--render-window` draws every page of the window with sample history, settings, vocabulary, and microphones, and the Dictionary page once more with the vocabulary a new user starts with, to PNG files in the folder. It works over SSH and leaves your settings, history, and vocabulary file alone. `--import-willow-dry-run` is described in the Import from Willow section.

`--self-test` loads the models the way the app does and transcribes `selftest.wav` from the bundle. The clip says "Profit Pilot" and "Bee hive" the way the engine mishears them, so the test exits 1 unless ProfitPilot, Beehiiv, and Friday reach the final text. `--bench` simulates a key press, plays the clip in real time to the live previews, releases after the clip's length or `--hold-cap` seconds, whichever is shorter, and prints one JSON line per clip and round. With a hold cap shorter than the clip, the part before it counts as already captured at the press. `--preview off` skips the previews. Both modes use the 13 terms the bakeoff measured, `Vocabulary.bakeoff`, not your vocabulary file. `--bench --vocabulary PATH` reads the terms from a file instead. Both modes stop with `models missing: run scripts/fetch-models.sh` when the models are not cached, and with the first file that differs when a cached model fails the check. `--self-test --allow-download` downloads them instead. Use it only in a GUI session.

`--list-inputs` prints each audio input's name and UID, then the system default. `--mic-start` starts and stops the microphone as a dictation does, with the saved choice or `--microphone automatic`, `default`, or a UID, and prints one JSON line per round: `ready` is the seconds from the start to the first recorded sample, and `lost` is the part of the hold that was not recorded, at the start and at the release. It needs the Microphone permission, so run the app bundle through `open`, as in `open -n -W --stdout out.jsonl "Lip Service.app" --args --mic-start --rounds 10`. `--render-bar DIR` draws every state of the bar, in every position, with the app's own views on a stand-in screen, and writes a PNG of each and a close-up into DIR. It needs a user logged in to the Mac's desktop. An SSH session to that Mac works.

Two scripts regenerate test inputs. `scripts/make-cleanup-fixtures.sh` runs `bench/cleanup-inputs.txt` through `bench/cleanup.py`, the Python cleanup that the bakeoff measured, and writes the expected outputs as a Swift test fixture. `bench/cleanup.py` can also send text to a small model for the bakeoff's comparisons. That call needs `ANTHROPIC_API_KEY` for the Anthropic Messages API, and `CLEANUP_ENDPOINT` points it at another server with the same API. The fixtures need neither. `scripts/make-selftest-clip.sh` rebuilds `Resources/selftest.wav` with `say`.

Two more regenerate the app's resources. `scripts/make-icon.sh` builds `Resources/AppIcon.icns` from `Resources/AppIcon-1024.png` with `sips` and `iconutil`. `scripts/make-sounds.py Resources` writes the three cues, `start.wav`, `stop.wav`, and `cancel.wav`.

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
