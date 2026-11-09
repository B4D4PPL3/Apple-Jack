# Apple Jack

**A customizable desktop companion for macOS with AI chat and everyday Mac tools.**

Choose Apple Jack or Fonz, or bring a pet you designed in ChatGPT. Click your companion to chat with ChatGPT in its speech bubble, pause your music, or find a link you copied earlier. To move a file between windows, drop it onto your companion, switch windows, and drag it out where you need it.

![Apple Jack stands with crossed arms beneath the new Classic header logo, Music controls, and a sample playlist conversation.](Docs/Screenshots/desktop.jpg)

**[Download the 0.54 preview](https://github.com/B4D4PPL3/Apple-Jack/releases/tag/v0.54-preview.1)** · macOS 13 or later · Apple silicon and Intel · [Installation instructions](#install)

## Feature gallery

### ChatGPT and custom pets

**Bring your own character.** Choose **Menu → Appearance & Character → Pets** to see Apple Jack, Fonz, and your imported characters. Select a character to preview it, then click **Use Pet**. **Import ChatGPT Pet…** lets you browse your ChatGPT companions or choose a PNG or WebP sprite sheet. Turn on **Automatically Import All ChatGPT Pets** on the Pets page to keep your collection up to date.

![ChatGPT companions. The Pets page shows Fonz selected, his sprite preview, and the Import ChatGPT Pet and Use Pet buttons.](Docs/Screenshots/chatgpt-pets.jpg)

**Chat in your pet’s speech bubble.** On a Mac that supports Apple Intelligence with ChatGPT enabled, open **Menu → Shortcuts → Set Up Shortcuts…** and add **Ask Apple Jack (ChatGPT)**. If it says **Already Added**, you’re ready to use it. Then choose **Menu → AI Assistant → ChatGPT**, click your pet, and type a question or use **Speak to Jack**. You can use ChatGPT with any character, and you can use your custom pet with any of Jack’s assistants.

### Hold This and clipboard history

Drop a file, image, link, or note onto your companion. You can also select a recent copy in **Clipboard** and click **Hold This** to put it on the shelf. The item keeps its original type, and your current clipboard stays available to paste.

![The Clipboard page shows a selected cover image, the Hold This button and the confirmation “Added to Hold This.”](Docs/Screenshots/clipboard.jpg)

Select a shelf thumbnail and press **Space** to preview it in Jack’s bubble.

![A waving Apple Jack below the Hold This shelf, with an album cover selected beside a link and a note.](Docs/Screenshots/hold-this.jpg)

Press **Space** again to return from a file, image, or text preview. For an interactive website, use **Back** to return or **Open in Browser** to continue in your default browser.

![Hold This Preview displays the selected Orchard Sessions cover artwork at full size inside the bubble, with Back in the upper left.](Docs/Screenshots/held-preview.jpg)

### Favorites

Right-click a held thumbnail and choose **Add to Favorites**. Open the **Favorites** menu to find apps, folders, websites, shortcuts, and other items by category. **Manage Favorites…** accepts drops from Finder and lets you drag entries into order. Choosing a saved document or image from **Items** reveals it in Finder.

![The Hold This context menu offers Add to Favorites. Beside it, Manage Favorites shows the saved music link alongside an app and a shortcut.](Docs/Screenshots/favorites.jpg)

### Websites inside Jack or in your browser

Type `open example.com` to browse the site inside Jack. The web page receives normal keyboard input, including Space and Return.

![Typing open example.com displays the site in Website Preview, with Back at the upper left and Open in Browser above the page.](Docs/Screenshots/website-preview.jpg)

Type just `example.com` to use your Mac’s default browser. Jack names the browser that opened it. The same input field accepts app names, Finder paths, and `run shortcut` followed by an installed shortcut’s name.

![The bare address example.com appears in the input field and Jack confirms “Opened example.com in Safari.”](Docs/Screenshots/default-browser.jpg)

### Now Playing

Jack matches the previous, play/pause, and next buttons to the waveform color of the active player. The examples show Music and Chrome. When the bubble is closed, the waveform above your companion uses the same color.

![Two Now Playing views of the same sample track. Previous, play/pause, next, and the waveform are pink for Music and yellow for Chrome.](Docs/Screenshots/media-sources.jpg)

### Conversation history

Open **History** to revisit a reply or switch assistants. Clipboard history, pet selection, settings, the Setup Guide, and conversation history all open inside the speech bubble. Use **Back** in the upper-left corner to return to your draft.

![Conversation History appears inside the bubble with a Back button, an assistant picker, and two sample questions and replies.](Docs/Screenshots/conversation.jpg)

## Install

Apple Jack 0.54 is available as an **unnotarized preview** for macOS Ventura 13 or newer on Intel and Apple silicon.

1. Download `Apple-Jack-0.54-preview-macOS.dmg` under **Assets** on the [Apple Jack 0.54 preview release](https://github.com/B4D4PPL3/Apple-Jack/releases/tag/v0.54-preview.1).
2. Open the disk image, drag **Apple Jack Public** into **Applications**, and open it from there.
3. If macOS says it cannot verify the developer and you trust this download, open **System Settings → Privacy & Security** and choose **Open Anyway** for Apple Jack Public. [Apple’s first-launch instructions](https://support.apple.com/en-us/102445)

To update from an earlier public preview, quit Apple Jack Public and replace the previous copy in Applications. The illustrated Setup Guide is available from Jack’s menu. This preview uses manual updates. [Check GitHub Releases for updates](https://github.com/B4D4PPL3/Apple-Jack/releases).

Apple Intelligence features require a supported Mac and macOS version. Jack can also use a text-in, text-out shortcut or a separately installed, signed-in Codex CLI. For Claude, open **Menu → AI Assistant → Claude Code Setup…**, sign in through Claude Code with an eligible account, and choose **Claude (Beta)**. Replies appear in Jack’s bubble using your Claude Code account. Local desktop features work without an AI account.

## Build from source

Use Python 3.9 or newer and Apple's Command Line Tools or Xcode with a current macOS SDK. From the repository root run

```sh
python3 Scripts/build.py
open "build/Apple Jack Public.app"
```

To build a local test disk image, run `python3 Scripts/package.py`. The image and its SHA-256 checksum appear in `dist/local/`. Local builds use ad-hoc signing. The verified distribution process is documented in [RELEASING.md](RELEASING.md).

## Check the public updater

The release tests use a simulated HTTPS response and a temporary disk image fixture. Run them after building.

```sh
xcrun swiftc -parse-as-library Sources/UpdateRelease.swift Sources/GitHubUpdates.swift Tests/PublicUpdates.swift -o build/PublicUpdatesTests
build/PublicUpdatesTests
```

## Data and permissions

Favorites, imported pets, held items, and clipboard history live under `~/Library/Application Support/Apple Jack Public/`. Conversation memory, when enabled, lasts for the current session. Clipboard history can be paused or cleared. Dictation requests microphone and speech access. Revealing a playing Safari tab can request Automation permission. Choosing an AI backend sends the request and enabled conversation context to that backend. Pet discovery uses installed pet folders and can request pets from the signed-in ChatGPT account. The public updater contacts GitHub.

## Licenses

Original code and documentation use the [MIT license](LICENSE). The bundled characters and app icon have [separate artwork terms](ARTWORK.md). MediaRemoteAdapter ships under [BSD-3-Clause](ThirdParty/MediaRemoteAdapter/LICENSE). It uses macOS private media APIs, so Now Playing availability can vary by player and OS version.
