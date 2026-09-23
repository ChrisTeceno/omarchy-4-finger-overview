import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick
import qs.Commons

// Workspace overview for the focused monitor. Shows every regular workspace on
// that monitor holding at least one window, each as a scaled-down copy of the
// monitor with live previews of its windows. A column on the right lists the
// unused workspaces 1 to 10 as small numbered boxes, plus a "+" box for a new
// workspace past the highest one in use.
//
// One window is selected at a time: it starts on the focused window, follows
// the mouse, and moves with the arrow keys to the nearest window in that
// direction, across workspaces. Enter or a click focuses it; clicking the
// empty part of a workspace switches to that workspace. Typing filters the
// windows by title and class.
//
// Dragging a window onto another workspace, an unused box, or "+" moves it
// there without leaving the overview, which then re-reads the layout. Inside
// a workspace, including the window's own, the drop splits the tiled window
// under the cursor, on the side of it nearest the cursor. While dragging, a
// box grows around the window, and a workspace previews the split, with the
// window being split sliding over to make room.
//
// Summoned by a 4-finger swipe (see README) through
// `omarchy-shell shell summon christeceno.4-finger-overview '{}'`.
Item {
  id: root

  property bool opened: false
  property var monitor: null     // hyprctl monitors entry for the focused monitor
  property var workspaces: []    // [{ id, name, windows: [client, ...] }]
  property var freeIds: []       // workspaces 1 to 10 with no windows on any monitor
  property int newId: 11         // first workspace id past everything in use
  property int selectedWs: 0     // index into workspaces
  property int selectedWin: -1   // index into workspaces[selectedWs].windows, -1 for none
  property int selectedBox: -1   // index into the side column (freeIds, then "+"), -1 when a workspace is selected
  property string filterText: ""
  property bool helpOpen: false

  // Drag state. dragX/dragY are in panel coordinates; dropTarget is the
  // workspace id under the cursor, or -1.
  property var dragWin: null
  property real dragX: 0
  property real dragY: 0
  property int dropTarget: -1
  property var dropBox: null     // unused/"+" box under the cursor, which grows around the window
  // Over a workspace tile: the tiled window the drop will split, and on which
  // side ("l", "r", "u", "d") the dragged window goes. target is null when
  // the workspace has no tiled window to split.
  property var dropAt: null      // { target: client | null, side: string }
  property bool keyGrab: false   // the drag was started from the keyboard (SUPER+SHIFT+arrow)

  // Darker than the menu scrim: the previews are busy, and a see-through
  // backdrop makes the desktop behind them read as more windows.
  property color scrim: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.88)
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property color dimBorder: Qt.rgba(border.r, border.g, border.b, 0.3)
  property color accent: Color.accent
  property string fontFamily: Style.font.menuFamily
  readonly property int radius: Style.cornerRadius
  readonly property int gap: Style.space(24)
  readonly property int labelHeight: Style.font.body + Style.space(12)
  readonly property int searchHeight: Style.font.body + Style.space(20)
  readonly property int boxW: Style.space(72)
  // Hyprland puts gaps_in on each side of a tiled window, so two split halves
  // sit 2 * gaps_in apart (5 on Omarchy).
  readonly property int splitGap: 10

  readonly property var selectedWindow: {
    if (root.selectedBox >= 0) return null
    var ws = root.workspaces[root.selectedWs]
    return ws && root.selectedWin >= 0 ? ws.windows[root.selectedWin] : null
  }

  // While open, a payload of {"jump": "l"|"r"|"u"|"d"} moves the selection to
  // the neighbouring workspace, {"grab": dir} grabs the selected window or
  // moves the grabbed one, and {"help": true} toggles the shortcut sheet,
  // instead of reopening. Hyprland keeps SUPER+arrow, SUPER+SHIFT+arrow and
  // SUPER+K for itself, so the README's bindings send them here while the
  // overview is showing.
  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") || {} } catch (e) {}
    if (root.opened && payload.help) {
      root.helpOpen = !root.helpOpen
      return
    }
    if (root.opened && payload.grab) {
      var gd = { l: [-1, 0], r: [1, 0], u: [0, -1], d: [0, 1] }[payload.grab]
      if (gd) root.grabStep(gd[0], gd[1])
      return
    }
    if (root.opened && payload.jump) {
      var dirs = { l: [-1, 0], r: [1, 0], u: [0, -1], d: [0, 1] }
      var d = dirs[payload.jump]
      if (d) root.moveWorkspace(d[0], d[1])
      return
    }
    root.filterText = ""
    root.helpOpen = false
    root.endDrag()
    root.opened = true
    clientsProc.running = true
  }

  function close() {
    root.endDrag()
    root.opened = false
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  // Monitors, clients and workspaces in one process, so the layout is built
  // from a single consistent snapshot. The process table comes along so the
  // search can match programs running inside a window (herdr or claude in a
  // terminal), not just its title and class.
  Process {
    id: clientsProc
    command: ["sh", "-c", "printf '{\"monitors\":%s,\"clients\":%s,\"workspaces\":%s,\"ps\":%s}' \"$(hyprctl monitors -j)\" \"$(hyprctl clients -j)\" \"$(hyprctl workspaces -j)\" \"$(ps -e -o pid=,ppid=,comm= | jq -Rs .)\""]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.build(text)
    }
  }

  // Re-read the layout shortly after moving or closing a window, once
  // Hyprland has applied it.
  Timer {
    id: refreshTimer
    interval: 200
    onTriggered: clientsProc.running = true
  }

  function build(raw) {
    var data
    try { data = JSON.parse(raw) } catch (e) { console.warn("overview: bad hyprctl output", e); return }

    var mon = data.monitors.find(function(m) { return m.focused }) || data.monitors[0]
    if (!mon) return

    // Program names in each window's process tree, two levels down from the
    // window's own process: terminal, then shell or multiplexer, then what
    // runs in it.
    var children = {}, comm = {}
    String(data.ps || "").split("\n").forEach(function(line) {
      var m = line.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/)
      if (!m) return
      comm[m[1]] = m[3]
      ;(children[m[2]] = children[m[2]] || []).push(m[1])
    })
    function programs(pid) {
      var names = [], level = [String(pid)]
      for (var depth = 0; depth <= 2 && level.length; depth++) {
        var next = []
        level.forEach(function(p) {
          if (comm[p]) names.push(comm[p])
          next = next.concat(children[p] || [])
        })
        level = next
      }
      return names.join(" ")
    }

    var byId = {}
    var used = {}
    var highest = 10
    for (var i = 0; i < data.clients.length; i++) {
      var c = data.clients[i]
      if (c.workspace.id <= 0) continue
      used[c.workspace.id] = true
      highest = Math.max(highest, c.workspace.id)
      if (c.monitor !== mon.id || !c.mapped || c.hidden) continue
      c.programs = programs(c.pid)
      if (!byId[c.workspace.id]) byId[c.workspace.id] = { id: c.workspace.id, name: c.workspace.name, windows: [] }
      byId[c.workspace.id].windows.push(c)
    }
    for (var j = 0; j < data.workspaces.length; j++)
      if (data.workspaces[j].id > 0) highest = Math.max(highest, data.workspaces[j].id)

    var list = Object.keys(byId).map(function(k) { return byId[k] })
    list.sort(function(a, b) { return a.id - b.id })

    var free = []
    for (var n = 1; n <= 10; n++) if (!used[n]) free.push(n)

    root.monitor = mon
    root.workspaces = list
    root.freeIds = free
    root.newId = highest + 1

    // Start on the focused window (focusHistoryID 0), else the first window
    // of the active workspace.
    root.selectedBox = -1
    root.selectedWs = Math.max(0, list.findIndex(function(w) { return w.id === mon.activeWorkspace.id }))
    root.selectedWin = list.length > 0 ? 0 : -1
    for (var w = 0; w < list.length; w++) {
      var idx = list[w].windows.findIndex(function(c) { return c.focusHistoryID === 0 })
      if (idx >= 0) { root.selectedWs = w; root.selectedWin = idx }
    }
    root.selectFirstMatchIfHidden()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function dispatch(lua) {
    Hyprland.dispatch(lua)
  }

  function goToWorkspace(id) {
    root.close()
    root.dispatch("hl.dsp.focus({ workspace = \"" + id + "\" })")
  }

  function focusWindow(address) {
    root.close()
    root.dispatch("hl.dsp.focus({ window = \"address:" + address + "\" })")
  }

  function moveWindow(address, workspaceId) {
    root.dispatch("hl.dsp.window.move({ window = \"address:" + address + "\", workspace = \"" + workspaceId + "\", follow = false })")
    refreshTimer.restart()
  }

  function closeWindow(address) {
    root.dispatch("hl.dsp.window.close({ window = \"address:" + address + "\" })")
    refreshTimer.restart()
  }

  function activateSelection() {
    if (root.selectedBox >= 0) root.goToWorkspace(root.boxId(root.selectedBox))
    else if (root.selectedWindow) root.focusWindow(root.selectedWindow.address)
    else if (root.workspaces[root.selectedWs]) root.goToWorkspace(root.workspaces[root.selectedWs].id)
  }

  function select(wsIndex, winIndex) {
    root.selectedBox = -1
    root.selectedWs = wsIndex
    root.selectedWin = winIndex
  }

  function selectBox(i) {
    root.selectedBox = i
  }

  // Workspace id of side-column box i: an unused workspace, or "+" last.
  function boxId(i) {
    return i < root.freeIds.length ? root.freeIds[i] : root.newId
  }

  function boxItem(i) {
    return i < root.freeIds.length ? freeBoxes.itemAt(i) : plusBox
  }

  // Centers of the side-column boxes, in grid coordinates like the windows.
  function boxCenters() {
    var out = []
    for (var i = 0; i <= root.freeIds.length; i++) {
      var item = root.boxItem(i)
      if (!item) continue
      var p = item.mapToItem(grid, item.width / 2, item.height / 2)
      out.push({ box: i, x: p.x, y: p.y })
    }
    return out
  }

  // The current selection as a point in grid coordinates: a box, a window,
  // or (with nothing selected in it) a workspace tile's center.
  function selectionPoint(windows) {
    if (root.selectedBox >= 0)
      return root.boxCenters().find(function(p) { return p.box === root.selectedBox })
    var w = windows.find(function(p) { return p.ws === root.selectedWs && p.win === root.selectedWin })
    return w || root.tileCenters().find(function(p) { return p.ws === root.selectedWs })
  }

  function tileCenters() {
    var out = []
    for (var w = 0; w < root.workspaces.length; w++)
      out.push({ ws: w, win: -1,
        x: (w % panel.cols) * (panel.tileW + root.gap) + panel.tileW / 2,
        y: Math.floor(w / panel.cols) * (panel.tileH + root.labelHeight + root.gap) + panel.tileH / 2 })
    return out
  }

  // Nearest candidate from `from` in a direction (dx, dy one of -1/0/1),
  // preferring candidates in line with it.
  function nearestInDirection(from, candidates, dx, dy) {
    var best = null, bestScore = Infinity
    for (var i = 0; i < candidates.length; i++) {
      var p = candidates[i]
      var along = (p.x - from.x) * dx + (p.y - from.y) * dy
      if (along <= 1) continue
      var score = along + (Math.abs((p.x - from.x) * dy) + Math.abs((p.y - from.y) * dx)) * 2
      if (score < bestScore) { bestScore = score; best = p }
    }
    return best
  }

  // Select a workspace tile, landing on its last-focused window that passes
  // the search.
  function selectWorkspace(w) {
    var wins = root.workspaces[w].windows
    var pick = -1
    for (var i = 0; i < wins.length; i++)
      if (root.matches(wins[i]) && (pick < 0 || wins[i].focusHistoryID < wins[pick].focusHistoryID)) pick = i
    root.select(w, pick)
  }

  function applyPick(p) {
    if (!p) return
    if (p.box !== undefined) root.selectBox(p.box)
    else if (p.win >= 0) root.select(p.ws, p.win)
    else root.selectWorkspace(p.ws)
  }

  // Search: case-insensitive substring of the window title, class, or the
  // names of the programs running in it.
  function matches(c) {
    if (!root.filterText) return true
    var needle = root.filterText.toLowerCase()
    return [c.title, c.class, c.initialClass, c.programs].some(function(f) {
      return String(f || "").toLowerCase().indexOf(needle) >= 0
    })
  }

  function setFilter(text) {
    root.filterText = text
    root.selectFirstMatchIfHidden()
  }

  function selectFirstMatchIfHidden() {
    if (root.selectedWindow && root.matches(root.selectedWindow)) return
    var all = root.windowCenters()
    if (all.length > 0) root.select(all[0].ws, all[0].win)
    else root.selectedWin = -1
  }

  // Wayland toplevel handle for a Hyprland window address, for screencopy.
  function toplevelFor(address) {
    var list = ToplevelManager.toplevels.values
    for (var i = 0; i < list.length; i++) {
      var hy = list[i].HyprlandToplevel
      if (hy && ("0x" + hy.address) === address) return list[i]
    }
    return null
  }

  // Every window that passes the search, with its center in overview
  // coordinates, in reading order.
  function windowCenters() {
    var out = []
    for (var w = 0; w < root.workspaces.length; w++) {
      var tileX = (w % panel.cols) * (panel.tileW + root.gap)
      var tileY = Math.floor(w / panel.cols) * (panel.tileH + root.labelHeight + root.gap)
      var wins = root.workspaces[w].windows
      for (var i = 0; i < wins.length; i++) {
        if (!root.matches(wins[i])) continue
        out.push({
          ws: w, win: i,
          x: tileX + (wins[i].at[0] - root.monitor.x + wins[i].size[0] / 2) * panel.tileScale,
          y: tileY + (wins[i].at[1] - root.monitor.y + wins[i].size[1] / 2) * panel.tileScale
        })
      }
    }
    return out
  }

  // Arrow keys: the nearest window in a direction, or a side-column box, so
  // Right from the rightmost window reaches the unused workspaces and "+".
  function moveSpatial(dx, dy) {
    var wins = root.windowCenters()
    var from = root.selectionPoint(wins)
    var all = wins.concat(root.boxCenters())
    if (!from) { root.applyPick(all[0]); return }
    root.applyPick(root.nearestInDirection(from, all, dx, dy))
  }

  // SUPER+arrows: the nearest workspace tile in a direction, or a
  // side-column box.
  function moveWorkspace(dx, dy) {
    var tilesAt = root.tileCenters()
    var from = root.selectedBox >= 0
      ? root.boxCenters().find(function(p) { return p.box === root.selectedBox })
      : tilesAt.find(function(p) { return p.ws === root.selectedWs })
    var all = tilesAt.concat(root.boxCenters())
    if (!from) { root.applyPick(all[0]); return }
    root.applyPick(root.nearestInDirection(from, all, dx, dy))
  }

  // Tab order: every window in reading order, then the side-column boxes,
  // wrapping.
  function moveSequential(delta) {
    var all = root.windowCenters().concat(root.boxCenters())
    if (all.length === 0) return
    var at = all.findIndex(function(p) {
      return root.selectedBox >= 0 ? p.box === root.selectedBox : (p.ws === root.selectedWs && p.win === root.selectedWin)
    })
    root.applyPick(all[(Math.max(0, at) + delta + all.length) % all.length])
  }

  // Drop targets: workspace tiles, unused-workspace boxes and the "+" box.
  // Returns { id, box } for the target under a panel-coordinate point, where
  // box is the box item or null for a tile; id is -1 over nothing.
  function targetAt(px, py) {
    function hit(item) {
      if (!item) return false
      var p = item.mapFromItem(panel.contentItem, px, py)
      return p.x >= 0 && p.y >= 0 && p.x < item.width && p.y < item.height
    }
    for (var i = 0; i < tiles.count; i++)
      if (hit(tiles.itemAt(i))) return { id: root.workspaces[i].id, box: null }
    for (var j = 0; j < freeBoxes.count; j++)
      if (hit(freeBoxes.itemAt(j))) return { id: root.freeIds[j], box: freeBoxes.itemAt(j) }
    if (hit(plusBox)) return { id: root.newId, box: plusBox }
    return { id: -1, box: null }
  }

  function startDrag(client) {
    root.dragWin = client
    root.dropTarget = -1
  }

  function updateDrag(px, py) {
    root.dragX = px
    root.dragY = py
    var t = root.targetAt(px, py)
    root.dropTarget = t.id
    root.dropBox = t.box
    root.dropAt = t.id > 0 && !t.box ? root.splitAt(t.id, px, py) : null
  }

  // Which tiled window of workspace wsId a drop at a panel point splits, and
  // on which side: the window under the point, else the nearest one by
  // center, never the dragged window itself. The side is the edge of that
  // window nearest the point, measured relative to its size.
  function splitAt(wsId, px, py) {
    var i = root.workspaces.findIndex(function(w) { return w.id === wsId })
    var item = tiles.itemAt(i)
    if (i < 0 || !item) return null
    var local = item.mapFromItem(panel.contentItem, px, py)
    var lx = local.x / panel.tileScale + root.monitor.x
    var ly = local.y / panel.tileScale + root.monitor.y
    var dragged = root.dragWin
    var tiled = root.workspaces[i].windows.filter(function(c) { return !c.floating && c.address !== dragged.address })
    if (tiled.length === 0) return { target: null, side: "" }

    var target = null, best = Infinity
    for (var k = 0; k < tiled.length; k++) {
      var c = tiled[k]
      var inside = lx >= c.at[0] && ly >= c.at[1] && lx < c.at[0] + c.size[0] && ly < c.at[1] + c.size[1]
      var d = inside ? -1 : Math.hypot(lx - (c.at[0] + c.size[0] / 2), ly - (c.at[1] + c.size[1] / 2))
      if (d < best) { best = d; target = c }
    }
    var dx = (lx - (target.at[0] + target.size[0] / 2)) / target.size[0]
    var dy = (ly - (target.at[1] + target.size[1] / 2)) / target.size[1]
    var side = Math.abs(dx) > Math.abs(dy) ? (dx < 0 ? "l" : "r") : (dy < 0 ? "u" : "d")
    return { target: target, side: side }
  }

  function finishDrag() {
    var w = root.dragWin
    var target = root.dropTarget
    var at = root.dropAt
    var box = root.dropBox
    root.endDrag()
    if (!w || target <= 0) return
    if (!box && at && at.target) root.placeWindow(w, target, at.target, at.side)
    else if (target !== w.workspace.id) root.moveWindow(w.address, target)
  }

  // Put window w into workspace wsId as a split of window `target`, on `side`.
  // Hyprland's dwindle layout (with use_active_for_splits, the default)
  // splits the focused window of the workspace a window is added to, and
  // "preselect" picks the side for the next one. So: focus the target, which
  // shows its workspace behind the overview, preselect, add the window, then
  // return to the workspace that was showing. A window already in wsId is
  // first parked on a special workspace so it can be added again. A floating
  // window is tiled as it lands, which is what adds it to the split. Run as
  // one hyprctl batch so nothing else lands in between.
  function placeWindow(w, wsId, target, side) {
    var addr = "address:" + w.address
    var steps = []
    if (w.workspace.id === wsId)
      steps.push("hl.dsp.window.move({ window = \"" + addr + "\", workspace = \"special:overview-drag\", follow = false })")
    steps.push("hl.dsp.focus({ window = \"address:" + target.address + "\" })")
    if (w.floating) {
      steps.push("hl.dsp.window.move({ window = \"" + addr + "\", workspace = \"" + wsId + "\", follow = false })")
      steps.push("hl.dsp.layout(\"preselect " + side + "\")")
      steps.push("hl.dsp.window.float({ window = \"" + addr + "\", action = \"disable\" })")
    } else {
      steps.push("hl.dsp.layout(\"preselect " + side + "\")")
      steps.push("hl.dsp.window.move({ window = \"" + addr + "\", workspace = \"" + wsId + "\", follow = false })")
    }
    steps.push("hl.dsp.focus({ workspace = \"" + root.monitor.activeWorkspace.id + "\" })")
    batchProc.command = ["hyprctl", "--batch", steps.map(function(x) { return "dispatch " + x }).join(" ; ")]
    batchProc.running = true
  }

  Process {
    id: batchProc
    onExited: refreshTimer.restart()
  }

  // Keyboard drag. The first SUPER+SHIFT+arrow picks up the selected window;
  // each arrow after that moves it to the nearest drop slot in that
  // direction: a side of another window, an empty workspace, an unused box or
  // "+". It reuses the mouse drag by pointing the drag at the slot, so the
  // preview and the drop are the same. Enter drops, Esc cancels.
  function grabStep(dx, dy) {
    if (!root.dragWin) {
      // With a workspace selected but no window (the pointer resting on a
      // gap), take its last-focused window.
      if (!root.selectedWindow && root.selectedBox < 0 && root.workspaces[root.selectedWs])
        root.selectWorkspace(root.selectedWs)
      var w = root.selectedWindow
      if (!w) return
      var start = root.windowPoint(root.selectedWs, w, 0.5, 0.5)
      root.startDrag(w)
      root.keyGrab = true
      if (start) root.updateDrag(start.x, start.y)
    }
    var best = root.nearestInDirection({ x: root.dragX, y: root.dragY }, root.grabSlots(), dx, dy)
    if (best) root.updateDrag(best.x, best.y)
  }

  // Panel-coordinate point at fractions (fx, fy) across window c's rect in
  // workspace tile w.
  function windowPoint(w, c, fx, fy) {
    var item = tiles.itemAt(w)
    if (!item) return null
    return item.mapToItem(panel.contentItem,
      (c.at[0] - root.monitor.x + c.size[0] * fx) * panel.tileScale,
      (c.at[1] - root.monitor.y + c.size[1] * fy) * panel.tileScale)
  }

  // Every drop slot as a panel point that splitAt/targetAt resolve to it:
  // just inside each edge of every other tiled window, the center of a
  // workspace with nothing to split, and each side-column box.
  function grabSlots() {
    var out = []
    for (var w = 0; w < root.workspaces.length; w++) {
      var tiled = root.workspaces[w].windows.filter(function(c) { return !c.floating && c.address !== root.dragWin.address })
      if (tiled.length === 0) {
        var item = tiles.itemAt(w)
        if (item) out.push(item.mapToItem(panel.contentItem, panel.tileW / 2, panel.tileH / 2))
        continue
      }
      tiled.forEach(function(c) {
        ;[[0.15, 0.5], [0.85, 0.5], [0.5, 0.15], [0.5, 0.85]].forEach(function(f) {
          var p = root.windowPoint(w, c, f[0], f[1])
          if (p) out.push(p)
        })
      })
    }
    for (var i = 0; i <= root.freeIds.length; i++) {
      var box = root.boxItem(i)
      if (box) out.push(box.mapToItem(panel.contentItem, box.width / 2, box.height / 2))
    }
    return out.map(function(p) { return { x: p.x, y: p.y } })
  }

  function endDrag() {
    root.keyGrab = false
    root.dragWin = null
    root.dropTarget = -1
    root.dropBox = null
    root.dropAt = null
  }

  // Where the dragged window would land in workspace ws, in monitor-relative
  // logical coordinates: the split window's half away from `side`, and the
  // dragged window's half on it, 2 * gaps_in apart. An empty workspace (or
  // one with only floating windows) gives it the whole usable area. Returns
  // null when ws is not the drop target.
  //   { target: address of the window being split (or ""),
  //     targetRect: that window's new rect, newRect: the dragged window's }
  function dropPreview(ws) {
    if (!root.dragWin || root.dropTarget !== ws.id || !root.dropAt || !root.monitor) return null
    var mon = root.monitor
    var g = root.splitGap
    var t = root.dropAt.target
    if (!t) {
      var r = mon.reserved || [0, 0, 0, 0]
      return { target: "", targetRect: null, newRect: {
        x: r[0] + g, y: r[1] + g,
        w: mon.width / mon.scale - r[0] - r[2] - 2 * g,
        h: mon.height / mon.scale - r[1] - r[3] - 2 * g } }
    }
    var x = t.at[0] - mon.x, y = t.at[1] - mon.y, w = t.size[0], h = t.size[1]
    var hw = (w - g) / 2, hh = (h - g) / 2
    var first = { l: { x: x, y: y, w: hw, h: h }, u: { x: x, y: y, w: w, h: hh } }
    var second = { l: { x: x + hw + g, y: y, w: hw, h: h }, u: { x: x, y: y + hh + g, w: w, h: hh } }
    var side = root.dropAt.side
    var axis = side === "l" || side === "r" ? "l" : "u"
    var newFirst = side === "l" || side === "u"
    return { target: t.address,
      targetRect: newFirst ? second[axis] : first[axis],
      newRect: newFirst ? first[axis] : second[axis] }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    screen: {
      if (!root.monitor) return null
      var screens = Quickshell.screens
      for (var i = 0; i < screens.length; i++)
        if (screens[i].name === root.monitor.name) return screens[i]
      return null
    }
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "christeceno-4-finger-overview"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      // Printable keys go to the search, so navigation is arrows and Tab only.
      Keys.onPressed: function(event) {
        var k = event.key
        if (root.helpOpen && k !== Qt.Key_K) {
          root.helpOpen = false
          event.accepted = true
          return
        }
        if ((event.modifiers & Qt.MetaModifier) && k === Qt.Key_K) root.helpOpen = !root.helpOpen
        else if (root.keyGrab && (k === Qt.Key_Left || k === Qt.Key_Right || k === Qt.Key_Up || k === Qt.Key_Down))
          root.grabStep(k === Qt.Key_Left ? -1 : k === Qt.Key_Right ? 1 : 0, k === Qt.Key_Up ? -1 : k === Qt.Key_Down ? 1 : 0)
        else if (root.keyGrab && (k === Qt.Key_Return || k === Qt.Key_Enter)) root.finishDrag()
        else if (k === Qt.Key_Escape) {
          if (root.dragWin) root.endDrag()
          else if (root.filterText) root.setFilter("")
          else root.close()
        }
        else if ((event.modifiers & Qt.MetaModifier) && k === Qt.Key_Left) root.moveWorkspace(-1, 0)
        else if ((event.modifiers & Qt.MetaModifier) && k === Qt.Key_Right) root.moveWorkspace(1, 0)
        else if ((event.modifiers & Qt.MetaModifier) && k === Qt.Key_Up) root.moveWorkspace(0, -1)
        else if ((event.modifiers & Qt.MetaModifier) && k === Qt.Key_Down) root.moveWorkspace(0, 1)
        else if (k === Qt.Key_Left) root.moveSpatial(-1, 0)
        else if (k === Qt.Key_Right) root.moveSpatial(1, 0)
        else if (k === Qt.Key_Up) root.moveSpatial(0, -1)
        else if (k === Qt.Key_Down) root.moveSpatial(0, 1)
        else if (k === Qt.Key_Backtab) root.moveSequential(-1)
        else if (k === Qt.Key_Tab) root.moveSequential((event.modifiers & Qt.ShiftModifier) ? -1 : 1)
        else if (k === Qt.Key_Return || k === Qt.Key_Enter) root.activateSelection()
        else if (k === Qt.Key_Backspace) root.setFilter(root.filterText.slice(0, -1))
        else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127
                 && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)))
          root.setFilter(root.filterText + event.text)
        else return
        event.accepted = true
      }
    }

    // Logical monitor size: hyprctl reports physical pixels, windows are laid
    // out in logical (scaled) coordinates.
    readonly property real monW: root.monitor ? root.monitor.width / root.monitor.scale : 1
    readonly property real monH: root.monitor ? root.monitor.height / root.monitor.scale : 1
    readonly property int count: root.workspaces.length
    readonly property int cols: count <= 3 ? Math.max(1, count) : Math.ceil(Math.sqrt(count))
    readonly property int rows: Math.max(1, Math.ceil(count / cols))
    readonly property real sideW: root.boxW + root.gap * 2
    readonly property real tileW: Math.min(
      (width * 0.92 - sideW - root.gap * (cols - 1)) / cols,
      ((height * 0.82 - root.searchHeight - (root.gap + root.labelHeight) * rows) / rows) * monW / monH,
      width * 0.4)
    readonly property real tileH: tileW * monH / monW
    readonly property real tileScale: tileW / monW
    readonly property real boxH: root.boxW * monH / monW

    // Search box.
    Rectangle {
      id: searchBox
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: parent.height * 0.05
      width: Math.min(Style.space(520), parent.width * 0.5)
      height: root.searchHeight
      radius: root.radius
      color: root.background
      border.width: root.filterText ? Style.space(2) : 1
      border.color: root.filterText ? root.accent : root.dimBorder
      opacity: grid.opacity

      Text {
        anchors.fill: parent
        anchors.leftMargin: Style.space(14)
        anchors.rightMargin: Style.space(14)
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideLeft
        text: root.filterText || "Type to search windows"
        color: root.filterText ? root.foreground : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.45)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
    }

    Text {
      anchors.top: searchBox.bottom
      anchors.topMargin: Style.space(6)
      anchors.horizontalCenter: searchBox.horizontalCenter
      visible: root.keyGrab
      text: "Arrows move the window, Enter drops it, Esc cancels"
      color: root.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      visible: panel.count === 0
      anchors.centerIn: parent
      anchors.horizontalCenterOffset: -panel.sideW / 2
      text: "No windows on this monitor"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
    }

    Flow {
      id: grid
      anchors.centerIn: parent
      anchors.horizontalCenterOffset: -panel.sideW / 2
      anchors.verticalCenterOffset: root.searchHeight / 2
      width: panel.cols * panel.tileW + (panel.cols - 1) * root.gap
      spacing: root.gap
      opacity: root.opened && root.monitor ? 1 : 0
      scale: root.opened && root.monitor ? 1 : 0.96
      Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
      Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

      Repeater {
        id: tiles
        model: root.workspaces

        delegate: Column {
          id: tile
          required property var modelData
          required property int index
          readonly property bool selected: index === root.selectedWs && root.selectedBox < 0
          readonly property bool current: root.monitor && modelData.id === root.monitor.activeWorkspace.id
          readonly property bool dropHere: root.dragWin !== null && root.dropTarget === modelData.id
          readonly property var preview: root.dropPreview(modelData)
          spacing: Style.space(6)

          Rectangle {
            width: panel.tileW
            height: panel.tileH
            radius: root.radius
            color: tile.dropHere ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.12) : root.background
            clip: true
            border.width: tile.selected || tile.dropHere ? Style.space(3) : 1
            border.color: tile.selected || tile.dropHere ? root.accent : root.dimBorder

            Repeater {
              model: tile.modelData.windows

              delegate: Item {
                id: win
                required property var modelData
                required property int index
                readonly property var toplevel: root.opened ? root.toplevelFor(modelData.address) : null
                readonly property bool selected: tile.selected && index === root.selectedWin
                readonly property bool dragged: root.dragWin !== null && root.dragWin.address === modelData.address
                readonly property var rect: tile.preview && tile.preview.target === modelData.address
                  ? tile.preview.targetRect
                  : { x: modelData.at[0] - root.monitor.x, y: modelData.at[1] - root.monitor.y, w: modelData.size[0], h: modelData.size[1] }
                x: rect.x * panel.tileScale
                y: rect.y * panel.tileScale
                width: rect.w * panel.tileScale
                height: rect.h * panel.tileScale
                Behavior on x { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                Behavior on y { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                Behavior on height { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                z: selected ? 1 : 0
                opacity: win.dragged ? 0.3 : root.matches(modelData) ? 1 : 0.2

                Rectangle {
                  anchors.fill: parent
                  radius: Math.max(2, root.radius * panel.tileScale)
                  color: Qt.darker(root.background, 1.3)
                  border.width: 1
                  border.color: root.dimBorder
                }

                ScreencopyView {
                  anchors.fill: parent
                  anchors.margins: 1
                  captureSource: win.toplevel
                  live: root.opened
                }

                // Selection highlight: accent tint and border drawn over the
                // preview, so it shows whatever the window contains.
                Rectangle {
                  anchors.fill: parent
                  radius: Math.max(2, root.radius * panel.tileScale)
                  visible: win.selected && !root.dragWin
                  color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.15)
                  border.width: Style.space(3)
                  border.color: root.accent
                }

                Text {
                  visible: !win.toplevel
                  anchors.centerIn: parent
                  width: parent.width - 8
                  horizontalAlignment: Text.AlignHCenter
                  elide: Text.ElideRight
                  text: win.modelData.class || win.modelData.title
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            // The slot the dragged window will take, opened up by the
            // preview above.
            Rectangle {
              id: slot
              visible: opacity > 0
              opacity: tile.preview ? 1 : 0
              Behavior on opacity { NumberAnimation { duration: 160 } }
              readonly property var r: tile.preview ? tile.preview.newRect : slot.lastRect
              property var lastRect: ({ x: 0, y: 0, w: 0, h: 0 })
              onRChanged: if (tile.preview) lastRect = tile.preview.newRect
              x: r.x * panel.tileScale
              y: r.y * panel.tileScale
              width: r.w * panel.tileScale
              height: r.h * panel.tileScale
              z: 1
              radius: Math.max(2, root.radius * panel.tileScale)
              color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.15)
              border.width: Style.space(2)
              border.color: root.accent

              ScreencopyView {
                anchors.fill: parent
                anchors.margins: Style.space(2)
                opacity: 0.6
                captureSource: root.dragWin ? root.toplevelFor(root.dragWin.address) : null
                live: slot.visible
              }
            }

            // One pointer handler per workspace, on top of the previews. It
            // hit-tests the windows itself, topmost first, so hovering a
            // window always selects it and hovering the gaps selects the
            // workspace. It only reacts to movement, so opening the overview
            // under a resting cursor keeps the focused window selected.
            // Pressing a window and moving past a few pixels starts a drag;
            // the press keeps the pointer grab, so the drag can leave the
            // tile for other tiles and the boxes on the right.
            MouseArea {
              id: tileMouse
              anchors.fill: parent
              z: 2
              hoverEnabled: true
              cursorShape: root.dragWin ? Qt.ClosedHandCursor : Qt.PointingHandCursor
              acceptedButtons: Qt.LeftButton | Qt.MiddleButton

              property int pressedWin: -1
              property real pressX: 0
              property real pressY: 0
              property bool dragged: false

              function windowAt(mx, my) {
                var wins = tile.modelData.windows
                for (var i = wins.length - 1; i >= 0; i--) {
                  var x = (wins[i].at[0] - root.monitor.x) * panel.tileScale
                  var y = (wins[i].at[1] - root.monitor.y) * panel.tileScale
                  if (mx >= x && my >= y && mx < x + wins[i].size[0] * panel.tileScale && my < y + wins[i].size[1] * panel.tileScale)
                    return i
                }
                return -1
              }

              onPressed: function(mouse) {
                pressedWin = mouse.button === Qt.LeftButton ? windowAt(mouse.x, mouse.y) : -1
                pressX = mouse.x
                pressY = mouse.y
                dragged = false
              }

              onPositionChanged: function(mouse) {
                if (pressed && pressedWin >= 0) {
                  if (!dragged && Math.abs(mouse.x - pressX) + Math.abs(mouse.y - pressY) > 8) {
                    dragged = true
                    root.startDrag(tile.modelData.windows[pressedWin])
                  }
                  if (dragged) {
                    var p = mapToItem(panel.contentItem, mouse.x, mouse.y)
                    root.updateDrag(p.x, p.y)
                  }
                  return
                }
                root.select(tile.index, windowAt(mouse.x, mouse.y))
              }

              onReleased: function(mouse) {
                if (dragged) root.finishDrag()
              }

              onCanceled: root.endDrag()

              onClicked: function(mouse) {
                if (dragged) return
                var i = windowAt(mouse.x, mouse.y)
                var w = i >= 0 ? tile.modelData.windows[i] : null
                if (mouse.button === Qt.MiddleButton) {
                  if (w) root.closeWindow(w.address)
                } else if (w) {
                  root.focusWindow(w.address)
                } else {
                  root.goToWorkspace(tile.modelData.id)
                }
              }
            }
          }

          // Workspace number, plus the selected window's title under its
          // workspace.
          Text {
            width: panel.tileW
            height: root.labelHeight - Style.space(6)
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: tile.selected && root.selectedWindow
              ? tile.modelData.name + "   " + (root.selectedWindow.title || root.selectedWindow.class)
              : tile.modelData.name
            color: tile.selected ? root.accent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: tile.current
          }
        }
      }
    }

    // Unused workspaces and "+": click to go there, drop a window to move it.
    Column {
      id: side
      // Anchored at the top so a box growing under a drag pushes only the
      // boxes below it, and never slides out from under the cursor.
      anchors.right: parent.right
      anchors.rightMargin: root.gap
      anchors.top: searchBox.bottom
      anchors.topMargin: root.gap
      spacing: Style.space(8)
      opacity: grid.opacity

      Repeater {
        id: freeBoxes
        model: root.freeIds

        delegate: Rectangle {
          id: box
          required property var modelData
          required property int index
          readonly property bool dropHere: root.dragWin !== null && root.dropTarget === modelData
          readonly property bool selected: root.selectedBox === index
          anchors.right: parent.right
          width: dropHere ? dragProxy.w + Style.space(16) : root.boxW
          height: dropHere ? dragProxy.h + Style.space(16) : panel.boxH
          Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
          Behavior on height { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
          radius: root.radius
          color: dropHere ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.12) : root.background
          border.width: dropHere || selected ? Style.space(3) : boxMouse.containsMouse ? Style.space(2) : 1
          border.color: dropHere || selected || boxMouse.containsMouse ? root.accent : root.dimBorder

          // Hidden while the box holds a dragged window.
          Text {
            anchors.centerIn: parent
            visible: !box.dropHere
            text: box.modelData
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.6)
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          MouseArea {
            id: boxMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onPositionChanged: if (!root.dragWin) root.selectBox(box.index)
            onClicked: root.goToWorkspace(box.modelData)
          }
        }
      }

      Rectangle {
        id: plusBox
        readonly property bool dropHere: root.dragWin !== null && root.dropTarget === root.newId
        readonly property bool selected: root.selectedBox === root.freeIds.length
        anchors.right: parent.right
        width: dropHere ? dragProxy.w + Style.space(16) : root.boxW
        height: dropHere ? dragProxy.h + Style.space(16) : panel.boxH
        Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        Behavior on height { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        radius: root.radius
        color: dropHere ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.12) : "transparent"
        border.width: dropHere || selected ? Style.space(3) : plusMouse.containsMouse ? Style.space(2) : 1
        border.color: dropHere || selected || plusMouse.containsMouse ? root.accent : root.dimBorder

        Text {
          anchors.centerIn: parent
          text: "+"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
        }

        MouseArea {
          id: plusMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onPositionChanged: if (!root.dragWin) root.selectBox(root.freeIds.length)
          onClicked: root.goToWorkspace(root.newId)
        }
      }
    }

    // Shortcut sheet, toggled with SUPER+K; any other key or a click closes it.
    Item {
      anchors.fill: parent
      visible: root.helpOpen
      z: 20

      Rectangle {
        anchors.fill: parent
        color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.6)
      }

      MouseArea {
        anchors.fill: parent
        onClicked: root.helpOpen = false
      }

      Rectangle {
        anchors.centerIn: parent
        width: helpGrid.width + Style.space(48)
        height: helpTitle.height + helpGrid.height + Style.space(64)
        radius: root.radius
        color: root.background
        border.width: 1
        border.color: root.dimBorder

        Text {
          id: helpTitle
          anchors.top: parent.top
          anchors.topMargin: Style.space(24)
          anchors.horizontalCenter: parent.horizontalCenter
          text: "Overview shortcuts"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Grid {
          id: helpGrid
          anchors.top: helpTitle.bottom
          anchors.topMargin: Style.space(16)
          anchors.horizontalCenter: parent.horizontalCenter
          columns: 2
          columnSpacing: Style.space(32)
          rowSpacing: Style.space(8)

          Repeater {
            model: [
              "Arrow keys", "Select the nearest window in that direction",
              "SUPER + arrow keys", "Jump to the neighbouring workspace or box",
              "SUPER + SHIFT + arrow keys", "Grab the selected window; arrows move it, Enter drops",
              "Tab / Shift + Tab", "Step through every window",
              "Enter", "Focus the selected window, or go to the selected box",
              "Type", "Search by title, app or program (Backspace edits)",
              "Esc", "Cancel drag, clear search, then close",
              "Click window", "Focus it",
              "Click empty space", "Switch to that workspace",
              "Middle-click window", "Close it",
              "Drag window", "Place it beside the window under the cursor",
              "Drag to a box or +", "Move it to that workspace",
              "4-finger swipe up / SUPER + TAB", "Open or close",
              "SUPER + K", "Show or hide this sheet"
            ]

            delegate: Text {
              required property var modelData
              required property int index
              text: modelData
              color: index % 2 === 0 ? root.accent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: index % 2 === 0
            }
          }
        }
      }
    }

    // The window being dragged, following the cursor.
    Rectangle {
      id: dragProxy
      visible: root.dragWin !== null
      readonly property real w: root.dragWin ? Math.min(root.dragWin.size[0] * panel.tileScale, panel.tileW * 0.6) : 0
      readonly property real h: root.dragWin ? w * root.dragWin.size[1] / root.dragWin.size[0] : 0
      // Follows the cursor, except over a box, where it settles in the
      // middle of the box growing around it.
      x: root.dropBox ? side.x + root.dropBox.x + (root.dropBox.width - w) / 2 : root.dragX - w / 2
      y: root.dropBox ? side.y + root.dropBox.y + (root.dropBox.height - h) / 2 : root.dragY - h / 2
      Behavior on x { enabled: root.dropBox !== null; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
      Behavior on y { enabled: root.dropBox !== null; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
      width: w
      height: h
      z: 10
      radius: Math.max(2, root.radius * panel.tileScale)
      color: Qt.darker(root.background, 1.3)
      border.width: Style.space(2)
      border.color: root.accent
      // Over a workspace the slot shows the window, so the proxy steps back.
      opacity: root.dropTarget > 0 && !root.dropBox ? 0.45 : 0.9

      ScreencopyView {
        anchors.fill: parent
        anchors.margins: Style.space(2)
        captureSource: root.dragWin ? root.toplevelFor(root.dragWin.address) : null
        live: dragProxy.visible
      }
    }
  }
}
