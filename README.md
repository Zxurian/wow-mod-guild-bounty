# Guild Bounty

A **World of Warcraft: Forever** addon that keeps a shared **Guild Bounty Board** of enemy players who PvP-kill your guildmates.

## Install
Copy the `GuildBounty` folder into `World of Warcraft/_forever_/Interface/AddOns/` and restart the game or `/reload`.
Every guild member who wants to share the board needs the addon installed.

## How it works
- **You die to an enemy player:** you see how many times that player has killed you.
  - If they are **not** on the board, a popup asks whether to add them. Choosing **Yes** adds them along with every kill they've made on you.
  - If they **are** on the board, the kill is added automatically and an alert tells you that a bounty target killed you.
- **A guildmate kills a bounty target:** every online guildmate sees an alert, and the target's row shows who slew them.
- **Kill log:** every kill is logged with its date and both players' levels at the time, for example `2026-11-13 21:04  Zug (60) killed Bob (58)`. Hover a board row to see the 5 most recent kills, or click it to open that player's full history. When you add someone, each of your earlier deaths to them is logged with its original date and levels.
- **Minimap button:** left-click opens the board (top 10 by kills on guild members; hover a row for victims, slayers and recent kills). Right-click opens the options. Drag the button to move it around the minimap.
- **Options:** board lock, scale and position; alert position (Move alert); sound on/off and choice; minimap button and chat toggles; manual sync; reset all data.

## Sync (swarm, no hub)
Sync uses **hidden addon messages** sent to the guild (`C_ChatInfo.SendAddonMessage(..., "GUILD")`). Nothing is posted to guild chat or shown to anyone; only clients running this addon see the traffic.

Every client is an equal peer. Logs are compared top-down, so only what actually differs is ever sent:

1. **Overall fingerprint (1 message).** Sent on login (after a random 5–30 s delay), on `/gb sync`, and about every 10 minutes. If it matches, nothing else happens.
2. **Month fingerprints (32-day blocks), then day fingerprints** inside months that differ.
3. **Per-kill fingerprints** for days that differ (5 characters each, about 40 per message). Then only the missing kills are sent.
4. **Claims.** Before sending a day or month of kills, a peer broadcasts a tiny "I've got this" message, and everyone else skips it. Which peer goes first depends on a hash of (peer, day), so different days go to different peers. The work, and each client's separate send budget, is spread across everyone online. Peers with a long send queue back off.
5. **Compact records.** About 45 bytes each (4–5 per message): the home realm is omitted, numbers are in base 36, and class is a one-letter code.

Messages are discarded unless the guild name matches yours and the sender is in your guild roster. Every kill has a unique ID, so the same kill is never counted twice.

Estimates for a 50-member guild with about 10,000 kills a year, assuming roughly 1 message per second per client:
- **Logging in with a matching board:** 1 message.
- **Back after a week, 100 kills missed:** about 30–60 messages.
- **New member with an empty board:** about 2,200 messages in total, split across everyone online. That's about 4 minutes with 10 peers online, and longer with fewer.
- **Applying synced kills:** incremental per kill, with the board redrawn at most twice a second.

## Slash commands
`/gb` (or `/bounty`) toggles the board. `/gb config` opens the options. `/gb sync` broadcasts your digest now. `/gb minimap` shows or hides the minimap button.

## How detection works on Forever
Forever applies Midnight's addon restrictions: addons can't read the combat log, and some unit data comes back as unreadable "secret" values.
- **Deaths:** after you die, the addon reads Blizzard's Death Recap and takes the killing blow's source.
  - If the recap includes a GUID, only player GUIDs count.
  - If it doesn't, the killer counts only if they're a hostile player you've seen on a nameplate, target or mouseover, a known killer, already on the board, or cross-realm.
- **Kills:** a kill counts when you get an honorable-kill message, or when a bounty target in your target or focus dies while you're in combat.
  - The game doesn't expose who landed the killing blow, so everyone who took part gets credit.
  - When several guildmates report the same kill within 20 seconds, it counts as one death and they are all listed as slayers.
