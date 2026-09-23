# 4-Finger Overview for Omarchy

A workspace overview for [Omarchy](https://omarchy.org/), opened with a 4-finger swipe up on the trackpad, similar to Mission Control on macOS.

It shows only the workspaces on the **focused monitor** that hold at least one window, each drawn as a scaled-down copy of the monitor with live previews of its windows. Empty workspaces and workspaces on other monitors are left out.

It runs as an overlay plugin inside the Omarchy shell (Quickshell), so it picks up your theme's menu colors and font and needs no extra process.

## Requirements

- Omarchy with the Quickshell-based shell (`omarchy-shell`)
- Hyprland 0.55 or later (Lua config)

## Install

```bash
omarchy plugin add https://github.com/ChrisTeceno/omarchy-4-finger-overview --enable
```

Then add the gestures to `~/.config/hypr/input.lua`:

```lua
-- 3- and 4-finger horizontal swipes switch workspaces.
hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })
hl.gesture({ fingers = 4, direction = "horizontal", action = "workspace" })

-- 4-finger swipe up opens the overview, down closes it.
hl.gesture({ fingers = 4, direction = "up", action = function() hl.exec_cmd("omarchy-shell shell summon christeceno.4-finger-overview '{}'") end })
hl.gesture({ fingers = 4, direction = "down", action = function() hl.exec_cmd("omarchy-shell shell hide christeceno.4-finger-overview") end })
```

Hyprland reloads the file on save. Check for mistakes with `hyprctl configerrors`.

To open it from the keyboard instead, bind a key in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + TAB", "Overview", "omarchy-shell shell toggle christeceno.4-finger-overview")
```

(SUPER+TAB is taken by default in Omarchy; call `hl.unbind("SUPER + TAB")` first if you want it.)

## Usage

| Input | Action |
| --- | --- |
| 4-finger swipe up | Open |
| 4-finger swipe down, Esc, click the background | Close |
| Click a workspace | Switch to it |
| Click a window | Focus that window |
| Arrow keys, h/j/k/l, Tab | Move the selection |
| Enter | Switch to the selected workspace |

The current workspace's label is bold, and the selected workspace has an accent border.

## Update and remove

```bash
omarchy plugin update christeceno.4-finger-overview
omarchy plugin remove christeceno.4-finger-overview
```

Remove the gesture lines from `input.lua` as well when uninstalling.

## Notes

- Only regular workspaces are shown. Special workspaces (such as the scratchpad) are skipped.
- Window positions come from `hyprctl` when the overview opens; previews then update live while it stays open.
- Tested on a single monitor so far. Multi-monitor reports are welcome.

## License

MIT
