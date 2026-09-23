import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick
import qs.Commons

// Workspace overview for the focused monitor. Shows every regular workspace on
// that monitor holding at least one window, each as a scaled-down copy of the
// monitor with live previews of its windows.
//
// One window is selected at a time: it starts on the focused window, follows
// the mouse, and moves with the arrow keys to the nearest window in that
// direction, across workspaces. Enter or a click focuses it; clicking the
// empty part of a workspace switches to that workspace.
//
// Summoned by a 4-finger swipe (see README) through
// `omarchy-shell shell summon christeceno.4-finger-overview '{}'`.
Item {
  id: root

  property bool opened: false
  property var monitor: null     // hyprctl monitors entry for the focused monitor
  property var workspaces: []    // [{ id, name, windows: [client, ...] }]
  property int selectedWs: 0     // index into workspaces
  property int selectedWin: -1   // index into workspaces[selectedWs].windows, -1 for none

  // Darker than the menu scrim: the previews are busy, and a see-through
  // backdrop makes the desktop behind them read as more windows.
  property color scrim: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.88)
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property color accent: Color.accent
  property string fontFamily: Style.font.menuFamily
  readonly property int radius: Style.cornerRadius
  readonly property int gap: Style.space(24)
  readonly property int labelHeight: Style.font.body + Style.space(12)

  readonly property var selectedWindow: {
    var ws = root.workspaces[root.selectedWs]
    return ws && root.selectedWin >= 0 ? ws.windows[root.selectedWin] : null
  }

  function open(payloadJson) {
    root.opened = true
    clientsProc.running = true
  }

  function close() {
    root.opened = false
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  // hyprctl gives both monitors and clients as JSON in one call each; read
  // them together so the layout is built from a single consistent snapshot.
  Process {
    id: clientsProc
    command: ["sh", "-c", "printf '{\"monitors\":%s,\"clients\":%s}' \"$(hyprctl monitors -j)\" \"$(hyprctl clients -j)\""]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.build(text)
    }
  }

  // Re-read windows shortly after closing one, once Hyprland has unmapped it.
  Timer {
    id: refreshTimer
    interval: 250
    onTriggered: clientsProc.running = true
  }

  function build(raw) {
    var data
    try { data = JSON.parse(raw) } catch (e) { console.warn("overview: bad hyprctl output", e); return }

    var mon = data.monitors.find(function(m) { return m.focused }) || data.monitors[0]
    if (!mon) return

    var byId = {}
    for (var i = 0; i < data.clients.length; i++) {
      var c = data.clients[i]
      if (c.monitor !== mon.id || c.workspace.id <= 0 || !c.mapped || c.hidden) continue
      if (!byId[c.workspace.id]) byId[c.workspace.id] = { id: c.workspace.id, name: c.workspace.name, windows: [] }
      byId[c.workspace.id].windows.push(c)
    }

    var list = Object.keys(byId).map(function(k) { return byId[k] })
    list.sort(function(a, b) { return a.id - b.id })

    root.monitor = mon
    root.workspaces = list

    // Start on the focused window (focusHistoryID 0), else the first window
    // of the active workspace.
    root.selectedWs = Math.max(0, list.findIndex(function(w) { return w.id === mon.activeWorkspace.id }))
    root.selectedWin = list.length > 0 ? 0 : -1
    for (var w = 0; w < list.length; w++) {
      var idx = list[w].windows.findIndex(function(c) { return c.focusHistoryID === 0 })
      if (idx >= 0) { root.selectedWs = w; root.selectedWin = idx }
    }
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

  function activateSelection() {
    if (root.selectedWindow) root.focusWindow(root.selectedWindow.address)
    else if (root.workspaces[root.selectedWs]) root.goToWorkspace(root.workspaces[root.selectedWs].id)
  }

  function select(wsIndex, winIndex) {
    root.selectedWs = wsIndex
    root.selectedWin = winIndex
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

  // Every window with its center in overview coordinates, in reading order.
  function windowCenters() {
    var out = []
    for (var w = 0; w < root.workspaces.length; w++) {
      var tileX = (w % panel.cols) * (panel.tileW + root.gap)
      var tileY = Math.floor(w / panel.cols) * (panel.tileH + root.labelHeight + root.gap)
      var wins = root.workspaces[w].windows
      for (var i = 0; i < wins.length; i++) {
        out.push({
          ws: w, win: i,
          x: tileX + (wins[i].at[0] - root.monitor.x + wins[i].size[0] / 2) * panel.tileScale,
          y: tileY + (wins[i].at[1] - root.monitor.y + wins[i].size[1] / 2) * panel.tileScale
        })
      }
    }
    return out
  }

  // Move the selection to the nearest window in a direction (dx, dy one of
  // -1/0/1), preferring windows in line with the current one.
  function moveSpatial(dx, dy) {
    var all = root.windowCenters()
    var from = all.find(function(p) { return p.ws === root.selectedWs && p.win === root.selectedWin })
    if (!from) { if (all.length > 0) root.select(all[0].ws, all[0].win); return }

    var best = null, bestScore = Infinity
    for (var i = 0; i < all.length; i++) {
      var p = all[i]
      var along = (p.x - from.x) * dx + (p.y - from.y) * dy
      if (along <= 1) continue
      var across = Math.abs((p.x - from.x) * dy) + Math.abs((p.y - from.y) * dx)
      var score = along + across * 2
      if (score < bestScore) { bestScore = score; best = p }
    }
    if (best) root.select(best.ws, best.win)
  }

  // Tab order: every window in reading order, wrapping.
  function moveSequential(delta) {
    var all = root.windowCenters()
    if (all.length === 0) return
    var at = all.findIndex(function(p) { return p.ws === root.selectedWs && p.win === root.selectedWin })
    var next = all[(Math.max(0, at) + delta + all.length) % all.length]
    root.select(next.ws, next.win)
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

      Keys.onPressed: function(event) {
        var k = event.key
        if (k === Qt.Key_Escape) root.close()
        else if (k === Qt.Key_Left || k === Qt.Key_H) root.moveSpatial(-1, 0)
        else if (k === Qt.Key_Right || k === Qt.Key_L) root.moveSpatial(1, 0)
        else if (k === Qt.Key_Up || k === Qt.Key_K) root.moveSpatial(0, -1)
        else if (k === Qt.Key_Down || k === Qt.Key_J) root.moveSpatial(0, 1)
        else if (k === Qt.Key_Backtab) root.moveSequential(-1)
        else if (k === Qt.Key_Tab) root.moveSequential((event.modifiers & Qt.ShiftModifier) ? -1 : 1)
        else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) root.activateSelection()
        else if (k >= Qt.Key_1 && k <= Qt.Key_9) root.goToWorkspace(k - Qt.Key_0)
        else if (k === Qt.Key_0) root.goToWorkspace(10)
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
    readonly property real tileW: Math.min(
      (width * 0.9 - root.gap * (cols - 1)) / cols,
      ((height * 0.85 - (root.gap + root.labelHeight) * rows) / rows) * monW / monH,
      width * 0.4)
    readonly property real tileH: tileW * monH / monW
    readonly property real tileScale: tileW / monW

    Text {
      visible: panel.count === 0
      anchors.centerIn: parent
      text: "No windows on this monitor"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
    }

    Flow {
      id: grid
      anchors.centerIn: parent
      width: panel.cols * panel.tileW + (panel.cols - 1) * root.gap
      spacing: root.gap
      opacity: root.opened && root.monitor ? 1 : 0
      scale: root.opened && root.monitor ? 1 : 0.96
      Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
      Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

      Repeater {
        model: root.workspaces

        delegate: Column {
          id: tile
          required property var modelData
          required property int index
          readonly property bool selected: index === root.selectedWs
          readonly property bool current: root.monitor && modelData.id === root.monitor.activeWorkspace.id
          spacing: Style.space(6)

          Rectangle {
            width: panel.tileW
            height: panel.tileH
            radius: root.radius
            color: root.background
            clip: true
            border.width: tile.selected ? Style.space(3) : 1
            border.color: tile.selected ? root.accent : Qt.rgba(root.border.r, root.border.g, root.border.b, 0.3)

            Repeater {
              model: tile.modelData.windows

              delegate: Item {
                id: win
                required property var modelData
                required property int index
                readonly property var toplevel: root.opened ? root.toplevelFor(modelData.address) : null
                readonly property bool selected: tile.selected && index === root.selectedWin
                x: (modelData.at[0] - root.monitor.x) * panel.tileScale
                y: (modelData.at[1] - root.monitor.y) * panel.tileScale
                width: modelData.size[0] * panel.tileScale
                height: modelData.size[1] * panel.tileScale
                z: selected ? 1 : 0

                Rectangle {
                  anchors.fill: parent
                  radius: Math.max(2, root.radius * panel.tileScale)
                  color: Qt.darker(root.background, 1.3)
                  border.width: 1
                  border.color: Qt.rgba(root.border.r, root.border.g, root.border.b, 0.3)
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
                  visible: win.selected
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

            // One pointer handler per workspace, on top of the previews. It
            // hit-tests the windows itself, topmost first, so hovering a
            // window always selects it and hovering the gaps selects the
            // workspace. It only reacts to movement, so opening the overview
            // under a resting cursor keeps the focused window selected.
            MouseArea {
              anchors.fill: parent
              z: 2
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              acceptedButtons: Qt.LeftButton | Qt.MiddleButton

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

              onPositionChanged: function(mouse) { root.select(tile.index, windowAt(mouse.x, mouse.y)) }
              onClicked: function(mouse) {
                var i = windowAt(mouse.x, mouse.y)
                var w = i >= 0 ? tile.modelData.windows[i] : null
                if (mouse.button === Qt.MiddleButton) {
                  if (!w) return
                  root.dispatch("hl.dsp.window.close({ window = \"address:" + w.address + "\" })")
                  refreshTimer.restart()
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
  }
}
