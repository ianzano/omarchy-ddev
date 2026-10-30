import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Panel {
    id: root
    moduleName: "ianzano.ddev"
    ipcTarget: "ianzano.ddev"
    manageIpc: false
    IpcHandler {
        target: root.ipcTarget
        function open(): void { root.open() }
        function close(): void { root.close() }
        function toggle(): void { root.toggle() }
        function refresh(): void { root.refresh() }
        function status(): string { return JSON.stringify({ projects: root.projects, warning: root.warning, busy: root.busy }) }
    }
    property var projects: []
    property var snapshots: []
    property string selectedName: ""
    property string warning: ""
    property var jobs: ({})
    readonly property bool busy: Object.keys(jobs).length > 0
    readonly property bool globalBusy: !!jobs["__all__"]
    property double clockNow: Date.now()
    function projectBusy(name) { return globalBusy || !!jobs[name] }
    function actionFor(name) { return globalBusy ? "poweroff" : jobs[name] ? jobs[name].actionName : "" }
    function elapsedFor(name) {
        var job = globalBusy ? jobs["__all__"] : jobs[name]
        return job ? Math.max(0, Math.floor((clockNow - job.startedAt) / 1000)) : 0
    }
    function canRun(action, name) {
        if (action === "poweroff") return !busy
        if (projectBusy(name)) return false
        if (action === "restart") return projects.some(p => p.name === name && p.status === "running")
        return true
    }
    property string pendingRestore: ""
    property string pendingLabel: ""
    property string query: ""
    property bool settingsOpen: false
    property bool poweroffConfirm: false
    property var projectOutputs: ({})
    function outputFor(name) { return projectOutputs[name] || ({}) }
    function updateOutput(name, patch) {
        var next = Object.assign({}, projectOutputs)
        next[name] = Object.assign({}, next[name] || {}, patch)
        projectOutputs = next
    }
    function previewOutput(text) {
        var lines = String(text || "").replace(/\s+$/, "").split("\n")
        return lines.slice(-6).join("\n").slice(-1800)
    }
    property int refreshSeconds: Number(setting("refreshIntervalSec", 15))
    readonly property color success: "#86c995"
    readonly property color progress: "#e4b76c"
    readonly property color muted: Commons.Color.muted
    function actionLabelFor(action) { return ({poweroff: "Powering off DDEV", start: "Starting", stop: "Stopping", restart: "Restarting", snapshot: "Creating snapshot", restore: "Restoring database", snapshots: "Loading snapshots", browse: "Opening browser", mailpit: "Opening Mailpit", folder: "Opening folder"})[action] || "Working" }
    function persistRefresh(value) {
        refreshSeconds = value
        if (!bar || !bar.shell || typeof bar.shell.updateEntryInline !== "function") return
        var entry = {id: moduleName}
        for (var key in settings) if (key !== "id") entry[key] = settings[key]
        entry.refreshIntervalSec = value
        bar.shell.updateEntryInline(moduleName, entry)
    }
    function cleanOutput(text) {
        return text.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "").replace(/\r\n/g, "\n").replace(/\r/g, "\n")
    }
    readonly property string bridge: Qt.resolvedUrl("backend.py").toString().replace(/^file:\/\//, "")
    readonly property color foreground: Commons.Color.foreground
    readonly property int runningCount: projects.filter(p => p.status === "running").length
    readonly property var filteredProjects: projects.filter(p => (p.name + " " + p.approot).toLowerCase().indexOf(query.toLowerCase()) >= 0)
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    function refresh() {
        if (!listing.running) listing.running = true
    }
    function execute(action, name, extra) {
        if (!canRun(action, name)) return false
        var job = operationFactory.createObject(root, {
            projectName: name,
            actionName: action,
            startedAt: Date.now(),
            command: ["python3", bridge, action, name].concat(extra ? [extra] : [])
        })
        if (!job) return false
        var next = Object.assign({}, jobs)
        next[name] = job
        jobs = next
        clockNow = Date.now()
        if (action !== "snapshots") updateOutput(name, {text: "", message: "", failed: false, action: action, expanded: false, open: true})
        job.running = true
        return true
    }
    function selectProject(name) {
        if (projectBusy(name)) return
        selectedName = selectedName === name ? "" : name
        snapshots = []
        pendingRestore = ""
        if (selectedName) execute("snapshots", name, "")
    }
    function finishJob(job, exitCode) {
        if (!job.receivedResult) {
            job.commandFailed = true
            updateOutput(job.projectName, {failed: true, message: "Command exited without a result (" + exitCode + ")", text: job.capturedOutput, open: true})
        }
        var next = Object.assign({}, jobs)
        delete next[job.projectName]
        jobs = next
        refresh()
        var reloadSnapshots = !job.commandFailed && (job.actionName === "snapshot" || job.actionName === "restore") && selectedName === job.projectName
        var projectName = job.projectName
        Qt.callLater(function() {
            job.destroy()
            if (reloadSnapshots && root.selectedName === projectName) root.execute("snapshots", projectName, "")
        })
    }
    function sizeLabel(bytes) {
        if (bytes >= 1073741824) return (bytes / 1073741824).toFixed(1) + " GB"
        return bytes >= 1048576 ? (bytes / 1048576).toFixed(1) + " MB" : (bytes / 1024).toFixed(0) + " KB"
    }
    Timer { interval: 1000; running: root.busy; repeat: true; onTriggered: root.clockNow = Date.now() }
    Component.onCompleted: refresh()
    onOpenedChanged: if (opened) refresh()
    Timer {
        interval: Math.max(5, root.refreshSeconds) * 1000
        running: true
        repeat: true
        onTriggered: root.refresh()
    }
    Process {
        id: listing
        command: ["python3", root.bridge, "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var data = JSON.parse(text)
                    if (data.ok) { root.projects = data.projects; root.warning = data.warning || "" }
                    else root.warning = data.message
                } catch (error) { root.warning = "Could not read DDEV status: " + error }
            }
        }
        stderr: StdioCollector { onStreamFinished: if (text.trim()) root.warning = text.trim() }
    }
    Component {
        id: operationFactory
        Process {
            id: job
            property string projectName: ""
            property string actionName: ""
            property double startedAt: 0
            property string capturedOutput: ""
            property bool commandFailed: false
            property bool receivedResult: false
            stdout: SplitParser {
                onRead: function(line) {
                    if (!line.trim()) return
                    try {
                        var data = JSON.parse(line)
                        if (data.event === "output") {
                            job.capturedOutput = (job.capturedOutput + root.cleanOutput(data.text)).slice(-24000)
                            root.updateOutput(job.projectName, {text: job.capturedOutput})
                            return
                        }
                        job.receivedResult = true
                        job.commandFailed = !data.ok
                        if (job.actionName === "snapshots" && data.ok) {
                            if (root.selectedName === job.projectName) {
                                root.snapshots = data.snapshots
                                if (!root.snapshots.some(s => s.path === root.pendingRestore)) root.pendingRestore = ""
                            }
                        } else {
                            if (data.message) job.capturedOutput = root.cleanOutput(data.message)
                            root.updateOutput(job.projectName, {text: job.capturedOutput, message: data.ok ? "Completed" : "Command failed", failed: !data.ok, open: true})
                        }
                    } catch (error) {
                        job.commandFailed = true
                        root.updateOutput(job.projectName, {message: "Could not read command result: " + error, failed: true, open: true})
                    }
                }
            }
            stderr: StdioCollector {
                onStreamFinished: if (text.trim()) {
                    job.commandFailed = true
                    root.updateOutput(job.projectName, {message: text.trim(), failed: true, open: true})
                }
            }
            onExited: function(exitCode, exitStatus) { root.finishJob(job, exitCode) }
        }
    }
    WidgetButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: (root.busy ? "󰔟 " : "󰡨 ") + (root.warning ? "?" : root.runningCount) + "/" + root.projects.length
        onPressed: function(code) { if (code === Qt.MiddleButton) root.refresh(); else root.toggle() }
    }
    KeyboardPanel {
        id: panel
        anchorItem: button
        owner: root
        bar: root.bar
        open: root.opened
        focusTarget: content
        contentWidth: panel.fittedContentWidth(Style.space(510))
        contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(680))
        Flickable {
            id: panelScroll
            objectName: "projectPanelScroll"
            anchors.fill: parent
            clip: true
            contentWidth: width
            contentHeight: content.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick
            Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }
            Column {
                id: content
                width: parent.width
                spacing: Style.space(10)
                focus: true
                Keys.onEscapePressed: {
                    if (root.poweroffConfirm) root.poweroffConfirm = false
                    else if (root.pendingRestore) root.pendingRestore = ""
                    else root.close()
                }
                RowLayout {
                    width: parent.width
                    spacing: Style.space(12)
                    Rectangle {
                        implicitWidth: Style.space(44); implicitHeight: implicitWidth
                        Layout.alignment: Qt.AlignVCenter
                        radius: Style.space(10); color: Util.alpha(Commons.Color.accent, 0.12)
                        Label { anchors.centerIn: parent; text: "󰡨"; font.pixelSize: Style.space(25); color: Commons.Color.accent }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.minimumWidth: 0
                        Layout.alignment: Qt.AlignVCenter
                        spacing: Style.space(3)
                        Label { Layout.fillWidth: true; elide: Text.ElideRight; text: "DDEV Projects"; font.bold: true; font.pixelSize: Style.font.title }
                        Label { Layout.fillWidth: true; elide: Text.ElideRight; text: root.runningCount + " running  /  " + root.projects.length + " registered"; color: root.muted; font.pixelSize: Style.font.caption }
                    }
                    RowLayout {
                        spacing: Style.space(6)
                        Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                        Item {
                            Layout.preferredWidth: Style.space(18)
                            Layout.preferredHeight: Style.space(32)
                            Spinner { anchors.centerIn: parent; visible: listing.running || root.globalBusy; tint: Commons.Color.accent }
                        }
                        IconAction { objectName: "refreshProjectsButton"; iconText: "󰑐"; tooltipText: "Refresh projects"; enabled: !listing.running; onClicked: root.refresh() }
                        IconAction {
                            objectName: "poweroffDdevButton"
                            iconText: "󰐥"
                            foreground: Commons.Color.urgent
                            tooltipText: "Power off DDEV · stop all projects"
                            enabled: !root.busy
                            onClicked: root.poweroffConfirm = !root.poweroffConfirm
                        }
                        IconAction { objectName: "panelSettingsButton"; iconText: "󰒓"; tooltipText: "Panel settings"; selected: root.settingsOpen; onClicked: root.settingsOpen = !root.settingsOpen }
                    }
                }
                Column {
                    width: parent.width
                    spacing: Style.space(8)
                    visible: root.poweroffConfirm
                    Label { width: parent.width; wrapMode: Text.Wrap; text: "Power off DDEV? This stops all DDEV projects and shared services."; color: Commons.Color.urgent }
                    Row {
                        spacing: Style.space(8)
                        Action { text: "Cancel"; onClicked: root.poweroffConfirm = false }
                        Action {
                            objectName: "confirmPoweroffDdevButton"
                            text: "Power off DDEV"
                            iconText: "󰐥"
                            foreground: Commons.Color.urgent
                            enabled: !root.busy
                            onClicked: { root.poweroffConfirm = false; root.execute("poweroff", "__all__", "") }
                        }
                    }
                }
                Column {
                    width: parent.width
                    spacing: Style.space(6)
                    visible: !!root.outputFor("__all__").action
                    Label {
                        width: parent.width; wrapMode: Text.Wrap
                        text: root.globalBusy ? "Powering off DDEV… · " + root.elapsedFor("__all__") + " s" : "DDEV poweroff · " + (root.outputFor("__all__").message || "")
                        color: root.outputFor("__all__").failed ? Commons.Color.urgent : root.foreground
                    }
                    Controls.TextArea {
                        width: parent.width
                        text: root.outputFor("__all__").expanded ? root.outputFor("__all__").text || "Waiting for DDEV output…" : root.previewOutput(root.outputFor("__all__").text || "Waiting for DDEV output…")
                        readOnly: true; selectByMouse: true; wrapMode: TextEdit.Wrap; textFormat: TextEdit.PlainText
                        color: root.foreground; font.family: "monospace"; font.pixelSize: Style.font.caption
                        background: Rectangle { color: Util.alpha(Commons.Color.background, 0.65); radius: Style.space(6) }
                    }
                    Row {
                        spacing: Style.space(6)
                        Action { text: root.outputFor("__all__").expanded ? "Show less" : "Show all output"; onClicked: root.updateOutput("__all__", {expanded: !root.outputFor("__all__").expanded}) }
                        Action { text: "Dismiss"; enabled: !root.busy; onClicked: root.updateOutput("__all__", {action: ""}) }
                    }
                }
                Column {
                    visible: root.settingsOpen
                    width: parent.width
                    spacing: Style.space(8)
                    RowLayout {
                        width: parent.width
                        Label { text: "Refresh interval"; Layout.fillWidth: true; color: root.muted }
                        Label { text: refreshSlider.liveValue.toFixed(0) + " s"; color: Commons.Color.accent }
                    }
                    PanelSlider {
                        id: refreshSlider
                        width: parent.width
                        bar: root.bar
                        minimum: 5; maximum: 60; step: 5; integer: true
                        value: root.refreshSeconds
                        fillColor: Commons.Color.accent
                        knobColor: Commons.Color.accent
                        trackColor: Util.alpha(root.foreground, 0.15)
                        onReleased: function(value) { root.persistRefresh(value) }
                    }
                }
                Label {
                    width: parent.width
                    visible: text !== ""
                    text: root.warning
                    color: Commons.Color.urgent
                    wrapMode: Text.Wrap
                }
                TextField {
                    width: parent.width
                    placeholderText: "Filter projects…"
                    onTextChanged: root.query = text
                }
                Label {
                    visible: root.filteredProjects.length === 0
                    text: listing.running ? "Loading projects…" : "No matching registered projects."
                }
                Repeater {
                    model: root.filteredProjects
                    Rectangle {
                        id: projectRow
                        objectName: "projectCard-" + modelData.name
                        readonly property var consoleState: root.outputFor(modelData.name)
                        readonly property bool consoleBusy: !!root.jobs[modelData.name] && root.actionFor(modelData.name) !== "snapshots"
                        required property var modelData
                        readonly property bool busy: root.projectBusy(modelData.name)
                        readonly property bool running: modelData.status === "running"
                        readonly property color statusColor: busy ? root.progress : (running ? root.success : (modelData.status === "stopped" ? root.muted : root.progress))
                        width: content.width
                        implicitHeight: projectContent.implicitHeight + Style.space(24)
                        radius: Style.space(10)
                        color: Util.alpha(projectRow.statusColor, busy ? 0.08 : 0.035)
                        border.width: 1
                        border.color: Util.alpha(projectRow.statusColor, busy ? 0.5 : 0.18)
                        Behavior on color { ColorAnimation { duration: 180 } }
                        Column {
                            id: projectContent
                            anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.space(12) }
                            spacing: Style.space(9)
                            Item {
                                width: parent.width
                                implicitHeight: Math.max(projectInfo.implicitHeight, powerSwitch.implicitHeight, restartProject.implicitHeight)
                                RowLayout {
                                    id: projectInfo
                                    anchors.left: parent.left
                                    anchors.right: restartProject.left
                                    anchors.rightMargin: Style.space(12)
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Style.space(10)
                                Rectangle { width: Style.space(8); height: width; radius: width / 2; color: projectRow.statusColor; visible: !projectRow.busy }
                                Spinner { visible: projectRow.busy; tint: root.progress }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    Layout.minimumWidth: 0
                                    spacing: Style.space(2)
                                    Label { Layout.fillWidth: true; elide: Text.ElideRight; text: projectRow.modelData.name; font.bold: true; font.pixelSize: Style.font.subtitle }
                                    Label { Layout.fillWidth: true; elide: Text.ElideRight; text: projectRow.busy ? root.actionLabelFor(root.actionFor(projectRow.modelData.name)) + "… · " + root.elapsedFor(projectRow.modelData.name) + " s" : (projectRow.running ? "Running" : projectRow.modelData.status === "stopped" ? "Stopped" : projectRow.modelData.status); color: projectRow.statusColor; font.pixelSize: Style.font.caption }
                                }
                                Label { text: projectRow.modelData.type; color: root.muted; font.pixelSize: Style.font.caption }
                                }
                                IconAction {
                                    id: restartProject
                                    objectName: "restartProject-" + projectRow.modelData.name
                                    anchors.right: powerSwitch.left
                                    anchors.rightMargin: Style.space(6)
                                    anchors.verticalCenter: parent.verticalCenter
                                    iconText: "󰑐"
                                    tooltipText: projectRow.running ? "Restart project" : "Start the project before restarting"
                                    enabled: !projectRow.busy && projectRow.running
                                    onClicked: root.execute("restart", projectRow.modelData.name, "")
                                }
                                ToggleSwitch {
                                    id: powerSwitch
                                    objectName: "powerSwitch-" + projectRow.modelData.name
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    checked: projectRow.busy && (root.actionFor(projectRow.modelData.name) === "start" || root.actionFor(projectRow.modelData.name) === "stop") ? root.actionFor(projectRow.modelData.name) === "start" : projectRow.running
                                    busy: projectRow.busy
                                    accent: root.success
                                    rounded: true
                                    opacity: root.globalBusy ? 0.45 : 1
                                    activeFocusOnTab: true
                                    Keys.onSpacePressed: if (!projectRow.busy) root.execute(projectRow.running ? "stop" : "start", projectRow.modelData.name, "")
                                    Keys.onReturnPressed: if (!projectRow.busy) root.execute(projectRow.running ? "stop" : "start", projectRow.modelData.name, "")
                                    onToggled: root.execute(projectRow.running ? "stop" : "start", projectRow.modelData.name, "")
                                    PanelToolTip { visible: parent.containsMouse; text: projectRow.running ? "Stop project" : "Start project" }
                                }
                            }
                            Label { width: parent.width; text: projectRow.modelData.shortroot || projectRow.modelData.approot; elide: Text.ElideMiddle; color: root.muted; font.pixelSize: Style.font.caption }
                            RowLayout {
                                width: parent.width
                                spacing: Style.space(6)
                                Action { text: "Open site"; iconText: "󰖟"; foreground: root.success; enabled: !projectRow.busy && projectRow.running; onClicked: root.execute("browse", projectRow.modelData.name, "") }
                                Action { text: "Snapshots"; iconText: "󰆼"; selected: root.selectedName === projectRow.modelData.name; enabled: !projectRow.busy; onClicked: root.selectProject(projectRow.modelData.name) }
                                Item { Layout.fillWidth: true }
                                IconAction { iconText: "󰇮"; tooltipText: "Open Mailpit"; enabled: !projectRow.busy && projectRow.running; onClicked: root.execute("mailpit", projectRow.modelData.name, "") }
                                IconAction { iconText: "󰉋"; tooltipText: "Open project folder"; enabled: !projectRow.busy; onClicked: root.execute("folder", projectRow.modelData.name, "") }
                            }
                            Rectangle {
                                width: parent.width
                                height: 1
                                color: Util.alpha(root.foreground, 0.12)
                                visible: root.selectedName === projectRow.modelData.name || !!projectRow.consoleState.action || !!projectRow.consoleState.message
                            }
                            Column {
                                objectName: "snapshots-" + projectRow.modelData.name
                                width: parent.width
                                spacing: Style.space(8)
                                visible: root.selectedName === projectRow.modelData.name
                                RowLayout {
                                    width: parent.width
                                    Label { text: "Database snapshots"; font.bold: true; Layout.fillWidth: true }
                                    IconAction { iconText: "󰅖"; tooltipText: "Close snapshots"; enabled: !projectRow.busy; onClicked: root.selectProject(projectRow.modelData.name) }
                                }
                                RowLayout {
                                    width: parent.width
                                    TextField { id: snapshotName; Layout.fillWidth: true; placeholderText: "Snapshot name (optional)" }
                                    Action { text: "Create"; iconText: "󰐕"; enabled: !projectRow.busy; onClicked: root.execute("snapshot", root.selectedName, snapshotName.text.trim()) }
                                    IconAction { iconText: "󰑐"; tooltipText: "Reload snapshots"; enabled: !projectRow.busy; onClicked: root.execute("snapshots", root.selectedName, "") }
                                }
                                Label { text: "Local project snapshots, newest first. DDEV may start a stopped project."; width: parent.width; wrapMode: Text.Wrap; opacity: 0.65 }
                                Label { visible: root.snapshots.length === 0; text: projectRow.busy && root.actionFor(projectRow.modelData.name) === "snapshots" ? "Loading snapshots…" : "No local snapshots found." }
                                Repeater {
                                    model: root.selectedName === projectRow.modelData.name ? root.snapshots : []
                                    Rectangle {
                                        id: snapshotRow
                                        objectName: "snapshotCard-" + modelData.name
                                        required property var modelData
                                        width: parent.width
                                        implicitHeight: Math.max(snapshotDetails.implicitHeight, restoreSnapshot.implicitHeight) + Style.space(20)
                                        radius: Style.space(6)
                                        color: Util.alpha(root.foreground, 0.035)
                                        border.width: 1
                                        border.color: Util.alpha(root.pendingRestore === modelData.path ? Commons.Color.urgent : root.foreground, 0.2)
                                        Column {
                                            id: snapshotDetails
                                            objectName: "snapshotDetails-" + snapshotRow.modelData.name
                                            anchors.left: parent.left
                                            anchors.leftMargin: Style.space(10)
                                            anchors.right: restoreSnapshot.left
                                            anchors.rightMargin: Style.space(12)
                                            anchors.verticalCenter: parent.verticalCenter
                                            spacing: Style.space(3)
                                            Label { width: parent.width; text: snapshotRow.modelData.name; elide: Text.ElideMiddle }
                                            Label { width: parent.width; text: new Date(snapshotRow.modelData.modified * 1000).toLocaleString() + " · " + root.sizeLabel(snapshotRow.modelData.size); elide: Text.ElideRight; color: root.muted; font.pixelSize: Style.font.caption }
                                        }
                                        Action {
                                            id: restoreSnapshot
                                            objectName: "restoreSnapshot-" + snapshotRow.modelData.name
                                            anchors.right: parent.right
                                            anchors.rightMargin: Style.space(10)
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: "Restore…"
                                            iconText: "󰕍"
                                            enabled: !projectRow.busy && root.pendingRestore !== snapshotRow.modelData.path
                                            onClicked: {
                                                root.pendingRestore = snapshotRow.modelData.path
                                                root.pendingLabel = snapshotRow.modelData.name
                                            }
                                        }
                                    }
                                }
                                Column {
                                    width: parent.width
                                    spacing: Style.space(6)
                                    visible: root.pendingRestore !== ""
                                    Label {
                                        width: parent.width
                                        wrapMode: Text.Wrap
                                        text: "Replace the current database of “" + root.selectedName + "” with “" + root.pendingLabel + "”? Changes since this snapshot will be lost."
                                        color: Commons.Color.urgent
                                    }
                                    Row {
                                        spacing: Style.space(8)
                                        Action { text: "Cancel"; onClicked: root.pendingRestore = "" }
                                        Action { text: "Restore database"; iconText: "󰕍"; foreground: Commons.Color.urgent; enabled: !projectRow.busy; onClicked: { var path = root.pendingRestore; root.pendingRestore = ""; root.execute("restore", root.selectedName, path) } }
                                    }
                                }
                            }
                            Column {
                                objectName: "console-" + projectRow.modelData.name
                                width: parent.width
                                spacing: Style.space(8)
                                visible: !!projectRow.consoleState.action || !!projectRow.consoleState.message
                                RowLayout {
                                    width: parent.width
                                    Spinner { visible: projectRow.consoleBusy; tint: root.progress }
                                    Label {
                                        visible: !projectRow.consoleBusy
                                        text: projectRow.consoleState.failed ? "󰅚" : "󰄬"
                                        color: projectRow.consoleState.failed ? Commons.Color.urgent : root.success
                                    }
                                    Label {
                                        Layout.fillWidth: true
                                        text: projectRow.consoleBusy ? root.actionLabelFor(root.actionFor(projectRow.modelData.name)) + "… · " + root.elapsedFor(projectRow.modelData.name) + " s" : projectRow.consoleState.message || "Console"
                                        color: projectRow.consoleState.failed ? Commons.Color.urgent : root.foreground
                                        elide: Text.ElideRight
                                        font.pixelSize: Style.font.caption
                                    }
                                    IconAction {
                                        iconText: projectRow.consoleState.open ? "󰅀" : "󰅃"
                                        tooltipText: projectRow.consoleState.open ? "Hide console" : "Show console"
                                        onClicked: root.updateOutput(projectRow.modelData.name, {open: !projectRow.consoleState.open})
                                    }
                                }
                                Rectangle {
                                    width: parent.width
                                    implicitHeight: consoleText.implicitHeight + Style.space(16)
                                    visible: !!projectRow.consoleState.open
                                    color: Util.alpha(Commons.Color.background, 0.65)
                                    radius: Style.space(6)
                                    Controls.TextArea {
                                        id: consoleText
                                        objectName: "consoleText-" + projectRow.modelData.name
                                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.space(8) }
                                        padding: 0
                                        text: {
                                            var output = projectRow.consoleState.text || ""
                                            if (!output) return projectRow.consoleBusy ? "Waiting for DDEV output…" : "No output."
                                            return projectRow.consoleState.expanded ? output : root.previewOutput(output)
                                        }
                                        readOnly: true
                                        selectByMouse: true
                                        wrapMode: TextEdit.Wrap
                                        textFormat: TextEdit.PlainText
                                        color: projectRow.consoleState.failed ? Commons.Color.urgent : root.foreground
                                        font.family: "monospace"
                                        font.pixelSize: Style.font.caption
                                        background: null
                                    }
                                }
                                RowLayout {
                                    width: parent.width
                                    visible: !!projectRow.consoleState.open && !!projectRow.consoleState.text
                                    Label {
                                        Layout.fillWidth: true
                                        text: projectRow.consoleState.expanded ? "Full output · scroll with the panel" : "Latest output · " + String(projectRow.consoleState.text || "").replace(/\s+$/, "").split("\n").length + " lines"
                                        color: root.muted
                                        font.pixelSize: Style.font.caption
                                    }
                                    Action {
                                        text: projectRow.consoleState.expanded ? "Show less" : "Show all output"
                                        iconText: projectRow.consoleState.expanded ? "󰘕" : "󰘖"
                                        onClicked: root.updateOutput(projectRow.modelData.name, {expanded: !projectRow.consoleState.expanded})
                                    }
                                }
                            }

                        }
                    }
                }


            }
        }
    }
    component Label: Text {
        textFormat: Text.PlainText
        color: root.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
    }
    component Action: Button { focusable: true; bordered: true; fontSize: Style.font.caption; opacity: enabled ? 1 : 0.4 }
    component IconAction: Action {
        implicitWidth: Style.space(32)
        implicitHeight: Style.space(32)
        Layout.alignment: Qt.AlignVCenter
        horizontalPadding: 0
        verticalPadding: 0
        iconSize: Style.space(18)
    }
    component Spinner: Item {
        id: spinner
        property color tint: root.progress
        implicitWidth: Style.space(18)
        implicitHeight: implicitWidth
        Repeater {
            model: 10
            Rectangle {
                required property int index
                width: Style.space(3); height: width; radius: width / 2
                color: spinner.tint
                opacity: (index + 1) / 10
                x: spinner.width / 2 + Math.cos(index * Math.PI / 5) * spinner.width * 0.37 - width / 2
                y: spinner.height / 2 + Math.sin(index * Math.PI / 5) * spinner.height * 0.37 - height / 2
            }
        }
        RotationAnimator on rotation { from: 0; to: 360; duration: 850; loops: Animation.Infinite; running: spinner.visible && root.opened }
    }
}
