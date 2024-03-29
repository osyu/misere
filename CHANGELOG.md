# Changelog

## 0.3.0 (2023-04-21)

- Add zone shrinking to improve game balance
  - Zones will now shrink constantly instead of staying at their max radius until round end
  - The larger the zone, the faster it shrinks, and vice versa
  - Shrink speed is doubled when the zone's team is carrying the ball
- Force overtime to always occur regardless of goals scored
- Increase round time to 10 minutes
- Flash the carrier's screen when they are leaving the zone
- Add a white outline to the carrier
- Block the interception condition from being applied to players
- Suppress crowd reaction sounds when the ball is intercepted or stolen
- Improve joinclass check to allow players to queue a class change while still preventing them from suiciding near the ball
- Prevent respawning due to loadout changes while players are near the ball

## 0.2.0 (2022-12-08)

- Allow jumper weapons to inflict knockback on enemies
- Add custom server tag for the gamemode
- Switch to building against SlidyBat's SendProxy Manager fork
- Various minor improvements

## 0.1.0 (2022-08-13)

- Initial release
