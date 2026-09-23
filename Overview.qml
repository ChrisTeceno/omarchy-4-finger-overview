import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick
import qs.Commons

// Workspace overview for the focused monitor. Shows every regular workspace on
// that monitor holding at least one window, each as a scaled-down copy of the
// monitor with live previews of its windows. Click a workspace (or press
// Enter on it) to switch there; click a window to focus it.
//
// Summoned by a 4-finger swipe (see README) through
// `omarchy-shell shell summon christeceno.4-finger-overview '{}'`.
Item {
  id: root

  property bool opened: false
  property var monitor: null     // hyprctl monitors entry for the focused monitor
  property var workspaces: []    // [{ id, name, windows: [client, ...] }]
  property int selectedIndex: 0

  property color scrim: Color.menu.scrim
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property color accent: Color.menu.selectedBackground
  property string fontFamily: Style.font.menuFamily
  readonly property int radius: Style.cornerRadius
  readonly property int gap: Style.space(24)

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
    var current = list.findIndex(function(w) { return w.id === mon.activeWorkspace.id })
    root.selectedIndex = current >= 0 ? current : 0
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

  // Wayland toplevel handle for a Hyprland window address, for screencopy.
  function toplevelFor(address) {
    var list = ToplevelManager.toplevels.values
    for (var i = 0; i < list.length; i++) {
      var hy = list[i].HyprlandToplevel
      if (hy && ("0x" + hy.address) === address) return list[i]
    }
    return null
  }

  function move(delta) {
    if (root.workspaces.length === 0) return
    root.selectedIndex = (root.selectedIndex + delta + root.workspaces.length) % root.workspaces.length
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
        if (event.key === Qt.Key_Escape) root.close()
        else if (event.key === Qt.Key_Left || event.key === Qt.Key_H || event.key === Qt.Key_Up || event.key === Qt.Key_K) root.move(-1)
        else if (event.key === Qt.Key_Right || event.key === Qt.Key_L || event.key === Qt.Key_Down || event.key === Qt.Key_J || event.key === Qt.Key_Tab) root.move(1)
        else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && root.workspaces.length > 0)
          root.goToWorkspace(root.workspaces[root.selectedIndex].id)
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
      ((height * 0.85 - root.gap * (rows - 1)) / rows) * monW / monH,
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
      anchors.centerIn: parent
      width: panel.cols * panel.tileW + (panel.cols - 1) * root.gap
      spacing: root.gap

      Repeater {
        model: root.workspaces

        delegate: Column {
          id: tile
          required property var modelData
          required property int index
          readonly property bool selected: index === root.selectedIndex
          readonly property bool current: root.monitor && modelData.id === root.monitor.activeWorkspace.id
          spacing: Style.space(6)

          Rectangle {
            width: panel.tileW
            height: panel.tileH
            radius: root.radius
            color: root.background
            clip: true
            border.width: tile.selected ? Style.space(3) : 1
            border.color: tile.selected ? root.accent : root.border

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              onEntered: root.selectedIndex = tile.index
              onClicked: root.goToWorkspace(tile.modelData.id)
            }

            Repeater {
              model: tile.modelData.windows

              delegate: Item {
                id: win
                required property var modelData
                readonly property var toplevel: root.opened ? root.toplevelFor(modelData.address) : null
                x: (modelData.at[0] - root.monitor.x) * panel.tileScale
                y: (modelData.at[1] - root.monitor.y) * panel.tileScale
                width: modelData.size[0] * panel.tileScale
                height: modelData.size[1] * panel.tileScale

                Rectangle {
                  anchors.fill: parent
                  radius: Math.max(2, root.radius * panel.tileScale)
                  color: Qt.darker(root.background, 1.3)
                  border.width: 1
                  border.color: root.border
                }

                ScreencopyView {
                  anchors.fill: parent
                  anchors.margins: 1
                  captureSource: win.toplevel
                  live: root.opened
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

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  onEntered: root.selectedIndex = tile.index
                  onClicked: root.focusWindow(win.modelData.address)
                }
              }
            }
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: tile.modelData.name
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: tile.current
          }
        }
      }
    }
  }
}
