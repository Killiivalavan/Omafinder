# Omafinder — Transient Filesystem Navigator for Omarchy

A minimal, keyboard-first filesystem navigator for Omarchy.

**Summon → locate / navigate → act → disappear.**

Unlike a traditional file manager, Omafinder exists only for the duration of the interaction. Press `Super+E`, find or browse to what you need, open it, and the overlay is gone.

Inspired by the Omarchy Transient Filesystem Navigator spec.

---

## Philosophy

* Temporary layer, not an application window
* Navigation **and** search are one interaction
* Fuzzy **path** search (not content search)
* No silent ignore lists — `.git`, `node_modules`, `.env` are discoverable
* Deterministic, no AI, no content indexing
* Remembers `lastDir` + frecency for ranking, but UI stays minimal

---

## Features (v0.1)

* **Overlay:** centered ~620px, dark Omarchy-native (uses `Color.menu.*`, `Style.*`), 130ms in / 80ms out
* **Summon:** `Super+E` (configurable via `hypr/bindings.lua`)
* **Input:** type to fuzzy-search, type `~/` or `/` for direct path completion
* **Browse:** empty input lists current dir, `Enter` on dir → navigate, `Enter` on file → `xdg-open` + dismiss
* **Parent:** `Backspace` on empty filter → parent, `Alt+Backspace` always parent
* **Dismiss:** `Esc` (clears filter first, then dismisses)
* **Mouse:** click, scroll, hover all work, but keyboard is fastest
* **Hidden toggle:** `Ctrl+H` / `Ctrl+.` (persists)
* **Search scope:** defaults to `$HOME` (covers all user files), direct absolute paths work for `/etc` etc.
* **Remember:** `~/.local/state/omarchy/omafinder/state.json` stores `currentDir` + frecency
* **Frecency:** visited files/dirs ranked higher in search, but no visible “recent” dashboard
* **Performance:** on-demand `fd` index (80k cap, `find` fallback), cached, debounced; `ls` for browsing

### Secondary actions (included)

Secondary, and still transient — the overlay goes away once the task is done, except copy/cut which keep the overlay open (jumping to `~` so the paste can follow immediately):

* `Ctrl+C` — Copy file (`wl-copy` uri-list / `xclip` fallback) → stays open, jumps to `~` for a quick `Ctrl+V` paste
* `Ctrl+X` — Cut file → stays open, jumps to `~` for paste
* `Ctrl+V` — Paste copied/cut item into the current folder (`gio` / `cp` fallback)
* `Ctrl+Shift+C` — Copy absolute path (`wl-copy` / `xclip` fallback)
* `Ctrl+D` — Trash with confirm dialog (`gio trash`); `Delete` routes through the same confirm
* `F2` — Rename selected file/folder (inline dialog, `Enter` confirms, `Esc` cancels, conflicts error in dialog)
* `Ctrl+T` — Terminal here (`xdg-terminal-exec --dir` → `foot`/`alacritty`/`kitty`/`ghostty` fallback); folder → that folder, file → its directory
* `Ctrl+Shift+O` — Open With… (mime-filtered app list)
* `Ctrl+O` — Reveal in file manager (`nautilus --select` or `xdg-open`)
* `Ctrl+N` — Create folder (“New Folder” with dedup)
* `Enter` on dir → navigate, `Enter` on file → open via `xdg-open` + dismiss
* `F1` / `Ctrl+/` — Keybindings help popup (lists every binding)

---

## Install

### As Omarchy plugin (recommended)

```bash
omarchy plugin add https://github.com/<you>/omafinder.git --enable
# or locally
omarchy plugin add file:///home/bashman/Code/omafinder --enable
```

Then add the keybind to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + E", "Omafinder", "omarchy-shell shell toggle omafinder")
hyprctl reload
```

Already enabled in this dev checkout: `~/.config/omarchy/plugins/omafinder` + `shell.json` entry + `hypr/bindings.lua`.

### Manual

```bash
mkdir -p ~/.config/omarchy/plugins
cp -r omafinder ~/.config/omarchy/plugins/
omarchy-shell shell rescanPlugins
omarchy-shell shell enablePlugin 'omafinder' '{}'
```

Validate:

```bash
omarchy plugin validate ~/.config/omarchy/plugins/omafinder
omarchy-shell shell listPlugins | jq '.[] | select(.id=="omafinder")'
omarchy-shell shell summon omafinder '{}'  # should return ok
```

---

## Usage

* `Super+E` → overlay appears, focus is on input
* Type `document` → fuzzy results:
  ```
  document_service.py   ~/projects/DMS/backend/services/
  Document.tsx          ~/projects/Musicboxd/src/components/
  document.pdf          ~/backup/old/DMS/
  ```
* `↑/↓` or `j/k` style, `Enter` → file opens + overlay gone, or dir entered
* Type `~/projects` + `Enter` → jump directly
* `Backspace` (empty) → parent
* `Esc` → dismiss
* `Ctrl+H` → toggle hidden files
* `F2` → rename selected item · `F1`/`Ctrl+/` → help popup
* Hints shown in a persistent footer (`F1 / Ctrl+/ help` entry)

### Path examples

* `~/projects/DMS` → navigates there
* `~/projects/DMS/backend/app.py` → opens file
* `/etc/hosts` → opens file

---

## Configuration

Currently minimal — edit `~/.config/omarchy/shell.json` plugin entry or state file:

* `showHidden` persisted in `~/.local/state/omarchy/omafinder/state.json` and toggled live with `Ctrl+H`
* `currentDir` remembered there as well
* For keybind, edit `~/.config/hypr/bindings.lua` before `require("default.hypr.omarchy")` or just in that file (already done)

Future: `searchRoot`, `width`, `maxResults` via `shell.json` `plugins[]` entry (same pattern as other plugins).

---

## Architecture

* `manifest.json` — `kinds: ["overlay"]`, `keepLoaded:true`, `overlay: Omafinder.qml`
* `Omafinder.qml` — `PanelWindow` (Overlay layer, Exclusive focus, Ignore exclusion), `BorderSurface` card, `ListView`, `Process` for `ls`/`fd`/`stat`, `FileView` for state
* `Fuzzy.js` — fzf-inspired scoring (consecutive bonus, slash boundary, filename boost, frecency additive)
* Host: `omarchy-shell` (`/usr/share/omarchy/shell/shell.qml`) — `summon`/`hide`/`toggle` via `omarchy-shell shell toggle omafinder``

Indexing: first summon builds `fd -H -a --type f --type d . $HOME | head -n 80000` cache (`globalPaths` in memory). Subsequent keys filter in JS (no rescan). Browse uses `ls -1 -p --group-directories-first` per dir.

---

## Development

The live plugin lives at `~/.config/omarchy/plugins/omafinder/` (watched by `inotifywait` auto-reload). The publishable repo is at `~/Code/omafinder/` (this folder).

Sync after changes:

```bash
cp ~/Code/omafinder/* ~/.config/omarchy/plugins/omafinder/   # repo → live
# or
cp ~/.config/omarchy/plugins/omafinder/* ~/Code/omafinder/  # live → repo
omarchy plugin validate ~/Code/omafinder
omarchy-shell shell summon omafinder '{}' # smoke test
```

Logs:

```bash
journalctl --user --no-pager -n 100 | grep omafinder
omarchy-shell shell ping
hyprctl binds | grep -i omafinder
```

---

## Roadmap

* [ ] Config via `shell.json` (`searchRoot`, `width`, `frecency` weight)
* [ ] Context menu for secondary actions (right-click)
* [x] Create/rename inline
* [x] Clipboard copy/cut/paste file ops (`wl-copy` uri-list, `gio` move)
* [ ] File preview for text/images (opt-in)
* [ ] Keep frecency in separate file for easier backup

---

## License

MIT — see `LICENSE`.

## Credits

Built for Omarchy shell (Quickshell). Uses `fd`/`find`, `ls`, `xdg-open`, `wl-copy`, `gio`.
