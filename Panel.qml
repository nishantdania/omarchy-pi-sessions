import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "nishant.pi-sessions"
  ipcTarget: "nishant.pi-sessions"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Color.popups.background
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string helperPath: Qt.resolvedUrl("bin/omarchy-pi-session").toString().replace(/^file:\/\//, "")

  property var sessions: []
  property var previousStatuses: ({})
  property bool initialized: false
  property int selectedIndex: 0
  property var notificationQueue: []

  readonly property int runningCount: countStatus("running")
  readonly property int waitingCount: countStatus("waiting")
  readonly property int doneCount: countStatus("done")
  readonly property int idleCount: countStatus("idle")
  readonly property bool needsAttention: waitingCount > 0

  function countStatus(status) {
    var count = 0
    for (var i = 0; i < sessions.length; i++)
      if (sessions[i].status === status) count++
    return count
  }

  function sectionName(session) {
    return session && session.status === "running" ? "Running" : "Waiting"
  }

  function sectionLabel(session) {
    var running = session && session.status === "running"
    var count = running ? runningCount : waitingCount + doneCount + idleCount
    return (running ? "RUNNING" : "WAITING") + "  " + count
  }

  function shortModel(model) {
    var value = String(model || "")
    var slash = value.indexOf("/")
    return slash >= 0 ? value.substring(slash + 1) : value
  }

  function relativeTime(value) {
    var timestamp = new Date(String(value || "")).getTime()
    if (!isFinite(timestamp)) return ""
    var seconds = Math.max(0, Math.floor((Date.now() - timestamp) / 1000))
    if (seconds < 60) return "now"
    var minutes = Math.floor(seconds / 60)
    if (minutes < 60) return minutes + "m ago"
    var hours = Math.floor(minutes / 60)
    if (hours < 24) return hours + "h ago"
    return Math.floor(hours / 24) + "d ago"
  }

  function sessionMeta(session) {
    var parts = [String(session.project || "")]
    var model = shortModel(session.model)
    if (model !== "") parts.push(model)
    var time = relativeTime(session.activityAt)
    if (time !== "") parts.push(time)
    return parts.filter(function(value) { return value !== "" }).join(" · ")
  }

  function applySessions(output) {
    var parsed = []
    try {
      var value = JSON.parse(String(output || "[]"))
      if (Array.isArray(value)) parsed = value
    } catch (e) {
      console.warn("pi-sessions", "Invalid tracker output", e)
      return
    }

    var nextStatuses = ({})
    for (var i = 0; i < parsed.length; i++) {
      var session = parsed[i]
      var id = String(session.instanceId || "")
      nextStatuses[id] = String(session.status || "")
      if (initialized && previousStatuses[id]
          && previousStatuses[id] !== "done" && session.status === "done")
        enqueueNotification(session)
    }

    previousStatuses = nextStatuses
    sessions = parsed
    initialized = true
    if (selectedIndex >= sessions.length) selectedIndex = Math.max(0, sessions.length - 1)
  }

  function refresh() {
    if (!listProcess.running) listProcess.running = true
  }

  function activateSession(session) {
    if (!session || actionProcess.running) return
    actionProcess.command = [root.helperPath, "activate", String(session.instanceId)]
    actionProcess.running = true
    root.close()
  }

  function enqueueNotification(session) {
    notificationQueue = notificationQueue.concat([{
      id: String(session.instanceId),
      title: String(session.title || "Pi session")
    }])
    runNextNotification()
  }

  function runNextNotification() {
    if (notificationProcess.running || notificationQueue.length === 0) return
    var item = notificationQueue[0]
    notificationQueue = notificationQueue.slice(1)
    notificationProcess.command = [root.helperPath, "notify", item.id]
    notificationProcess.running = true
  }

  visible: sessions.length > 0
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    selectedIndex = 0
    refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Timer {
    interval: 2000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Process {
    id: listProcess
    running: false
    command: [root.helperPath, "list"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySessions(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("pi-sessions", text.trim())
    }
  }

  Process {
    id: actionProcess
    running: false
    onExited: root.refresh()
  }

  Process {
    id: notificationProcess
    running: false
    onExited: root.runNextNotification()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "π"
    active: root.needsAttention
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton && root.sessions.length > 0)
        root.activateSession(root.sessions[0])
      else
        root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(410))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (root.sessions.length === 0 || dy === 0) return
        root.selectedIndex = Math.max(0, Math.min(root.sessions.length - 1, root.selectedIndex + dy))
      }
      onActivateRequested: if (root.sessions.length > 0) root.activateSession(root.sessions[root.selectedIndex])
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: sessionFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: contentColumn
          width: sessionFlick.width
          spacing: Style.space(8)

          Text {
            visible: root.sessions.length === 0
            width: parent.width
            topPadding: Style.space(20)
            bottomPadding: Style.space(20)
            text: "No active Pi sessions"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
          }

          Repeater {
            model: root.sessions

            Column {
              required property var modelData
              required property int index

              readonly property bool startsSection: index === 0
                || root.sectionName(root.sessions[index - 1]) !== root.sectionName(modelData)

              width: contentColumn.width
              spacing: Style.space(4)

              PanelSeparator {
                visible: parent.startsSection && parent.index > 0
                foreground: root.foreground
              }

              PanelSectionHeader {
                visible: parent.startsSection
                width: parent.width
                text: root.sectionLabel(parent.modelData)
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              CursorSurface {
                width: parent.width
                height: Style.space(54)
                hasCursor: parent.index === root.selectedIndex
                foreground: root.foreground

                Column {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(3)

                  Text {
                    id: titleText
                    width: parent.width
                    textFormat: Text.PlainText
                    text: String(modelData.title || modelData.project || "Pi session")
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: root.sessionMeta(modelData)
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                MouseArea {
                  id: rowMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.selectedIndex = index
                  onClicked: root.activateSession(modelData)
                }

                PanelToolTip {
                  visible: rowMouse.containsMouse && titleText.truncated
                  text: titleText.text
                  fontFamily: root.fontFamily
                }
              }
            }
          }

        }
      }
    }
  }
}
