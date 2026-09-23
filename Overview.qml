import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick
import qs.Commons

// Workspace overview, shown on every monitor at once. Each monitor shows its
// own regular workspaces that hold at least one window, each as a
// scaled-down copy of the monitor with live previews of its windows. A
// column on the right of each monitor lists the unused workspaces 1 to 10 as
// small numbered boxes, plus a "+" box for a new workspace past the highest
// one in use; using a box on a monitor puts that workspace on that monitor.
//
// One window is selected at a time, across all monitors: it starts on the
// focused window, follows the mouse, and moves with the arrow keys to the
// nearest window in that direction, across workspaces and monitors. Enter or
// a click focuses it; clicking the empty part of a workspace switches to that
// workspace. Typing filters the windows by title, class, and the programs
// running in them, from whichever monitor has keyboard focus.
//
// Dragging a window onto another workspace (on any monitor), an unused box,
// or "+" moves it there without leaving the overview, which then re-reads the
// layout. Inside a workspace, including the window's own, the drop splits the
// tiled window under the cursor, on the side of it nearest the cursor. While
// dragging, a box grows around the window, and a workspace previews the
// split, with the window being split sliding over to make room.
//
// Summoned by a 4-finger swipe (see README) through
// `omarchy-shell shell summon christeceno.4-finger-overview '{}'`.
Item {
  id: root

  property bool opened: false
  property var monitors: []      // hyprctl monitors
  property string focusedMon: "" // name of the focused monitor
  property var wsByMon: ({})     // monitor name -> [{ id, name, windows: [client, ...] }]
  property var freeIds: []       // workspaces 1 to 10 that do not exist anywhere
  property int newId: 11         // first workspace id past everything in use
  property var panels: ({})      // monitor name -> that monitor's overview window

  // Selection: a window (selWin >= 0) or workspace (selWin -1) in workspace
  // selWs of monitor selMon, or a side-column box (selBox >= 0) on selMon.
  property string selMon: ""
  property int selWs: 0
  property int selWin: -1
  property int selBox: -1
  property string filterText: ""
  property bool helpOpen: false

  // Drag state. dragMon is the monitor under the cursor and dragX/dragY are
  // in that monitor's overview coordinates; dropTarget is the workspace id
  // under the cursor, or -1.
  property var dragWin: null
  property string dragMon: ""
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
    if (root.selBox >= 0) return null
    var ws = (root.wsByMon[root.selMon] || [])[root.selWs]
    return ws && root.selWin >= 0 ? ws.windows[root.selWin] : null
  }

  function monitorByName(name) {
    return root.monitors.find(function(m) { return m.name === name }) || null
  }

  // Logical size of a monitor: hyprctl reports physical pixels, windows are
  // laid out in logical (scaled) coordinates, and a rotated monitor swaps
  // its sides.
  function logicalSize(m) {
    var w = m.width / m.scale, h = m.height / m.scale
    return m.transform % 2 === 1 ? { w: h, h: w } : { w: w, h: h }
  }

  function registerPanel(name, panel) {
    var next = ({})
    for (var k in root.panels) next[k] = root.panels[k]
    if (panel) next[name] = panel
    else delete next[name]
    root.panels = next
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
    var dirs = { l: [-1, 0], r: [1, 0], u: [0, -1], d: [0, 1] }
    if (root.opened && payload.help) {
      root.helpOpen = !root.helpOpen
      return
    }
    if (root.opened && payload.grab) {
      var gd = dirs[payload.grab]
      if (gd) root.grabStep(gd[0], gd[1])
      return
    }
    if (root.opened && payload.jump) {
      var jd = dirs[payload.jump]
      if (jd) root.moveWorkspace(jd[0], jd[1])
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
    if (!data.monitors.length) return

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

    var monName = {}
    data.monitors.forEach(function(m) { monName[m.id] = m.name })

    var byMon = {}
    data.monitors.forEach(function(m) { byMon[m.name] = {} })
    var used = {}
    var highest = 10
    data.workspaces.forEach(function(w) {
      if (w.id <= 0) return
      used[w.id] = true
      highest = Math.max(highest, w.id)
    })
    for (var i = 0; i < data.clients.length; i++) {
      var c = data.clients[i]
      if (c.workspace.id <= 0) continue
      used[c.workspace.id] = true
      highest = Math.max(highest, c.workspace.id)
      var mon = monName[c.monitor]
      if (!mon || !c.mapped || c.hidden) continue
      c.programs = programs(c.pid)
      var group = byMon[mon]
      if (!group[c.workspace.id]) group[c.workspace.id] = { id: c.workspace.id, name: c.workspace.name, windows: [] }
      group[c.workspace.id].windows.push(c)
    }

    var lists = {}
    for (var name in byMon) {
      var g = byMon[name]
      lists[name] = Object.keys(g).map(function(k) { return g[k] }).sort(function(a, b) { return a.id - b.id })
    }

    var free = []
    for (var n = 1; n <= 10; n++) if (!used[n]) free.push(n)

    var focused = data.monitors.find(function(m) { return m.focused }) || data.monitors[0]

    root.monitors = data.monitors
    root.focusedMon = focused.name
    root.wsByMon = lists
    root.freeIds = free
    root.newId = highest + 1

    // Start on the focused window (focusHistoryID 0), else the active
    // workspace of the focused monitor.
    root.selBox = -1
    root.selMon = focused.name
    root.selWs = Math.max(0, (lists[focused.name] || []).findIndex(function(w) { return w.id === focused.activeWorkspace.id }))
    root.selWin = -1
    for (var mn in lists) {
      for (var w = 0; w < lists[mn].length; w++) {
        var idx = lists[mn][w].windows.findIndex(function(c) { return c.focusHistoryID === 0 })
        if (idx >= 0) { root.selMon = mn; root.selWs = w; root.selWin = idx }
      }
    }
    root.selectFirstMatchIfHidden()
  }

  function dispatch(lua) {
    Hyprland.dispatch(lua)
  }

  function runBatch(steps) {
    batchProc.command = ["hyprctl", "--batch", steps.map(function(x) { return "dispatch " + x }).join(" ; ")]
    batchProc.running = true
  }

  Process {
    id: batchProc
    onExited: refreshTimer.restart()
  }

  function goToWorkspace(id) {
    root.close()
    root.dispatch("hl.dsp.focus({ workspace = \"" + id + "\" })")
  }

  // An unused or new workspace, created on monitor `mon`: Hyprland creates a
  // workspace on the focused monitor, so focus that monitor first.
  function goToNewWorkspace(id, mon) {
    root.close()
    root.runBatch([
      "hl.dsp.focus({ monitor = \"" + mon + "\" })",
      "hl.dsp.focus({ workspace = \"" + id + "\" })"
    ])
  }

  function focusWindow(address) {
    root.close()
    root.dispatch("hl.dsp.focus({ window = \"address:" + address + "\" })")
  }

  function closeWindow(address) {
    root.dispatch("hl.dsp.window.close({ window = \"address:" + address + "\" })")
    refreshTimer.restart()
  }

  // Steps that put every monitor back on the workspace it was showing, the
  // focused monitor last so focus ends where it started.
  function restoreSteps() {
    var steps = []
    var focused = root.monitorByName(root.focusedMon)
    root.monitors.forEach(function(m) {
      if (m.name !== root.focusedMon) steps.push("hl.dsp.focus({ workspace = \"" + m.activeWorkspace.id + "\" })")
    })
    if (focused) steps.push("hl.dsp.focus({ workspace = \"" + focused.activeWorkspace.id + "\" })")
    return steps
  }

  // Move window w to workspace wsId on monitor mon, filling it. For a
  // workspace that does not exist yet, focus the monitor first so Hyprland
  // creates it there.
  function moveWindow(w, wsId, mon) {
    var steps = []
    if (!root.workspaceExists(wsId)) steps.push("hl.dsp.focus({ monitor = \"" + mon + "\" })")
    steps.push("hl.dsp.window.move({ window = \"address:" + w.address + "\", workspace = \"" + wsId + "\", follow = false })")
    root.runBatch(steps.concat(root.restoreSteps()))
  }

  function workspaceExists(id) {
    for (var name in root.wsByMon)
      if (root.wsByMon[name].some(function(w) { return w.id === id })) return true
    return root.monitors.some(function(m) { return m.activeWorkspace.id === id })
  }

  // Put window w into workspace wsId as a split of window `target`, on `side`.
  // Hyprland's dwindle layout (with use_active_for_splits, the default)
  // splits the focused window of the workspace a window is added to, and
  // "preselect" picks the side for the next one. So: focus the target, which
  // shows its workspace behind the overview, preselect, add the window, then
  // put every monitor back on the workspace it was showing. A window already
  // in wsId is first parked on a special workspace so it can be added again.
  // A floating window is tiled as it lands, which is what adds it to the
  // split. Run as one hyprctl batch so nothing else lands in between.
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
    root.runBatch(steps.concat(root.restoreSteps()))
  }

  function activateSelection() {
    if (root.selBox >= 0) root.goToNewWorkspace(root.boxId(root.selBox), root.selMon)
    else if (root.selectedWindow) root.focusWindow(root.selectedWindow.address)
    else {
      var ws = (root.wsByMon[root.selMon] || [])[root.selWs]
      if (ws) root.goToWorkspace(ws.id)
    }
  }

  function select(mon, wsIndex, winIndex) {
    root.selBox = -1
    root.selMon = mon
    root.selWs = wsIndex
    root.selWin = winIndex
  }

  function selectBox(mon, i) {
    root.selMon = mon
    root.selBox = i
  }

  // Select a workspace tile, landing on its last-focused window that passes
  // the search.
  function selectWorkspace(mon, w) {
    var wins = root.wsByMon[mon][w].windows
    var pick = -1
    for (var i = 0; i < wins.length; i++)
      if (root.matches(wins[i]) && (pick < 0 || wins[i].focusHistoryID < wins[pick].focusHistoryID)) pick = i
    root.select(mon, w, pick)
  }

  // Workspace id of side-column box i: an unused workspace, or "+" last.
  function boxId(i) {
    return i < root.freeIds.length ? root.freeIds[i] : root.newId
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
    var all = root.windowPoints()
    if (all.length > 0) root.applyPick(all[0])
    else root.selWin = -1
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

  // Navigation works in global layout coordinates, so the arrow keys cross
  // monitors the way the monitors are arranged. Each candidate carries
  // { mon, ws, win } or { mon, box } plus its point { x, y }.
  function toGlobal(mon, p) {
    var m = root.monitorByName(mon)
    return m && p ? { x: m.x + p.x, y: m.y + p.y } : null
  }

  // Panel point at fractions (fx, fy) across window c's rect in workspace
  // tile w of monitor mon's overview.
  function windowPoint(mon, w, c, fx, fy) {
    var panel = root.panels[mon]
    var item = panel ? panel.tileAt(w) : null
    var m = root.monitorByName(mon)
    if (!item || !m) return null
    return item.mapToItem(panel.contentItem,
      (c.at[0] - m.x + c.size[0] * fx) * panel.tileScale,
      (c.at[1] - m.y + c.size[1] * fy) * panel.tileScale)
  }

  function forEachMonitor(fn) {
    root.monitors.slice().sort(function(a, b) { return a.x - b.x || a.y - b.y }).forEach(function(m) { fn(m.name) })
  }

  // Every window that passes the search, in monitor then reading order.
  function windowPoints() {
    var out = []
    root.forEachMonitor(function(mon) {
      var list = root.wsByMon[mon] || []
      for (var w = 0; w < list.length; w++)
        for (var i = 0; i < list[w].windows.length; i++) {
          if (!root.matches(list[w].windows[i])) continue
          var p = root.toGlobal(mon, root.windowPoint(mon, w, list[w].windows[i], 0.5, 0.5))
          if (p) out.push({ mon: mon, ws: w, win: i, x: p.x, y: p.y })
        }
    })
    return out
  }

  function tilePoints() {
    var out = []
    root.forEachMonitor(function(mon) {
      var panel = root.panels[mon]
      var list = root.wsByMon[mon] || []
      for (var w = 0; w < list.length; w++) {
        var item = panel ? panel.tileAt(w) : null
        if (!item) continue
        var p = root.toGlobal(mon, item.mapToItem(panel.contentItem, panel.tileW / 2, panel.tileH / 2))
        out.push({ mon: mon, ws: w, win: -1, x: p.x, y: p.y })
      }
    })
    return out
  }

  function boxPoints() {
    var out = []
    root.forEachMonitor(function(mon) {
      var panel = root.panels[mon]
      if (!panel) return
      for (var i = 0; i <= root.freeIds.length; i++) {
        var item = panel.boxAt(i)
        if (!item) continue
        var p = root.toGlobal(mon, item.mapToItem(panel.contentItem, item.width / 2, item.height / 2))
        out.push({ mon: mon, box: i, x: p.x, y: p.y })
      }
    })
    return out
  }

  function isSelected(p) {
    if (p.mon !== root.selMon) return false
    if (p.box !== undefined) return root.selBox === p.box
    return root.selBox < 0 && p.ws === root.selWs && (p.win === root.selWin || p.win === -1)
  }

  // The current selection's point, from the given candidates, else its tile.
  function selectionPoint(candidates) {
    return candidates.find(root.isSelected) || root.tilePoints().find(root.isSelected) || null
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

  function applyPick(p) {
    if (!p) return
    if (p.box !== undefined) root.selectBox(p.mon, p.box)
    else if (p.win >= 0) root.select(p.mon, p.ws, p.win)
    else root.selectWorkspace(p.mon, p.ws)
  }

  // Arrow keys: the nearest window in a direction, or a side-column box, on
  // any monitor.
  function moveSpatial(dx, dy) {
    var all = root.windowPoints().concat(root.boxPoints())
    var from = root.selectionPoint(all)
    if (!from) { root.applyPick(all[0]); return }
    root.applyPick(root.nearestInDirection(from, all, dx, dy))
  }

  // SUPER+arrows: the nearest workspace tile in a direction, or a
  // side-column box, on any monitor.
  function moveWorkspace(dx, dy) {
    var all = root.tilePoints().concat(root.boxPoints())
    var from = all.find(function(p) {
      return p.mon === root.selMon && (root.selBox >= 0 ? p.box === root.selBox : (p.box === undefined && p.ws === root.selWs))
    })
    if (!from) { root.applyPick(all[0]); return }
    root.applyPick(root.nearestInDirection(from, all, dx, dy))
  }

  // Tab order: every window, then the side-column boxes of each monitor,
  // wrapping.
  function moveSequential(delta) {
    var all = root.windowPoints().concat(root.boxPoints())
    if (all.length === 0) return
    var at = all.findIndex(root.isSelected)
    root.applyPick(all[(Math.max(0, at) + delta + all.length) % all.length])
  }

  // Drop targets on monitor mon's overview: workspace tiles, unused-workspace
  // boxes and the "+" box. Returns { id, box } for the target under a panel
  // point, where box is the box item or null for a tile; id is -1 over
  // nothing.
  function targetAt(mon, px, py) {
    var panel = root.panels[mon]
    if (!panel) return { id: -1, box: null }
    function hit(item) {
      if (!item) return false
      var p = item.mapFromItem(panel.contentItem, px, py)
      return p.x >= 0 && p.y >= 0 && p.x < item.width && p.y < item.height
    }
    var list = root.wsByMon[mon] || []
    for (var i = 0; i < list.length; i++)
      if (hit(panel.tileAt(i))) return { id: list[i].id, box: null }
    for (var j = 0; j <= root.freeIds.length; j++)
      if (hit(panel.boxAt(j))) return { id: root.boxId(j), box: panel.boxAt(j) }
    return { id: -1, box: null }
  }

  function startDrag(client) {
    root.dragWin = client
    root.dropTarget = -1
  }

  // Pointer moved during a drag, at a point in monitor `fromMon`'s overview.
  // The press keeps the pointer grab on that overview even when the pointer
  // crosses to another monitor, so the point can lie outside it: convert to
  // global coordinates and find the monitor it is really on.
  function updateDragFrom(fromMon, px, py) {
    var g = root.toGlobal(fromMon, { x: px, y: py })
    if (!g) return
    var on = root.monitors.find(function(m) {
      var s = root.logicalSize(m)
      return g.x >= m.x && g.y >= m.y && g.x < m.x + s.w && g.y < m.y + s.h
    })
    if (!on) return
    root.updateDrag(on.name, g.x - on.x, g.y - on.y)
  }

  function updateDrag(mon, px, py) {
    root.dragMon = mon
    root.dragX = px
    root.dragY = py
    var t = root.targetAt(mon, px, py)
    root.dropTarget = t.id
    root.dropBox = t.box
    root.dropAt = t.id > 0 && !t.box ? root.splitAt(mon, t.id, px, py) : null
  }

  // Which tiled window of workspace wsId on monitor mon a drop at a panel
  // point splits, and on which side: the window under the point, else the
  // nearest one by center, never the dragged window itself. The side is the
  // edge of that window nearest the point, measured relative to its size.
  function splitAt(mon, wsId, px, py) {
    var panel = root.panels[mon]
    var list = root.wsByMon[mon] || []
    var i = list.findIndex(function(w) { return w.id === wsId })
    var item = panel ? panel.tileAt(i) : null
    var m = root.monitorByName(mon)
    if (i < 0 || !item || !m) return null
    var local = item.mapFromItem(panel.contentItem, px, py)
    var lx = local.x / panel.tileScale + m.x
    var ly = local.y / panel.tileScale + m.y
    var dragged = root.dragWin
    var tiled = list[i].windows.filter(function(c) { return !c.floating && c.address !== dragged.address })
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
    var mon = root.dragMon
    root.endDrag()
    if (!w || target <= 0) return
    if (!box && at && at.target) root.placeWindow(w, target, at.target, at.side)
    else if (target !== w.workspace.id) root.moveWindow(w, target, mon)
  }

  // Keyboard drag. The first SUPER+SHIFT+arrow picks up the selected window;
  // each arrow after that moves it to the nearest drop slot in that
  // direction, on any monitor: a side of another window, an empty workspace,
  // an unused box or "+". It reuses the mouse drag by pointing the drag at
  // the slot, so the preview and the drop are the same. Enter drops, Esc
  // cancels.
  function grabStep(dx, dy) {
    if (!root.dragWin) {
      // With a workspace selected but no window (the pointer resting on a
      // gap), take its last-focused window.
      if (!root.selectedWindow && root.selBox < 0 && (root.wsByMon[root.selMon] || [])[root.selWs])
        root.selectWorkspace(root.selMon, root.selWs)
      var w = root.selectedWindow
      if (!w) return
      var start = root.windowPoint(root.selMon, root.selWs, w, 0.5, 0.5)
      root.startDrag(w)
      root.keyGrab = true
      if (start) root.updateDrag(root.selMon, start.x, start.y)
    }
    var from = root.toGlobal(root.dragMon, { x: root.dragX, y: root.dragY })
    var best = root.nearestInDirection(from, root.grabSlots(), dx, dy)
    if (best) root.updateDrag(best.mon, best.px, best.py)
  }

  // Every drop slot, as a point that targetAt/splitAt resolve to it: just
  // inside each edge of every other tiled window, the center of a workspace
  // with nothing to split, and each side-column box. Carries both the panel
  // point (px, py) and the global point (x, y).
  function grabSlots() {
    var out = []
    function add(mon, p) {
      var g = root.toGlobal(mon, p)
      if (g) out.push({ mon: mon, px: p.x, py: p.y, x: g.x, y: g.y })
    }
    root.forEachMonitor(function(mon) {
      var panel = root.panels[mon]
      if (!panel) return
      var list = root.wsByMon[mon] || []
      for (var w = 0; w < list.length; w++) {
        var tiled = list[w].windows.filter(function(c) { return !c.floating && c.address !== root.dragWin.address })
        if (tiled.length === 0) {
          var item = panel.tileAt(w)
          if (item) add(mon, item.mapToItem(panel.contentItem, panel.tileW / 2, panel.tileH / 2))
          continue
        }
        tiled.forEach(function(c) {
          ;[[0.15, 0.5], [0.85, 0.5], [0.5, 0.15], [0.5, 0.85]].forEach(function(f) {
            var p = root.windowPoint(mon, w, c, f[0], f[1])
            if (p) add(mon, p)
          })
        })
      }
      for (var i = 0; i <= root.freeIds.length; i++) {
        var box = panel.boxAt(i)
        if (box) add(mon, box.mapToItem(panel.contentItem, box.width / 2, box.height / 2))
      }
    })
    return out
  }

  function endDrag() {
    root.keyGrab = false
    root.dragWin = null
    root.dragMon = ""
    root.dropTarget = -1
    root.dropBox = null
    root.dropAt = null
  }

  // Where the dragged window would land in workspace ws of monitor mon, in
  // monitor-relative logical coordinates: the split window's half away from
  // `side`, and the dragged window's half on it, 2 * gaps_in apart. An empty
  // workspace (or one with only floating windows) gives it the whole usable
  // area. Returns null when ws is not the drop target.
  //   { target: address of the window being split (or ""),
  //     targetRect: that window's new rect, newRect: the dragged window's }
  function dropPreview(mon, ws) {
    if (!root.dragWin || root.dragMon !== mon || root.dropTarget !== ws.id || !root.dropAt) return null
    var m = root.monitorByName(mon)
    if (!m) return null
    var g = root.splitGap
    var t = root.dropAt.target
    if (!t) {
      var r = m.reserved || [0, 0, 0, 0]
      var s = root.logicalSize(m)
      return { target: "", targetRect: null, newRect: {
        x: r[0] + g, y: r[1] + g,
        w: s.w - r[0] - r[2] - 2 * g,
        h: s.h - r[1] - r[3] - 2 * g } }
    }
    var x = t.at[0] - m.x, y = t.at[1] - m.y, w = t.size[0], h = t.size[1]
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

  // Keys reach only the focused monitor's overview, which hands them here.
  function handleKey(event) {
    var k = event.key
    if (root.helpOpen && k !== Qt.Key_K) {
      root.helpOpen = false
      event.accepted = true
      return
    }
    if ((event.modifiers & Qt.MetaModifier) && k === Qt.Key_K) root.helpOpen = !root.helpOpen
    else if ((event.modifiers & Qt.MetaModifier) && k === Qt.Key_Left) root.moveWorkspace(-1, 0)
    else if ((event.modifiers & Qt.MetaModifier) && k === Qt.Key_Right) root.moveWorkspace(1, 0)
    else if ((event.modifiers & Qt.MetaModifier) && k === Qt.Key_Up) root.moveWorkspace(0, -1)
    else if ((event.modifiers & Qt.MetaModifier) && k === Qt.Key_Down) root.moveWorkspace(0, 1)
    else if (root.keyGrab && (k === Qt.Key_Left || k === Qt.Key_Right || k === Qt.Key_Up || k === Qt.Key_Down))
      root.grabStep(k === Qt.Key_Left ? -1 : k === Qt.Key_Right ? 1 : 0, k === Qt.Key_Up ? -1 : k === Qt.Key_Down ? 1 : 0)
    else if (root.keyGrab && (k === Qt.Key_Return || k === Qt.Key_Enter)) root.finishDrag()
    else if (k === Qt.Key_Escape) {
      if (root.dragWin) root.endDrag()
      else if (root.filterText) root.setFilter("")
      else root.close()
    }
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

  // One overview window per monitor.
  Variants {
    model: Quickshell.screens

    delegate: PanelWindow {
      id: panel
      required property var modelData
      readonly property string monName: modelData.name
      readonly property var mon: root.monitorByName(monName)
      readonly property var workspaces: root.wsByMon[monName] || []
      readonly property bool isFocused: monName === root.focusedMon

      function tileAt(i) { return tiles.itemAt(i) }
      function boxAt(i) { return i < root.freeIds.length ? freeBoxes.itemAt(i) : plusBox }

      Component.onCompleted: root.registerPanel(monName, panel)
      Component.onDestruction: root.registerPanel(monName, null)

      screen: modelData
      visible: root.opened && mon !== null
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      WlrLayershell.namespace: "christeceno-4-finger-overview"
      WlrLayershell.layer: WlrLayer.Overlay
      // Every monitor's overview is exclusive, not just the focused one's:
      // while any layer holds exclusive keyboard focus, Hyprland sends
      // pointer input only to exclusive layers, so a non-exclusive overview
      // on another monitor could not be clicked. Keys reach whichever one
      // Hyprland focuses (a click moves it), and all of them hand keys to
      // root.handleKey.
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
      exclusionMode: ExclusionMode.Ignore

      onVisibleChanged: if (visible) Qt.callLater(function() { keyCatcher.forceActiveFocus() })

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
        Keys.onPressed: function(event) { root.handleKey(event) }
      }

      readonly property real monW: mon ? root.logicalSize(mon).w : 1
      readonly property real monH: mon ? root.logicalSize(mon).h : 1
      readonly property int count: workspaces.length
      readonly property real sideW: root.boxW + root.gap * 2
      // Tile width for a given column count, fitting the space left of the
      // box column and below the search box.
      function fitWidth(c) {
        var r = Math.ceil(count / c)
        return Math.min(
          (width * 0.92 - sideW - root.gap * (c - 1)) / c,
          ((height * 0.82 - root.searchHeight - (root.gap + root.labelHeight) * r) / r) * monW / monH,
          width * 0.4)
      }
      // The column count that gives the largest tiles, so an ultrawide gets
      // one long row and a tall monitor a column.
      readonly property int cols: {
        var best = 1
        for (var c = 2; c <= Math.max(1, count); c++) if (fitWidth(c) > fitWidth(best)) best = c
        return best
      }
      readonly property int rows: Math.max(1, Math.ceil(count / cols))
      readonly property real tileW: fitWidth(cols)
      readonly property real tileH: tileW * monH / monW
      readonly property real tileScale: tileW / monW
      readonly property real boxH: root.boxW * monH / monW

      // Search box; the text is shared by every monitor.
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
        opacity: root.opened && panel.mon ? 1 : 0
        scale: root.opened && panel.mon ? 1 : 0.96
        Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

        Repeater {
          id: tiles
          model: panel.workspaces

          delegate: Column {
            id: tile
            required property var modelData
            required property int index
            readonly property bool selected: root.selMon === panel.monName && index === root.selWs && root.selBox < 0
            readonly property bool current: panel.mon && modelData.id === panel.mon.activeWorkspace.id
            readonly property bool dropHere: root.dragWin !== null && root.dragMon === panel.monName && root.dropTarget === modelData.id
            readonly property var preview: root.dropPreview(panel.monName, modelData)
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
                  readonly property bool selected: tile.selected && index === root.selWin
                  readonly property bool dragged: root.dragWin !== null && root.dragWin.address === modelData.address
                  readonly property var rect: tile.preview && tile.preview.target === modelData.address
                    ? tile.preview.targetRect
                    : { x: modelData.at[0] - panel.mon.x, y: modelData.at[1] - panel.mon.y, w: modelData.size[0], h: modelData.size[1] }
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
              // tile, and the monitor, for any other drop target.
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
                    var x = (wins[i].at[0] - panel.mon.x) * panel.tileScale
                    var y = (wins[i].at[1] - panel.mon.y) * panel.tileScale
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
                      root.updateDragFrom(panel.monName, p.x, p.y)
                    }
                    return
                  }
                  root.select(panel.monName, tile.index, windowAt(mouse.x, mouse.y))
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

      // Unused workspaces and "+": click to go there on this monitor, drop a
      // window to move it there.
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
            readonly property bool dropHere: root.dragWin !== null && root.dragMon === panel.monName && root.dropTarget === modelData
            readonly property bool selected: root.selMon === panel.monName && root.selBox === index
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
              onPositionChanged: if (!root.dragWin) root.selectBox(panel.monName, box.index)
              onClicked: root.goToNewWorkspace(box.modelData, panel.monName)
            }
          }
        }

        Rectangle {
          id: plusBox
          readonly property bool dropHere: root.dragWin !== null && root.dragMon === panel.monName && root.dropTarget === root.newId
          readonly property bool selected: root.selMon === panel.monName && root.selBox === root.freeIds.length
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
            onPositionChanged: if (!root.dragWin) root.selectBox(panel.monName, root.freeIds.length)
            onClicked: root.goToNewWorkspace(root.newId, panel.monName)
          }
        }
      }

      // Shortcut sheet, toggled with SUPER+K on the focused monitor; any
      // other key or a click closes it.
      Item {
        anchors.fill: parent
        visible: root.helpOpen && panel.isFocused
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
                "Arrow keys", "Select the nearest window in that direction, on any monitor",
                "SUPER + arrow keys", "Jump to the neighbouring workspace or box",
                "SUPER + SHIFT + arrow keys", "Grab the selected window; arrows move it, Enter drops",
                "Tab / Shift + Tab", "Step through every window",
                "Enter", "Focus the selected window, or go to the selected box",
                "Type", "Search by title, app or program (Backspace edits)",
                "Esc", "Cancel drag, clear search, then close",
                "Click window", "Focus it",
                "Click empty space", "Switch to that workspace",
                "Middle-click window", "Close it",
                "Drag window", "Place it beside the window under the cursor, on any monitor",
                "Drag to a box or +", "Move it to that workspace, on that monitor",
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

      // The window being dragged, following the cursor on whichever monitor
      // it is over.
      Rectangle {
        id: dragProxy
        visible: root.dragWin !== null && root.dragMon === panel.monName
        readonly property real w: root.dragWin ? Math.min(root.dragWin.size[0] * panel.tileScale, panel.tileW * 0.6) : 0
        readonly property real h: root.dragWin ? w * root.dragWin.size[1] / root.dragWin.size[0] : 0
        readonly property var box: root.dragMon === panel.monName ? root.dropBox : null
        // Follows the cursor, except over a box, where it settles in the
        // middle of the box growing around it.
        x: box ? side.x + box.x + (box.width - w) / 2 : root.dragX - w / 2
        y: box ? side.y + box.y + (box.height - h) / 2 : root.dragY - h / 2
        Behavior on x { enabled: dragProxy.box !== null; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        Behavior on y { enabled: dragProxy.box !== null; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        width: w
        height: h
        z: 10
        radius: Math.max(2, root.radius * panel.tileScale)
        color: Qt.darker(root.background, 1.3)
        border.width: Style.space(2)
        border.color: root.accent
        // Over a workspace the slot shows the window, so the proxy steps back.
        opacity: root.dropTarget > 0 && !box ? 0.45 : 0.9

        ScreencopyView {
          anchors.fill: parent
          anchors.margins: Style.space(2)
          captureSource: root.dragWin ? root.toplevelFor(root.dragWin.address) : null
          live: dragProxy.visible
        }
      }
    }
  }
}
