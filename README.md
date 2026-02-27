# SWAG - Set Wear And Go

A simple equipment set manager for World of Warcraft. Save your gear, switch sets, bank your stuff — no bloat, no fuss.

## Features

- **Save Sets** — Snapshot your currently equipped items as a named set
- **Equip Sets** — Switch to any saved set with one click or command
- **Undress** — Unequip all items to your bags
- **Bank Storage** — Store a set's items in your bank or load them back
- **Rename & Delete** — Manage your sets easily
- **Auto Icons** — Sets automatically get an icon from your chest or weapon
- **Minimap Button** — Quick toggle for the main panel
- **Slash Commands** — Full command-line control for macros and keybinds
- **Debug Mode** — Toggleable debug logging for troubleshooting

## Installation

1. Download or clone this repository
2. Copy the `SWAG` folder into your WoW AddOns directory:
   - **Windows:** `World of Warcraft\_classic_\Interface\AddOns\`
   - **macOS:** `World of Warcraft/_classic_/Interface/AddOns/`
3. Restart WoW or type `/reload` in-game

## Usage

### Slash Commands

| Command | Description |
|---------|-------------|
| `/swag` | Toggle the main panel |
| `/swag save <name>` | Save current gear as a named set |
| `/swag wear <name>` | Equip a saved set |
| `/swag delete <name>` | Delete a set |
| `/swag rename <old> \| <new>` | Rename a set |
| `/swag list` | List all saved sets in chat |
| `/swag undress` | Unequip all items to bags |
| `/swag bank <name>` | Store set items in bank (bank must be open) |
| `/swag load <name>` | Load set items from bank (bank must be open) |
| `/swag minimap` | Toggle minimap button |
| `/swag settings` | Open settings panel |
| `/swag help` | Show help panel |
| `/swag debug` | Toggle debug mode |

### Macros

Create macros for quick set switching:

```
/swag wear PvP
```

```
/swag wear Healing
```

```
/swag undress
```

### Panel

- Enter a set name and click **Save** to save your current gear
- Click **Wear** to equip a set
- Click **X** to delete a set (with confirmation)
- **Right-click** a set to rename it
- **Left-click** a set to select it for bank operations
- Use **Store** / **Load** buttons at the bottom for bank operations (bank must be open)
- Click **Undress** to unequip everything to your bags

## Settings

Access settings via `/swag settings` or right-click the minimap button:

- **Chat Messages** — Show/hide action messages in chat
- **Minimap Button** — Show/hide the minimap button
- **Debug Mode** — Enable debug logging

## Compatibility

- **Interface:** 20505 (TBC Classic / Anniversary Edition)
- **Dependencies:** None

## Author

Developed by **goosefraba** (Bernhard Keprt)

## License

[GPL-3.0](LICENSE)
