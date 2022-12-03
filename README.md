# Misère PASS Time

Custom TF2 gamemode based on PASS Time, where the team who moves the JACK furthest from the center loses.

## Overview

- Each team has a team-colored sphere called the "zone", whose radius represents the furthest distance from the center of the map that any team member has stood while carrying the JACK. There is no way to decrease the zone's size. The team with the smallest zone at the end of the round wins.
- The goal is to force the enemy team to inadvertently expand their zone. This is done mainly by throwing the JACK at enemies while they are standing outside of the zone, or using knockback (e.g. airblast) to push out an enemy who is currently holding the JACK.
- Standard PASS Time goals can still be scored, but they only serve to expedite the end of the round; the winner is still the team with the smallest zone. Normal overtime rules also still apply (overtime only occurs if both teams have equal goals).
- Suiciding by using the `kill`/`explode` commands or changing class is blocked while near (or carrying) the JACK. Friendly fire is enabled to allow teammates to kill each other as means to avoid the JACK.
- To keep players from hiding in spawn, teams can open each other's spawn doors and the JACK can be carried into spawn areas. Players are given 8 seconds of spawn protection, during which they cannot carry the JACK.
- Using jumper weapons or taunting no longer prevents players from carrying the JACK. Other conditions still do, though (e.g. uber, hauling a building).

## Installation

This plugin requires SourceMod 1.11+ and [SendProxy Manager](https://github.com/SlidyBat/sendproxy).

1. Download `misere.zip` from the [latest release](https://github.com/osyu/misere/releases/latest).
2. Extract it and copy all folders into `tf/` on your gameserver.
3. If you're using FastDL, copy the `models` folder there too.
4. Load the plugin or restart your server.

The plugin only affects PASS Time maps.
