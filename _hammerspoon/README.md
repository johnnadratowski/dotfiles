# Hammerspoon Configuration

Personal Hammerspoon configuration for macOS automation.

## Hotkeys

All hotkeys use the **HYPER** modifier: `Alt + Ctrl + Cmd + Shift`

### System

| Key | Action |
|-----|--------|
| `R` | Reload Hammerspoon config |
| `` ` `` | Toggle Hammerspoon console |
| `H` | Show all hotkeys |

### Applications

| Key | Action |
|-----|--------|
| `Space` | Launch/focus iTerm |
| `Return` | Launch/focus VS Code |
| `Tab` | Launch/focus browser |
| `G` | Open new browser tab (Google) |

### Window Management

| Key | Action |
|-----|--------|
| `Left` | Window left half (cycles: 1/2 -> 1/4 -> 3/4) |
| `Right` | Window right half (cycles: 1/2 -> 3/4 -> 1/4) |
| `Up` | Window top half / full height |
| `Down` | Window bottom half / minimize |
| `M` | Maximize window |
| `1` | Move window to display 1 |
| `2` | Move window to display 2 |
| `3` | Move window to display 3 |

### Clipboard Tools

| Key | Action |
|-----|--------|
| `V` | Force paste (bypasses paste restrictions) |
| `D` | Diff last two clipboard entries |
| `t` | Timestamp to date conversion |
| `s` | Seconds to human-readable duration |
| `b` | Bytes to human-readable file size |
| `n` | Format number with commas and English text |
| `u` | Generate UUID |
| `x` | Escape string (Python) |

### Productivity

| Key | Action |
|-----|--------|
| `J` | Open snippets chooser |
| `K` | Open notes file |
| `L` | Generate Lorem Ipsum text |
| `C` | Color picker |
| `4` | OCR - capture text from screen |
| `p` | Ping network check |
| `Z` | Toggle Dock visibility |

## Menu Bar

- **Caffeine** - Click to toggle display sleep prevention
- **Microphone** - Click to toggle microphone mute

## Modules

- `alerts.lua` - Alert notification system
- `applications.lua` - App launching and focusing
- `caffiene.lua` - Display sleep toggle
- `colorpicker.lua` - Color picker via AppleScript
- `constants.lua` - Configuration constants
- `dbug.lua` - Debugging utilities
- `dialog.lua` - AppleScript dialogs
- `diff.lua` - Clipboard diff tool
- `escape.lua` - String escaping
- `files.lua` - File utilities
- `fmtnum.lua` - Number formatting
- `humanfilesize.lua` - File size formatting
- `humanseconds.lua` - Duration formatting
- `log.lua` - Logging wrapper
- `mic.lua` - Microphone mute toggle
- `ocr.lua` - OCR text extraction
- `ping.lua` - Network connectivity check
- `snippets.lua` - Snippet manager
- `str.lua` - String utilities
- `timestamp.lua` - Timestamp conversion
- `util.lua` - General utilities
- `uuid.lua` - UUID generation
- `window.lua` - Window management

## Requirements

- [Hammerspoon](https://www.hammerspoon.org/)
- `/opt/homebrew/bin/numfmt` (for file size formatting)
- `~/bin/ocr` (for OCR functionality)
