# Changelog

## [0.3.0] - 2026-07-09

### Compatibility
- Updated for TBC Classic 2.5.6 (Interface 20506).

### Added
- **Per-character sets.** Sets are now saved separately for each character.
  By default you only see the sets belonging to the character you're logged in on
  (so your shaman no longer shows your paladin's sets).
- **Character selector** at the top of the panel: switch the view to any character
  that has SWAG sets. All actions (Save, Wear, Delete, reorder, bank) operate on the
  character you're currently viewing ("follow the view"). Your own character is
  marked "(you)" and listed first; names are class-coloured.
- Item tooltips now list matching sets across **all** your characters — sets on
  other characters are tagged with that character's name.

### Changed
- **SavedVariables schema migrated.** Existing account-wide sets are automatically
  moved into the character you're logged in on the first time you run 0.3.0. No
  action needed; your sets are preserved. (Old `SWAGDB.sets` / `SWAGDB.setOrder`
  are replaced by `SWAGDB.chars[<Name-Realm>].sets` / `.setOrder`.)

## [0.2.1] - 2026-06-01

### Fixed
- **Item tooltips now show which sets an item belongs to again.** The 0.1.1
  tooltip refactor routed through the modern `TooltipDataProcessor` API but still
  read the item link the old way, so the "[SWAG]" line silently stopped appearing
  on clients that have the new API. It now reads `data.hyperlink` (modern) with a
  fallback to `GetItem` (legacy).

### Added
- **Mouse-wheel scrolling in the set list.** The list already had a draggable
  scrollbar; the wheel now scrolls one set per notch while hovering the list or any
  row, so lists longer than 8 sets are easy to navigate.

## [0.2.0] - 2026-06-01

### Added
- **Drag-and-drop reordering of the saved-set list.** Drag a row up or down to
  change its order; a ghost follows the cursor and an insertion line shows where it
  will land. Long lists auto-scroll when you hold near the top/bottom edge. The order
  is saved (in `db.setOrder`) and persists across sessions.

## [0.1.1] - 2026-05-31

### Fixed
- **Equip set no longer falsely reports items as "Missing"** when the wanted item
  is already worn in a sibling slot (e.g. a ring on the other finger, off-hand vs.
  main-hand, trinket 1 vs. trinket 2). Such items are now swapped into place via an
  inventory-to-inventory swap instead of being skipped.
- **"Created" timestamp is preserved when updating a set.** Re-saving a set no
  longer resets its creation date; a separate "Updated" time is now tracked and
  shown in the set tooltip.
- **Bank Store/Load now stops cleanly when out of space.** Storing to a full bank
  (or loading into full bags) warns and reports how many items moved instead of
  silently dropping the rest.
- `EquipSet` now clears the cursor before starting, so a held item/spell can't
  interfere with the first equip.

### Changed
- Item tooltip "belongs to set" integration and the settings panel now prefer the
  modern `TooltipDataProcessor` / `Settings.*` APIs when available, falling back to
  the legacy TBC 2.5.x APIs. No behavioural change on Anniversary today; future-proofs
  against client updates.

### Removed
- Dead code cleanup (unused locals).

## [0.1.0] - 2026-02-27

### Added
- Save current equipped items as a named set
- Equip saved sets via UI or slash commands
- Delete and rename sets
- Auto-assigned set icons from chest piece or weapon
- Undress (unequip all items to bags)
- Bank storage: store set items in bank
- Bank loading: load set items from bank to bags
- Minimap button with drag-to-reposition
- Settings panel (Blizzard Interface Options)
- Help/About panel with command reference
- Full slash command support (`/swag`)
- Debug mode with toggleable logging
- Chat messages for all actions
