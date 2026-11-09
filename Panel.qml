import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Bar widget and panel for the MONKA G995W wireless mouse.
//
// Battery data arrives passively on the vendor status report (report 0x03),
// or from the BlueZ battery service in Bluetooth mode.  DPI, polling rate and
// lighting are written as vendor reports (HID feature reports on USB/2.4 GHz,
// or the BLE vendor channel over Bluetooth); the mouse cannot be read back, so
// the helper keeps the same kind of local profile the Windows app uses.
Panel {
  id: root
  moduleName: "io.github.cichowlasp.monka-g995w"
  ipcTarget: "io.github.cichowlasp.monka-g995w"
  manageIpc: false

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int lowThreshold: Math.max(5, Math.min(50, Number(setting("lowBatteryThreshold", 10))))
  readonly property int refreshSeconds: Math.max(15, Math.min(600, Number(setting("refreshIntervalSec", 60))))

  readonly property string helperPath:
    String(Qt.resolvedUrl("bin/monka-g995w")).replace("file://", "")

  // ── Battery ──────────────────────────────────────────────────────────────
  property bool haveData: false
  property bool charging: false
  property bool wired: false
  property bool bluetooth: false
  property bool lowNotified: false
  property int batteryPercent: -1
  property int batteryLevel: -1
  property int chargeState: -1
  property string rawReport: ""
  property string devicePath: ""
  property string failure: ""
  property double updatedAt: 0

  readonly property var defaultIcons: ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
  readonly property var chargingIcons: ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"]

  readonly property string batteryGlyph: {
    if (!haveData || batteryPercent < 0) return "󰂑"
    var index = Math.max(0, Math.min(9, Math.floor(batteryPercent / 10)))
    return charging ? chargingIcons[index] : defaultIcons[index]
  }

  readonly property string percentLabel:
    haveData && batteryPercent >= 0 ? batteryPercent + "%" : ""

  readonly property string statusText: {
    if (!haveData) return strings.t("panel.unknown")
    return charging ? strings.t("panel.charging") : strings.t("panel.onBattery")
  }

  readonly property string deviceText:
    bluetooth ? strings.t("panel.bluetooth")
    : wired ? strings.t("panel.wired")
    : strings.t("panel.wireless")

  readonly property string modeText:
    bluetooth ? strings.t("panel.metaBluetooth")
    : wired ? strings.t("panel.metaWired")
    : strings.t("panel.meta")

  readonly property string tooltipText: {
    if (!haveData) return strings.t("bar.tooltipUnknown")
    if (failure !== "") return strings.t("bar.tooltipUnknown")
    return (charging ? strings.t("bar.tooltipCharging") : strings.t("bar.tooltip")).arg(batteryPercent)
  }

  // ── Settings state (mirrors the helper's local profile) ──────────────────
  property var dpiValues: [800, 1600, 3200, 4800, 8000, 26000]
  property int dpiActive: 2
  readonly property var defaultDpiValues: [800, 1600, 3200, 4800, 8000, 26000]
  readonly property int defaultDpiActive: 2
  property int polling: 1000
  property int lightMode: 5
  property int lightBrightness: 3
  property int lightSpeed: 8
  property string lightColor: "#0000ff"
  property bool settingsBusy: false
  property bool settingsError: false
  property string settingsStatus: ""
  property string actionLabel: ""
  property bool dpiPending: false

  readonly property var lightModeOptions: [
    { value: "0", label: strings.t("light.off") },
    { value: "1", label: strings.t("light.static") },
    { value: "2", label: strings.t("light.breathing") },
    { value: "3", label: strings.t("light.neon") },
    { value: "4", label: strings.t("light.colorBreathing") },
    { value: "5", label: strings.t("light.staticDpi") },
    { value: "6", label: strings.t("light.breathingDpi") }
  ]

  readonly property var colorPresets: [
    "#ff0000", "#ff7f00", "#ffff00", "#7fff00",
    "#00ff80", "#00ffff", "#0000ff", "#ff00ff"
  ]

  implicitWidth: face.implicitWidth
  implicitHeight: face.implicitHeight

  function poll() {
    if (batteryProc.running) return
    batteryProc.running = true
  }

  function applyReport(text) {
    var data
    try {
      data = JSON.parse(String(text || "").trim())
    } catch (e) {
      failure = "parse"
      return
    }
    applyData(data)
  }

  function applyData(data) {
    if (!data || data.ok !== true) {
      failure = data && data.error ? String(data.error) : "unknown"
      haveData = false
      wired = false
      bluetooth = false
      return
    }

    failure = ""
    haveData = true
    wired = data.wired === true
    bluetooth = data.bluetooth === true || data.bt === true
    devicePath = String(data.device || "")
    rawReport = String(data.raw || "")
    batteryLevel = data.level === null || data.level === undefined ? -1 : Number(data.level)
    chargeState = data.chargeState === null || data.chargeState === undefined ? -1 : Number(data.chargeState)
    charging = data.charging === true
    var percent = data.percent === null || data.percent === undefined ? -1 : Number(data.percent)
    batteryPercent = isNaN(percent) ? -1 : percent
    updatedAt = Date.now()

    // One notification per low-battery episode. Clear after a small recovery
    // margin or while charging, so the next discharge can warn again.
    if (charging || batteryPercent < 0 || batteryPercent > lowThreshold + 5)
      lowNotified = false
    if (!charging && batteryPercent >= 0 && batteryPercent <= lowThreshold && !lowNotified) {
      lowNotified = true
      notifier.command = [
        "omarchy-notification-send",
        "--app-name", "MONKA G995W",
        "-g", "󰂃",
        "-u", "normal",
        "-i", "battery-caution",
        "-t", "30000",
        "-r", "9950",
        strings.t("notif.title"),
        strings.t("notif.body").arg(batteryPercent)
      ]
      notifier.running = true
    }
  }

  function handleWatch(line) {
    var data
    try {
      data = JSON.parse(String(line || "").trim())
    } catch (e) {
      return
    }
    if (!data || data.ok !== true) return
    if (data.bluetooth === true) bluetooth = true

    if (data.kind === "battery") {
      applyData(data)
      return
    }

    if (data.kind === "dpi") {
      var stage = Math.max(1, Math.min(6, Number(data.stage) || 1))
      dpiActive = stage
      var dpi = dpiValues[stage - 1]
      dpiNotifier.command = [
        "omarchy-notification-send",
        "--app-name", "MONKA G995W",
        "-g", "󰍽",
        "-u", "low",
        "-t", "2200",
        "-r", "9951",
        "DPI " + (dpi === undefined ? "" : dpi),
        strings.t("panel.stage").arg(stage) + " · "
          + (root.bluetooth ? strings.t("panel.bluetooth")
             : root.wired ? strings.t("panel.wired")
             : strings.t("panel.wireless"))
      ]
      dpiNotifier.running = true
      return
    }

    if (data.kind === "light") {
      lightMode = Math.max(0, Math.min(6, Number(data.mode) || 0))
    }
  }

  function loadSettings() {
    if (stateProc.running) return
    stateProc.running = true
  }

  function applyStateObject(state) {
    if (!state) return
    if (state.dpi) {
      if (state.dpi.values && state.dpi.values.length >= 6)
        dpiValues = state.dpi.values.slice(0, 6)
      if (state.dpi.active !== undefined)
        dpiActive = Math.max(1, Math.min(6, Number(state.dpi.active)))
    }
    if (state.polling !== undefined)
      polling = Number(state.polling)
    if (state.light) {
      lightMode = Number(state.light.mode)
      lightBrightness = Number(state.light.brightness)
      lightSpeed = Number(state.light.speed)
      lightColor = String(state.light.color || "#0000ff").toLowerCase()
    }
  }

  function handleState(text) {
    var data
    try {
      data = JSON.parse(String(text || "").trim())
    } catch (e) {
      settingsStatus = strings.t("panel.configMissing")
      settingsError = true
      return
    }
    if (data && data.ok === true && data.state) {
      applyStateObject(data.state)
      settingsStatus = strings.t("panel.loaded")
      settingsError = false
    } else {
      settingsStatus = strings.t("panel.configMissing")
      settingsError = true
    }
  }

  function runAction(label, args) {
    if (settingsBusy) return
    settingsBusy = true
    settingsError = false
    actionLabel = label
    settingsStatus = ""
    var command = [root.helperPath]
    for (var i = 0; i < args.length; i++) command.push(args[i])
    actionProc.command = command
    actionProc.running = true
  }

  function handleActionResult(text) {
    settingsBusy = false
    var data
    try {
      data = JSON.parse(String(text || "").trim())
    } catch (e) {
      settingsStatus = strings.t("panel.writeFailed").arg(actionLabel).arg("parse")
      settingsError = true
      flushDpiPending()
      return
    }
    if (!data || data.ok !== true) {
      settingsStatus = strings.t("panel.writeFailed")
        .arg(actionLabel)
        .arg(data && data.error ? String(data.error) : "error")
      settingsError = true
      flushDpiPending()
      return
    }
    if (data.state) applyStateObject(data.state)
    settingsError = false
    settingsStatus = strings.t("panel.writeOk").arg(actionLabel)
    flushDpiPending()
  }

  function flushDpiPending() {
    if (dpiPending) {
      dpiPending = false
      dpiApplyTimer.restart()
    }
  }

  function setDpiValue(index, value) {
    var rounded = Math.max(50, Math.min(26000, Math.round(value / 50) * 50))
    var next = dpiValues.slice()
    next[index] = rounded
    dpiValues = next
    dpiApplyTimer.restart()
  }

  function applyDpi() {
    if (dpiApplyTimer.running) dpiApplyTimer.stop()
    if (settingsBusy) {
      dpiPending = true
      return
    }
    var parts = []
    for (var i = 0; i < dpiValues.length; i++) parts.push(String(dpiValues[i]))
    runAction(strings.t("panel.dpi"),
              ["set-dpi", parts.join(","), String(dpiActive), "--fast"])
  }

  function resetDpi() {
    dpiValues = defaultDpiValues.slice()
    dpiActive = defaultDpiActive
    applyDpi()
  }

  function setPolling(hz) {
    polling = hz
    runAction(strings.t("panel.polling"), ["set-poll", String(hz)])
  }

  function applyLight() {
    runAction(strings.t("panel.lighting"), [
      "set-light",
      String(lightMode),
      String(lightBrightness),
      String(lightSpeed),
      lightColor
    ])
  }

  function setLightColor(value) {
    lightColor = String(value).toLowerCase()
  }

  Process {
    id: batteryProc
    command: [root.helperPath, "battery"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyReport(text)
    }
  }

  // Long-lived status reader: battery notifications plus the events the mouse
  // sends when its own DPI/lighting buttons are used.
  Process {
    id: watchProc
    command: [root.helperPath, "watch"]
    stdout: SplitParser {
      onRead: function(line) { root.handleWatch(line) }
    }
    onExited: {
      watchRestart.start()
    }
  }

  Timer {
    id: watchRestart
    interval: 2000
    repeat: false
    onTriggered: watchProc.running = true
  }

  // Bluetooth button events (the mouse's own DPI/lighting buttons) arrive on
  // the BLE vendor notification channel rather than the USB status interface.
  Process {
    id: btWatchProc
    command: [root.helperPath, "bt-watch"]
    stdout: SplitParser {
      onRead: function(line) { root.handleWatch(line) }
    }
    onExited: {
      btWatchRestart.start()
    }
  }

  Timer {
    id: btWatchRestart
    interval: 5000
    repeat: false
    onTriggered: btWatchProc.running = true
  }

  Timer {
    id: dpiApplyTimer
    interval: 250
    repeat: false
    onTriggered: root.applyDpi()
  }

  Process {
    id: dpiNotifier
  }

  Process {
    id: notifier
  }

  Process {
    id: stateProc
    command: [root.helperPath, "state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleState(text)
    }
  }

  Process {
    id: actionProc
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleActionResult(text)
    }
  }

  Timer {
    interval: root.refreshSeconds * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.poll()
  }

  IpcHandler {
    target: root.ipcTarget

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }

    function refresh(): string {
      root.poll()
      root.loadSettings()
      return "ok"
    }

    function applyDpi(): string {
      root.applyDpi()
      return "ok"
    }

    function resetDpi(): string {
      root.resetDpi()
      return "ok"
    }

    function applyLight(): string {
      root.applyLight()
      return "ok"
    }

    function setPolling(hz: int): string {
      root.setPolling(hz)
      return "ok"
    }

    function status(): string {
      return root.settingsStatus
    }
  }

  onOpenedChanged: {
    if (opened) {
      root.poll()
      root.loadSettings()
    }
  }

  Component.onCompleted: {
    root.loadSettings()
    watchProc.running = true
    btWatchProc.running = true
  }

  BarIconButton {
    id: face
    bar: root.bar
    text: root.batteryGlyph
    labelText: root.percentLabel
    active: root.haveData && root.charging
    dimmed: !root.haveData
    tooltipText: root.tooltipText

    // BarIconButton normally keeps a fixed 27px icon slot.  With a label the
    // painted content is wider than that slot, so it spilled over the icons
    // next to it.  Grow the slot to contain icon + label and leave the same
    // breathing room an icon-only slot has.
    readonly property real labelPx: root.percentLabel === ""
      ? 0
      : faceLabelMeasure.implicitWidth + Style.space(4)
    fixedWidth: root.percentLabel === ""
      ? Style.bar.iconSlot
      : Math.max(Style.bar.iconSlot,
                 Math.max(Style.bar.iconSize, Style.bar.iconCanvas) + labelPx)
        + Style.space(24)

    Text {
      id: faceLabelMeasure
      visible: false
      text: root.percentLabel
      font.family: root.fontFamily
      font.pixelSize: Style.bar.iconFont
    }

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.poll()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: face
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(900))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTextKey: function(t) {
        var key = String(t).toLowerCase()
        if (key === "r") { root.poll(); root.loadSettings() }
      }
    }

    Flickable {
      id: panelFlick
      anchors.fill: parent
      contentWidth: width
      contentHeight: column.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      interactive: contentHeight > height
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: column
        width: panelFlick.width
        spacing: Style.space(12)

        Item {
          width: parent.width
          height: Style.space(4)
        }

        PanelHero {
          width: parent.width
          title: strings.t("panel.title")
          meta: root.modeText
          detail: root.haveData && root.batteryPercent >= 0
                  ? Commons.I18n.formatNumber(root.batteryPercent) + "%"
                  : "—"
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconComponent: Component {
            Text {
              textFormat: Text.PlainText
              text: root.batteryGlyph
              color: root.haveData && root.batteryPercent <= root.lowThreshold && !root.charging
                     ? root.urgent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        // ── Battery ───────────────────────────────────────────────────────
        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.failure === ""
                ? root.statusText + " · " + root.deviceText
                : (root.failure === "permission-denied" || root.failure === "device-not-found")
                  ? strings.t("panel.unavailable")
                  : strings.t("panel.noReport")
          color: root.failure === "" ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          visible: root.failure === "permission-denied"
          textFormat: Text.PlainText
          text: strings.t("panel.permission")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          visible: root.haveData && root.rawReport !== ""
          textFormat: Text.PlainText
          text: (root.batteryLevel >= 0
                 ? strings.t("panel.levelShort") + " " + root.batteryLevel + " · "
                 : "")
                + root.rawReport
                + (root.updatedAt > 0
                   ? " · " + Qt.formatTime(new Date(root.updatedAt), "HH:mm:ss")
                   : "")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          visible: root.bluetooth
          textFormat: Text.PlainText
          text: strings.t("panel.bluetoothHint")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        PanelSeparator { foreground: root.foreground }

        // ── DPI ───────────────────────────────────────────────────────────
        Item {
          width: parent.width
          height: Math.max(dpiHeader.implicitHeight, dpiActiveRow.implicitHeight)

          PanelSectionHeader {
            id: dpiHeader
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: strings.t("panel.dpi")
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Row {
            id: dpiActiveRow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            Text {
              height: Style.spacing.controlHeight
              verticalAlignment: Text.AlignVCenter
              textFormat: Text.PlainText
              text: strings.t("panel.active")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Repeater {
              model: 6

              delegate: Button {
                text: "" + (index + 1)
                bordered: true
                selected: root.dpiActive === index + 1
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: {
                  root.dpiActive = index + 1
                  root.applyDpi()
                }
              }
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(2)

          Repeater {
            model: 6

            delegate: Item {
              width: column.width
              height: Math.max(stageText.implicitHeight, dpiSlider.implicitHeight, dpiValueField.implicitHeight)

              Text {
                id: stageText
                width: Style.space(64)
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: strings.t("panel.stage").arg(index + 1)
                color: index + 1 === root.dpiActive ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              PanelSlider {
                id: dpiSlider
                anchors.left: stageText.right
                anchors.right: dpiValueField.left
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                bar: root.bar
                minimum: 50
                maximum: 26000
                step: 50
                integer: true
                value: root.dpiValues[index]
                onReleased: function(v) { root.setDpiValue(index, v) }
              }

              TextField {
                id: dpiValueField
                width: Style.space(84)
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: String(root.dpiValues[index])
                horizontalAlignment: TextInput.AlignRight
                foreground: root.foreground
                accent: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                horizontalPadding: Style.space(4)
                verticalPadding: Style.space(2)
                validator: IntValidator { bottom: 50; top: 26000 }
                background: Rectangle {
                  color: dpiValueField.hovered || dpiValueField.activeFocus
                    ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
                    : "transparent"
                  radius: Style.space(3)
                  border.width: dpiValueField.activeFocus ? 1 : 0
                  border.color: root.dim
                }
                onActiveFocusChanged: if (activeFocus) selectAll()
                onEditingFinished: {
                  var value = Number(text)
                  if (!isNaN(value) && value > 0) root.setDpiValue(index, value)
                  text = String(root.dpiValues[index])
                }
                Connections {
                  target: root
                  function onDpiValuesChanged() {
                    if (!dpiValueField.activeFocus)
                      dpiValueField.text = String(root.dpiValues[index])
                  }
                }
              }
            }
          }
        }

        Button {
          text: strings.t("panel.resetDpi")
          bordered: true
          enabled: !root.settingsBusy
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.resetDpi()
        }

        PanelSeparator { foreground: root.foreground }

        // ── Polling rate ──────────────────────────────────────────────────
        Item {
          width: parent.width
          height: Math.max(pollingHeader.implicitHeight, pollingRow.implicitHeight)

          PanelSectionHeader {
            id: pollingHeader
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: strings.t("panel.polling")
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Row {
            id: pollingRow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            Repeater {
              model: [125, 250, 500, 1000]

              delegate: Button {
                text: "" + modelData
                bordered: true
                selected: root.polling === modelData
                enabled: !root.settingsBusy
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.setPolling(modelData)
              }
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        // ── Lighting ──────────────────────────────────────────────────────
        Item {
          width: parent.width
          height: Math.max(lightingHeader.implicitHeight, applyLightButton.implicitHeight)

          PanelSectionHeader {
            id: lightingHeader
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: strings.t("panel.lighting")
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Button {
            id: applyLightButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: strings.t("panel.applyLight")
            bordered: true
            enabled: !root.settingsBusy
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.applyLight()
          }
        }

        Dropdown {
          width: parent.width
          label: strings.t("panel.mode")
          value: String(root.lightMode)
          options: root.lightModeOptions
          foreground: root.foreground
          fontFamily: root.fontFamily
          onChanged: function(value) { root.lightMode = Number(value) }
        }

        Row {
          width: parent.width
          spacing: Style.space(12)

          Column {
            width: (parent.width - Style.space(12)) / 2
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: strings.t("panel.brightness")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Row {
              width: parent.width
              spacing: Style.space(6)

              PanelSlider {
                width: parent.width - Style.space(30)
                bar: root.bar
                minimum: 1
                maximum: 8
                step: 1
                integer: true
                value: root.lightBrightness
                onReleased: function(v) { root.lightBrightness = Math.round(v) }
              }

              Text {
                width: Style.space(24)
                height: Style.spacing.controlHeight
                verticalAlignment: Text.AlignVCenter
                textFormat: Text.PlainText
                text: String(root.lightBrightness)
                color: root.foreground
                horizontalAlignment: Text.AlignRight
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }

          Column {
            width: (parent.width - Style.space(12)) / 2
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: strings.t("panel.speed")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Row {
              width: parent.width
              spacing: Style.space(6)

              PanelSlider {
                width: parent.width - Style.space(30)
                bar: root.bar
                minimum: 4
                maximum: 8
                step: 1
                integer: true
                value: root.lightSpeed
                onReleased: function(v) { root.lightSpeed = Math.round(v) }
              }

              Text {
                width: Style.space(24)
                height: Style.spacing.controlHeight
                verticalAlignment: Text.AlignVCenter
                textFormat: Text.PlainText
                text: String(root.lightSpeed)
                color: root.foreground
                horizontalAlignment: Text.AlignRight
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }
        }

        Item {
          width: parent.width
          height: Math.max(colorLabel.implicitHeight, colorSwatch.height, colorPresetsRow.height, colorHex.implicitHeight)

          Text {
            id: colorLabel
            width: Style.space(64)
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: strings.t("panel.color")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Rectangle {
            id: colorSwatch
            width: Style.space(24)
            height: Style.space(24)
            anchors.left: colorLabel.right
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            radius: Style.space(4)
            color: root.lightColor
            border.width: 1
            border.color: root.dim
          }

          Row {
            id: colorPresetsRow
            anchors.left: colorSwatch.right
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            Repeater {
              model: root.colorPresets

              delegate: Rectangle {
                width: Style.space(20)
                height: Style.space(20)
                radius: Style.space(4)
                color: modelData
                border.width: root.lightColor === modelData ? 2 : 1
                border.color: root.lightColor === modelData ? root.foreground : root.dim

                MouseArea {
                  anchors.fill: parent
                  onClicked: root.setLightColor(modelData)
                }
              }
            }
          }

          Text {
            id: colorHex
            anchors.left: colorPresetsRow.right
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.lightColor
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          width: parent.width
          visible: root.settingsStatus !== ""
          textFormat: Text.PlainText
          text: root.settingsStatus
          color: root.settingsError ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Item {
          width: parent.width
          height: Style.space(4)
        }
      }
    }
  }
}
