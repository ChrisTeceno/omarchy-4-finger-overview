# 4-Finger Overview for Omarchy

A workspace overview for [Omarchy](https://omarchy.org/), opened with a 4-finger swipe up on the trackpad, similar to Mission Control on macOS.

It shows only the workspaces on the **focused monitor** that hold at least one window, each drawn as a scaled-down copy of the monitor with live previews of its windows. Workspaces on other monitors are left out. A column on the right lists the unused workspaces 1 to 10 as small numbered boxes, plus a "+" box for a new workspace.

Drag a window onto an unused box or "+" to move it there; the box grows around the window as you hover. Drag it onto any workspace, including its own, to place it next to a specific window: the tiled window under the cursor (or the nearest one) is split, and the window goes on the side of it nearest the cursor (left, right, above or below). While you hover, that window slides over and a slot opens where the dragged window will land. A floating window is tiled as it lands. The overview stays open and redraws with the new layout.

Placement uses Hyprland's dwindle layout with `use_active_for_splits` on (the default): on drop the plugin briefly focuses the target window behind the overview, preselects the side, moves the window in, and switches back to the workspace you were on.

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

One window is selected at a time. It starts on the focused window and follows the mouse or the arrow keys; its title shows under its workspace. Typing filters windows by title or app name: matches stay bright, the rest dim, and the arrow keys skip over them.

| Input | Action |
| --- | --- |
| 4-finger swipe up | Open |
| 4-finger swipe down, click the background | Close |
| Esc | Cancel a drag, then clear the search, then close |
| Type | Search windows (Backspace edits) |
| Hover a window | Select it |
| Click a window, or Enter | Focus the selected window |
| Click the empty part of a workspace | Switch to that workspace |
| Click an unused box or "+" | Switch to that workspace, or a new one |
| Drag a window | Move it next to the window it is dropped on (the side nearest the cursor), or to an unused box or "+" |
| Middle-click a window | Close it |
| Arrow keys | Select the nearest window in that direction, across workspaces |
| Tab, Shift+Tab | Step through every window in order |

## Update and remove

```bash
omarchy plugin update christeceno.4-finger-overview
omarchy restart shell
omarchy plugin remove christeceno.4-finger-overview
```

Restart the shell after an update: this plugin stays loaded, and the shell's hot reload does not replace a loaded plugin's code. Remove the gesture lines from `input.lua` as well when uninstalling.

## Notes

- Only regular workspaces are shown. Special workspaces (such as the scratchpad) are skipped.
- Window positions come from `hyprctl` when the overview opens; previews then update live while it stays open.
- Tested on a single monitor so far. Multi-monitor reports are welcome.

## License

MIT
