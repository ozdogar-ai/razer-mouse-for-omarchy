import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Razer mouse battery + DPI, modelled on the built-in Audio panel: a bar button
// that opens a keyboard-driven popup with a hero header, sections separated by
// PanelSeparator, and a single CursorSurface cursor shared by mouse and keys.
//
// All device access goes through razer-mice.py, which talks to the OpenRazer
// daemon over D-Bus and prints JSON.
Panel {
  id: root
  moduleName: "ozdogar.razer-mouse"
  ipcTarget: "ozdogar.razer-mouse"

  // ---------- Settings (inline shell.json entry) ----------
  readonly property bool showPercentage: setting("showPercentage", true)
  readonly property int lowBatteryPercent: setting("lowBatteryPercent", 20)
  readonly property int refreshIntervalSec: Math.max(15, setting("refreshIntervalSec", 60))

  // ---------- Device state ----------
  property bool loaded: false
  property bool daemonRunning: true
  property var mice: []
  property string selectedSerial: ""

  readonly property var mouse: {
    for (var i = 0; i < mice.length; i++)
      if (mice[i].serial === selectedSerial) return mice[i]
    return mice.length > 0 ? mice[0] : null
  }
  readonly property bool hasBattery: !!mouse && mouse.battery !== null && mouse.battery !== undefined
  readonly property int battery: hasBattery ? mouse.battery : 0
  readonly property bool charging: !!mouse && mouse.charging === true
  readonly property bool batteryLow: hasBattery && !charging && battery <= lowBatteryPercent
  readonly property int currentDpi: mouse && mouse.dpi ? mouse.dpi : 0
  readonly property int maxDpi: mouse && mouse.maxDpi ? mouse.maxDpi : 26000

  readonly property var dpiPresets: {
    var all = [400, 800, 1200, 1600, 3200, 6400]
    var list = []
    for (var i = 0; i < all.length; i++) if (all[i] <= maxDpi) list.push(all[i])
    return list
  }

  // DPI the user is steering towards; shown immediately, written after a pause
  // so dragging the slider doesn't queue a D-Bus call for every step.
  property int pendingDpi: 0
  readonly property int shownDpi: pendingDpi > 0 ? pendingDpi : currentDpi

  readonly property string helperPath: {
    var url = Qt.resolvedUrl("razer-mice.py").toString()
    if (url.indexOf("file://") === 0) url = url.substring(7)
    return decodeURIComponent(url)
  }

  // ---------- Cursor model (same shape as the Audio panel) ----------
  //   "slider"  — DPI slider row (h/l nudges DPI)
  //   "presets" — preset chips (h/l walks chips, Enter applies)
  //   "devices" — one row per mouse, only when more than one is connected
  //   "daemon"  — the "start daemon" row, only when OpenRazer isn't running
  property string focusSection: "slider"
  property int selectedIndex: 0
  property bool cursorActive: false

  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color dimForeground: bar ? Qt.darker(bar.foreground, 1.4) : Color.foreground

  readonly property var visibleSections: {
    if (!daemonRunning) return ["daemon"]
    if (!mouse) return []
    var list = []
    if (currentDpi > 0) list.push("slider", "presets")
    if (mice.length > 1) list.push("devices")
    return list
  }

  function sectionCount(section) {
    if (section === "presets") return dpiPresets.length
    if (section === "devices") return mice.length
    return 1
  }

  function moveCursor(delta) {
    var sections = visibleSections
    if (sections.length === 0) return
    var sIdx = sections.indexOf(focusSection)
    if (sIdx < 0) { focusSection = sections[0]; selectedIndex = 0; return }
    // Only the device list is vertical; slider and preset rows are one row each.
    if (focusSection === "devices") {
      var next = selectedIndex + delta
      if (next >= 0 && next < mice.length) { selectedIndex = next; return }
    }
    var target = sIdx + delta
    if (target < 0 || target >= sections.length) return
    focusSection = sections[target]
    if (focusSection === "presets") selectedIndex = Math.max(0, dpiPresets.indexOf(currentDpi))
    else if (focusSection === "devices") selectedIndex = delta > 0 ? 0 : mice.length - 1
    else selectedIndex = 0
  }

  function moveHorizontal(dx) {
    if (focusSection === "slider") nudgeDpi(dx * 100)
    else if (focusSection === "presets")
      selectedIndex = Math.max(0, Math.min(dpiPresets.length - 1, selectedIndex + dx))
  }

  function activateCursor() {
    if (focusSection === "presets" && selectedIndex >= 0 && selectedIndex < dpiPresets.length)
      applyDpi(dpiPresets[selectedIndex])
    else if (focusSection === "devices" && selectedIndex >= 0 && selectedIndex < mice.length)
      selectedSerial = mice[selectedIndex].serial
    else if (focusSection === "daemon")
      startDaemon()
  }

  // ---------- Actions ----------
  function refresh() {
    if (!statusProc.running && !setProc.running) statusProc.running = true
  }

  function applyStatus(raw) {
    var data
    try { data = JSON.parse(String(raw)) } catch (e) { return }
    loaded = true
    daemonRunning = data.daemon === true
    mice = Array.isArray(data.mice) ? data.mice : []
    if (mouse && selectedSerial === "") selectedSerial = mouse.serial
    // Keep the pending value on screen until the device reports it back.
    if (pendingDpi > 0 && !dpiWriteTimer.running && !setProc.running && currentDpi === pendingDpi)
      pendingDpi = 0
    clampCursor()
  }

  function clampDpi(v) {
    return Math.max(100, Math.min(maxDpi, Math.round(v / 50) * 50))
  }

  // The slider runs 0..1 on a log scale: with a 26000 DPI ceiling, a linear
  // track would squeeze the everyday 400-3200 range into its first tenth.
  function dpiToPos(dpi) {
    if (dpi <= 100) return 0
    return Math.log(dpi / 100) / Math.log(maxDpi / 100)
  }

  function posToDpi(pos) {
    return clampDpi(100 * Math.exp(Math.max(0, Math.min(1, pos)) * Math.log(maxDpi / 100)))
  }

  function applyDpi(v) {
    if (!mouse) return
    pendingDpi = clampDpi(v)
    dpiWriteTimer.restart()
  }

  function nudgeDpi(delta) {
    if (shownDpi > 0) applyDpi(shownDpi + delta)
  }

  function writeDpi() {
    if (!mouse || pendingDpi <= 0) return
    if (setProc.running) { dpiWriteTimer.restart(); return }
    setProc.command = ["python3", root.helperPath, "set-dpi", mouse.serial, String(pendingDpi)]
    setProc.running = true
  }

  function startDaemon() {
    Quickshell.execDetached(["systemctl", "--user", "start", "openrazer-daemon"])
    daemonStartTimer.restart()
  }

  function clampCursor() {
    var sections = visibleSections
    if (sections.length === 0) return
    if (sections.indexOf(focusSection) < 0) { focusSection = sections[0]; selectedIndex = 0; return }
    var count = sectionCount(focusSection)
    if (selectedIndex > count - 1) selectedIndex = Math.max(0, count - 1)
    if (selectedIndex < 0) selectedIndex = 0
  }

  // ---------- Presentation helpers ----------
  function shortName(name) {
    return String(name || "Razer mouse").replace(/^Razer\s+/i, "").replace(/\s*\((Wireless|Wired)\)\s*$/i, "")
  }

  // Same glyph ladders the built-in power panel uses for the laptop battery.
  function batteryGlyph() {
    if (!hasBattery) return "󰚥"
    var charging = ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"]
    var normal = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
    var i = Math.max(0, Math.min(9, Math.floor(battery / 10)))
    return root.charging ? charging[i] : normal[i]
  }

  function statusLabel() {
    if (!loaded) return "Checking…"
    if (!daemonRunning) return "OpenRazer not running"
    if (!mouse) return "No mouse connected"
    if (!hasBattery) return "Wired"
    if (charging) return battery >= 100 ? "Fully charged" : "Charging"
    if (batteryLow) return "Battery low"
    return "On battery"
  }

  function barText() {
    var glyph = "󰍽"
    if (!mouse || !hasBattery || !showPercentage) return glyph
    return glyph + " " + battery + "%" + (charging ? " 󱐋" : "")
  }

  function tooltip() {
    if (!daemonRunning) return "Razer mouse: OpenRazer daemon not running"
    if (!mouse) return "Razer mouse: not connected"
    var t = shortName(mouse.name)
    if (hasBattery) t += " · " + battery + "%" + (charging ? " (charging)" : "")
    if (currentDpi > 0) t += " · " + currentDpi + " DPI"
    return t
  }

  onOpenedChanged: {
    if (opened) {
      refresh()
      cursorActive = false
      focusSection = visibleSections.length > 0 ? visibleSections[0] : "slider"
      selectedIndex = 0
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---------- Processes & timers ----------
  Process {
    id: statusProc
    command: ["python3", root.helperPath, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
  }

  Process {
    id: setProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
    onExited: function(exitCode) {
      // A failed write (mouse asleep, dongle unplugged): drop the pending value
      // and fall back to whatever the device really reports.
      if (exitCode !== 0) { root.pendingDpi = 0; root.refresh() }
    }
  }

  Timer {
    id: dpiWriteTimer
    interval: 250
    onTriggered: root.writeDpi()
  }

  // Battery drains slowly, so poll lazily while closed and briskly while open.
  Timer {
    interval: root.opened ? 5000 : root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: daemonStartTimer
    interval: 2500
    onTriggered: root.refresh()
  }

  // ---------- Bar button ----------
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText()
    tooltipText: root.tooltip()
    active: root.batteryLow
    dimmed: root.loaded && (!root.daemonRunning || !root.mouse)
    onPressed: function(b) {
      if (b === Qt.RightButton) root.refresh()
      else root.toggle()
    }
  }

  // ---------- Popup ----------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.moveHorizontal(dx)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
      }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero: mouse glyph · name / status ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: "󰍽"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              opacity: root.mouse ? 1.0 : 0.5
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                text: root.mouse ? root.shortName(root.mouse.name) : "Razer Mouse"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                textFormat: Text.PlainText
                text: root.statusLabel().toUpperCase()
                color: root.batteryLow ? Color.urgent : root.dimForeground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          // ---------- Daemon not running ----------
          PanelSeparator {
            visible: root.loaded && !root.daemonRunning
            foreground: root.bar.foreground
          }

          CursorSurface {
            id: daemonRow
            visible: root.loaded && !root.daemonRunning
            width: parent.width
            implicitHeight: daemonInner.implicitHeight + Style.spacing.xl
            hasCursor: root.cursorActive && root.focusSection === "daemon"
            foreground: root.bar.foreground
            fill: root.hoverFill

            Row {
              id: daemonInner
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(6)
              anchors.rightMargin: Style.space(6)
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: "󰐊"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                width: Style.space(22)
                horizontalAlignment: Text.AlignHCenter
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                textFormat: Text.PlainText
                text: "Start the OpenRazer daemon"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
                width: parent.width - Style.space(30)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onContainsMouseChanged: if (containsMouse) { root.cursorActive = true; root.focusSection = "daemon" }
              onClicked: root.startDaemon()
            }
          }

          // ---------- Battery ----------
          PanelSeparator {
            visible: !!root.mouse
            foreground: root.bar.foreground
          }

          Column {
            visible: !!root.mouse
            width: parent.width
            spacing: Style.space(8)

            Item {
              width: parent.width
              implicitHeight: Math.max(batteryHeader.implicitHeight, batteryPercent.implicitHeight)

              PanelSectionHeader {
                id: batteryHeader
                text: "BATTERY"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: batteryPercent
                textFormat: Text.PlainText
                text: root.hasBattery ? root.batteryGlyph() + "  " + root.battery + "%" : "—"
                color: root.batteryLow ? Color.urgent : root.dimForeground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            // Level meter, drawn like the Audio panel's input peak meter.
            Rectangle {
              visible: root.hasBattery
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(6)
              anchors.rightMargin: Style.space(6)
              height: Math.max(Style.space(6), Style.spacing.sm)
              radius: height / 2
              color: Util.alpha(root.bar.foreground, 0.18)

              Rectangle {
                height: parent.height
                radius: parent.radius
                width: parent.width * Math.max(0, Math.min(1, root.battery / 100))
                color: root.batteryLow ? Color.urgent : root.bar.foreground
                Behavior on width { NumberAnimation { duration: 200 } }
              }
            }
          }

          // ---------- DPI ----------
          PanelSeparator {
            visible: !!root.mouse && root.currentDpi > 0
            foreground: root.bar.foreground
          }

          Column {
            visible: !!root.mouse && root.currentDpi > 0
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(dpiHeader.implicitHeight, dpiValue.implicitHeight)

              PanelSectionHeader {
                id: dpiHeader
                text: "DPI"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: dpiValue
                textFormat: Text.PlainText
                text: (dpiSlider.dragging ? root.posToDpi(dpiSlider.liveValue) : root.shownDpi) + " DPI"
                color: root.dimForeground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: sliderRow
              width: parent.width
              height: dpiSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "slider"
              foreground: root.bar.foreground
              outline: true

              PanelSlider {
                id: dpiSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 0
                maximum: 1
                step: 0.005
                value: root.dpiToPos(root.shownDpi)
                onMoved: function(v) { root.applyDpi(root.posToDpi(v)) }
              }

              HoverHandler {
                onHoveredChanged: if (hovered) { root.cursorActive = true; root.focusSection = "slider"; root.selectedIndex = 0 }
              }
            }

            CursorSurface {
              id: presetsRow
              width: parent.width
              height: presetGroup.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "presets"
              foreground: root.bar.foreground
              outline: true

              ButtonGroup {
                id: presetGroup
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                options: root.dpiPresets.map(function(d) { return String(d) })
                value: root.dpiPresets.indexOf(root.shownDpi) >= 0 ? String(root.shownDpi) : ""
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.caption
                focusable: false
                cursorIndex: root.cursorActive && root.focusSection === "presets" ? root.selectedIndex : -1
                onChanged: function(v) {
                  root.focusSection = "presets"
                  root.selectedIndex = root.dpiPresets.indexOf(parseInt(v))
                  root.applyDpi(parseInt(v))
                }
                onHovered: function(index, isHovered) {
                  if (isHovered) {
                    root.cursorActive = true
                    root.focusSection = "presets"
                    root.selectedIndex = index
                  }
                }
              }
            }
          }

          // ---------- Devices (only when several mice are connected) ----------
          PanelSeparator {
            visible: root.mice.length > 1
            foreground: root.bar.foreground
          }

          Column {
            visible: root.mice.length > 1
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "DEVICES"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Repeater {
              model: root.mice

              MouseRow {
                required property var modelData
                required property int index
                width: panelColumn.width
                device: modelData
                rowIndex: index
              }
            }
          }
        }
      }
    }
  }

  // One row per connected mouse; clicking selects which one the panel shows.
  component MouseRow: CursorSurface {
    id: mouseRow
    required property var device
    required property int rowIndex

    readonly property bool isActive: !!root.mouse && device && root.mouse.serial === device.serial
    hasCursor: root.cursorActive && root.focusSection === "devices" && root.selectedIndex === rowIndex
    current: isActive
    foreground: root.bar.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: rowInner.implicitHeight + Style.spacing.xl

    Row {
      id: rowInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: "󰍽"
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.title
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: root.shortName(mouseRow.device ? mouseRow.device.name : "")
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        font.bold: mouseRow.isActive
        elide: Text.ElideRight
        width: parent.width - Style.space(22) - rowPct.width - Style.space(16)
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: rowPct
        textFormat: Text.PlainText
        text: mouseRow.device && mouseRow.device.battery !== null ? mouseRow.device.battery + "%" : ""
        color: root.dimForeground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        width: Style.space(36)
        horizontalAlignment: Text.AlignRight
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.focusSection = "devices"
        root.selectedIndex = mouseRow.rowIndex
      }
      onClicked: root.selectedSerial = mouseRow.device.serial
    }
  }
}
