# Omafinder

A keyboard-first file navigator for quickly finding and managing files in Omarchy.

Omafinder is a transient filesystem navigator built for Omarchy. Summon it, find what you need, perform an action, and get out of the way.

## Features

* **Fuzzy file search** across your home directory
* **Fast directory browsing** with directories grouped first
* **Direct path navigation** with paths such as `~/Documents`, `./foo`, and `../bar`
* **Frecency-based ranking** for paths you use frequently or recently
* **Hidden file support**
* **File operations** without leaving the keyboard:

  * Open
  * Open With
  * Copy
  * Cut
  * Paste
  * Rename
  * New folder
  * Trash
  * Copy absolute path
  * Reveal in file manager
  * Open a terminal here
* Persistent navigation state
* Mouse support when you want it
* No background daemon, database, or network service

## Installation

Install Omafinder through the Omarchy plugin system:

```bash
omarchy plugin add https://github.com/Killiivalavan/Omafinder.git --enable
```

After installation, launch Omafinder from the Omarchy launcher or your configured keybinding.

## Usage

Omafinder is designed around a simple flow:

**Summon → Find → Act → Dismiss**

When opened, Omafinder starts in your last visited directory.

Start typing to search. Short queries search the current directory, while longer queries search your home directory and rank matching paths using fuzzy matching and frecency.

You can also enter a path directly:

```text
~/Downloads
../Projects
./src
/home/user/Documents
```

Press `Enter` to open the selected file or enter the selected directory.

## Keybindings

| Key                     | Action                                      |
| ----------------------- | ------------------------------------------- |
| `↑` / `↓`               | Move selection                              |
| `Page Up` / `Page Down` | Move by 6 results                           |
| `Home` / `End`          | First / last result                         |
| `Enter`                 | Open file or enter directory                |
| `Backspace`             | Go to parent directory when search is empty |
| `Alt+Backspace`         | Go to parent directory                      |
| `←`                     | Go to parent directory when search is empty |
| `Esc`                   | Dismiss                                     |
| `Ctrl+H` / `Ctrl+.`     | Toggle hidden files                         |
| `Ctrl+Shift+H`          | Go to home directory                        |
| `Ctrl+C`                | Copy                                        |
| `Ctrl+X`                | Cut                                         |
| `Ctrl+V`                | Paste                                       |
| `Ctrl+Shift+C`          | Copy absolute path                          |
| `Ctrl+D` / `Delete`     | Trash                                       |
| `F2`                    | Rename                                      |
| `Ctrl+N`                | New folder                                  |
| `Ctrl+T`                | Open terminal here                          |
| `Ctrl+O`                | Reveal in file manager                      |
| `Ctrl+Shift+O`          | Open With                                   |
| `F1` / `Ctrl+/`         | Show help                                   |

## Search

Omafinder searches **file and directory names and paths**, not file contents.

### Current directory

Single-character searches operate on the current directory for quick navigation.

### Home directory

Longer searches use `fd` when available to search your home directory. Results are limited to keep the interface responsive.

If `fd` is unavailable, Omafinder falls back to `find`.

Matches are then ranked locally using a fuzzy matcher that considers things such as:

* Consecutive character matches
* Filename matches
* Path boundaries
* Prefix matches
* Common filename separators
* Shorter paths
* Earlier matches

A query must be fully matchable for a result to be returned.

## Frecency

Omafinder remembers how you use paths and incorporates that information into search ranking.

Frequently and recently used paths receive a ranking boost, making commonly accessed locations easier to reach over time.

State is stored at:

```text
~/.local/state/omarchy/omafinder/state.json
```

The stored state includes navigation state, frecency data, and the hidden-file preference.

## File Operations

Omafinder handles common filesystem actions directly from the overlay.

### Copy and cut

`Ctrl+C` and `Ctrl+X` place the selected file or directory into Omafinder's clipboard state and the system clipboard.

### Paste

`Ctrl+V` pastes the current clipboard contents into the selected directory.

Name conflicts are handled by generating a new name rather than overwriting the existing item.

### Rename and create

`F2` renames the selected item.

`Ctrl+N` creates a new folder. If the default name already exists, Omafinder generates an available alternative.

### Trash

`Ctrl+D` or `Delete` moves an item to the desktop trash using the system's trash mechanism.

Omafinder does **not** fall back to permanently deleting files with `rm`.

### Open With

`Ctrl+Shift+O` opens the selected item using the available desktop applications associated with its MIME type.

### Terminal and file manager

`Ctrl+T` opens a terminal in the current directory.

`Ctrl+O` reveals the selected item in the available file manager.

## Dependencies & Integrations

Omafinder uses standard Linux desktop tools where appropriate, including:

* `fd` for fast filesystem searching, with `find` as a fallback
* `gio` for desktop file operations
* `wl-paste` or `xclip` for clipboard integration
* `xdg-terminal-exec` and common terminal emulators for terminal integration
* Omarchy's application library for desktop application integration where available

The exact tools available on your system may affect which fallback is used.

## Permissions & Safety

Omafinder runs as an Omarchy shell plugin and performs filesystem operations using your normal user permissions.

It can read filesystem paths and perform operations such as copying, moving, renaming, and trashing files because those capabilities are fundamental to its purpose.

It does not require:

* `sudo`
* A background service
* A database
* A network connection
* A separate server

Filesystem operations are performed through standard desktop and filesystem utilities. Paths passed to shell commands are appropriately quoted by the plugin.

## What Omafinder Is Not

Omafinder is intentionally not a replacement for a full file manager.

It focuses on **quick access and common actions** rather than persistent file management.

There is no:

* Two-pane interface
* File preview system
* Content indexing
* Mount manager
* Background filesystem daemon
* Full file-manager navigation interface

If you need those things, a dedicated file manager is still the better tool.

## Development

Clone the repository and work from the plugin directory:

```bash
git clone https://github.com/Killiivalavan/Omafinder.git
cd Omafinder
```

Validate the plugin with:

```bash
omarchy plugin validate .
```

For QML development, `Omafinder.qml` is the main UI and interaction layer, while `Fuzzy.js` contains the fuzzy matching logic.

## License

Omafinder is licensed under the MIT License. See [LICENSE](LICENSE) for details.
