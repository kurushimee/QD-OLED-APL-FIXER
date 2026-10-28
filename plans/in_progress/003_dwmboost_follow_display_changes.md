---
id: 003
title: DwmBoost follows display changes
status: in_progress
created: 2026-10-29
updated: 2026-10-29
---

# DwmBoost follows display changes

The tray host picks its target monitor once at startup, so after the user toggles HDR, changes the resolution or refresh rate, or plugs in or removes a monitor, the hook keeps matching a stale swapchain size or keeps boosting a monitor that's no longer in HDR. The host should pick the target again on every display change

## Facts

- Windows sends `WM_DISPLAYCHANGE` to every top-level window when the desktop mode changes, which covers resolution, refresh rate and monitors coming and going. The host's hidden tray window is top-level, so it gets the message
- Microsoft's Advanced Color guide says Win32 apps have no native notification for Advanced Color changes and tells them to poll `IDXGIFactory1::IsCurrent`. An HDR toggle alone isn't documented to send `WM_DISPLAYCHANGE`, so the host also reruns the target search on its 2 second heartbeat timer. The search is one `QueryDisplayConfig` call plus a device info query per path, and it only acts when the result differs from the current target
- The target stays the first monitor with HDR on and is never matched by EDID name or model, since every third generation QD-OLED TB400 panel in its 1000 nit mode measures close to `abl_curve.csv`
- The settle and content events are named after the target's origin. When the origin moves, the host recreates them under the new name, and the hook closes the handles it opened under the old one and opens the new ones
- With no HDR monitor left the host writes `enabled = 0`, and the hook's watcher thread reverts the flip patch through the same path as a manual disable. The user's on or off choice is kept apart from that, so the boost comes back on when an HDR monitor returns only if the user had it on
- The host bumps `resetGeneration` on every target change, so the gain history restarts on the new mode
- The host now starts without an HDR monitor and waits for one, since at logon the autostart task can run before HDR comes up

## Phase 1: host and hook

Done when the host follows display changes and DwmBoost builds

- [x] Keep the user's on or off choice apart from the written `enabled` flag
- [x] Rerun the target search on `WM_DISPLAYCHANGE` and on the heartbeat timer, and on a change stop the kicker, recreate the events, rewrite the config with a history reset and restart the kicker
- [x] Start without an HDR monitor and show it in the tray tooltip
- [x] Reopen the hook's events when the target origin moves
- [x] Build DwmBoost

## Phase 2: verification and docs

Done when the parity check passes and the README describes the behavior

- [x] Run `parity_check.py`
- [x] Say in the README's DwmBoost section that the target follows display changes

## Phase 3: live check

Done when the boost follows each change on a real desktop

- [ ] With DwmBoost running, toggle HDR off and on, change the resolution and the refresh rate, and unplug and replug a monitor, and check the tray tooltip and the boost after each
