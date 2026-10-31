import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Monitoring.js" as Monitoring

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
        function status(): string { return JSON.stringify({ projects: root.projects, warning: root.warning, busy: root.busy, containerCount: root.containers.length, eventsConnected: eventWatcher.running, monitorWarning: root.monitorWarning }) }
    }
    property var projects: []
    property bool projectsLoaded: false
    property int statusRevision: 0
    property var snapshots: []
    property bool monitoringEnabled: true
    property bool alertsEnabled: Boolean(setting("alertsEnabled", true))
    property var containers: []
    property var activeDetail: ({project: "", tab: ""})
    readonly property string detailProject: activeDetail.project
    readonly property string applicationProject: activeDetail.tab === "containers" ? activeDetail.project : ""
    readonly property string domainProject: activeDetail.tab === "domains" ? activeDetail.project : ""
    function isDetail(name, tab) { return activeDetail.project === name && activeDetail.tab === tab }
    function closeDetails() {
        activeDetail = {project: "", tab: ""}
        pendingRestore = ""
        pendingDelete = ""
        snapshots = []
        var names = Object.keys(logViews)
        for (var i = 0; i < names.length; i++) {
            if (logFor(names[i]).open) {
                updateLog(names[i], {open: false})
                stopLog(names[i], false)
            }
        }
    }
    function activateDetail(name, tab) {
        if (isDetail(name, tab)) return
        closeDetails()
        activeDetail = {project: name, tab: tab}
    }
    property var domainViews: ({})
    function domainFor(name) { return domainViews[name] || {items: []} }
    function updateDomains(name, patch) {
        var next = Object.assign({}, domainViews)
        next[name] = Object.assign({items: [], error: ""}, next[name] || {}, patch)
        domainViews = next
    }
    function showDomains(name) {
        if (isDetail(name, "domains")) { closeDetails(); return }
        if (!projectRunning(name) || projectBusy(name)) return
        activateDetail(name, "domains")
        updateDomains(name, {error: ""})
        execute("domains", name, "")
    }
    property string monitorWarning: ""
    property string eventWarning: ""
    property var logViews: ({})
    property var logJobs: ({})
    function containersFor(name) { return containers.filter(c => c.project === name) }
    function logFor(name) { return logViews[name] || ({}) }
    function updateLog(name, patch) {
        var next = Object.assign({}, logViews)
        next[name] = Object.assign({}, next[name] || {}, patch)
        logViews = next
    }
    function selectLog(name) {
        if (!projectRunning(name)) return
        activateDetail(name, "logs")
        var view = logFor(name)
        // Opening an existing viewer must not clear a still-running stream.
        updateLog(name, {open: true, expanded: view.expanded === undefined ? false : view.expanded,
            live: view.live === undefined ? true : view.live})
        refreshLog(name)
    }
    function closeLog(name) {
        if (isDetail(name, "logs")) closeDetails()
        else { updateLog(name, {open: false}); stopLog(name, false) }
    }
    function toggleLog(name) {
        if (isDetail(name, "logs")) closeLog(name)
        else selectLog(name)
    }
    function logSignature(name) { return containersFor(name).map(c => c.id).sort().join(",") }
    function stopLog(name, restart) {
        var reader = logJobs[name]
        if (!reader) { if (restart) refreshLog(name); return }
        reader.cancelled = true
        reader.restartRequested = !!restart
        reader.running = false
    }
    function setLogLive(name, value) {
        updateLog(name, {live: value})
        if (value) refreshLog(name)
        else stopLog(name, false)
    }
    function refreshLog(name) {
        var view = logFor(name)
        if (!view.open || !isDetail(name, "logs")) return
        if (logJobs[name]) {
            // A close/reopen can arrive before the previous reader exits.
            if (logJobs[name].cancelled) logJobs[name].restartRequested = true
            return
        }
        var follow = opened && view.live
        var reader = logReaderFactory.createObject(root, {
            projectName: name, following: follow, signature: logSignature(name),
            command: ["python3", bridge, follow ? "logs-follow" : "logs", name]
        })
        if (!reader) return
        var next = Object.assign({}, logJobs)
        next[name] = reader
        logJobs = next
        if (follow) updateLog(name, {error: "", notice: ""})
        reader.running = true
    }
    function refreshContainers() {
        if (!monitoringEnabled || !projectsLoaded) return
        if (monitor.running) { monitor.recheckRequested = true; return }
        monitor.recheckRequested = false
        monitor.command = ["python3", bridge, "monitor"].concat(opened && applicationProject ? ["stats"] : [])
        monitor.eventVersion = Monitoring.eventVersion
        monitor.running = true
    }
    function showApplications(name) {
        if (isDetail(name, "containers")) { closeDetails(); return }
        if (!projectRunning(name)) return
        activateDetail(name, "containers")
        refreshContainers()
    }
    function announce(alerts) {
        if (!monitoringEnabled || !alertsEnabled) return
        var selected = alerts.filter(alert => projects.some(p => p.name === alert.project))
        if (!selected.length) return
        var sender = notificationFactory.createObject(root, {payload: selected})
        if (sender) sender.running = true
    }
    property string notificationWarning: ""
    Component {
        id: notificationFactory
        Process {
            id: sender
            property var payload: []
            command: ["python3", Qt.resolvedUrl("notifications.py").toString().replace(/^file:\/\//, "")]
            stdinEnabled: true
            onStarted: { write(JSON.stringify(payload)); stdinEnabled = false; payload = [] }
            onExited: function(code, status) {
                root.notificationWarning = code === 0 ? "" : "Desktop alerts could not be delivered. Check the notification service and Python GObject dependency."
                Qt.callLater(function() { sender.destroy() })
            }
            property Timer watchdog: Timer { interval: 10000; running: sender.running; onTriggered: sender.running = false }
        }
    }

    function applyInventory(items, announceChanges) {
        containers = items.filter(c => projects.some(p => p.name === c.project))
        if (announceChanges) announce(Monitoring.inventory(containers, true, projects))
        var names = Object.keys(logJobs)
        for (var i = 0; i < names.length; i++) {
            var reader = logJobs[names[i]]
            if (reader.following && reader.signature !== logSignature(names[i])) stopLog(names[i], true)
        }
    }
    function receiveEvent(event) {
        if (!projects.some(p => p.name === event.project)) return
        announce(Monitoring.event(event, true, projects))
        refreshContainers()
    }
    function flushAlerts() {
        var blocked = globalBusy ? projects.map(p => p.name) : Object.keys(jobs)
        announce(Monitoring.flush(blocked))
    }
    function saveAlerts(value) {
        alertsEnabled = value
        var entry = {id: moduleName}
        for (var key in settings) if (key !== "id") entry[key] = settings[key]
        entry.alertsEnabled = value
        if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function") bar.shell.updateEntryInline(moduleName, entry)
    }
    readonly property string selectedName: activeDetail.tab === "snapshots" ? activeDetail.project : ""
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
    function projectRunning(name) { return projects.some(p => p.name === name && Monitoring.isActiveStatus(p.status)) }
    function canRun(action, name) {
        if (["poweroff", "start", "stop", "restart", "snapshot", "snapshots", "restore", "domains", "browse", "browse-all", "mailpit", "folder", "commands", "save-command", "delete-command", "custom-command", "delete-snapshot", "snapshot-folder"].indexOf(action) < 0) return false
        if (action === "poweroff") return !busy
        if (projectBusy(name)) return false
        if (["restart", "snapshot", "restore", "domains", "browse", "browse-all", "mailpit", "custom-command"].indexOf(action) >= 0 && !projectRunning(name)) return false
        if (action === "restart") return !containersFor(name).some(c => c.state === "paused")
        return true
    }
    property string pendingDelete: ""
    property string deleteLabel: ""
    property var commandViews: ({})
    function commandsFor(name) { return commandViews[name] || {items: [], error: ""} }
    function showCommands(name) {
        if (isDetail(name, "commands")) { closeDetails(); return }
        if (projectBusy(name)) return
        activateDetail(name, "commands")
        execute("commands", name, "")
    }
    function isCommandRead(action) { return ["commands", "save-command", "delete-command"].indexOf(action) >= 0 }
    property string pendingRestore: ""
    property string pendingLabel: ""
    property string query: ""
    onProjectsChanged: {
        if (detailProject && !projectRunning(detailProject)) {
            if (["snapshots", "commands"].indexOf(activeDetail.tab) < 0) closeDetails()
            pendingRestore = ""
        }
    }
    onQueryChanged: Qt.callLater(function() {
        if (root.detailProject && !root.filteredProjects.some(p => p.name === root.detailProject)) root.closeDetails()
    })
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
    function actionLabelFor(action) { return ({poweroff: "Powering off DDEV", "custom-command": "Running shortcut", "delete-snapshot": "Deleting snapshot", "snapshot-folder": "Opening snapshot folder", start: "Starting", stop: "Stopping", restart: "Restarting", snapshot: "Creating snapshot", restore: "Restoring database", snapshots: "Loading snapshots", domains: "Loading project domains", "browse-all": "Opening project domains", browse: "Opening browser", mailpit: "Opening Mailpit", folder: "Opening folder"})[action] || "Working" }
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
    readonly property int runningCount: projects.filter(p => Monitoring.isActiveStatus(p.status)).length
    readonly property var filteredProjects: projects.filter(p => (p.name + " " + p.approot).toLowerCase().indexOf(query.toLowerCase()) >= 0)
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    function refresh() {
        if (listing.running) listing.recheckRequested = true
        else { listing.recheckRequested = false; listing.running = true }
        refreshContainers()
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
        if (["snapshots", "domains"].indexOf(action) < 0 && !isCommandRead(action)) updateOutput(name, {text: "", message: "", failed: false, action: action, expanded: false, open: true, dismissed: false})
        Monitoring.beginning(name, action)
        if (action === "poweroff") projects.forEach(p => Monitoring.beginning(p.name, "stop"))
        job.running = true
        return true
    }
    function selectProject(name) {
        if (isDetail(name, "snapshots")) { closeDetails(); return }
        if (projectBusy(name)) return
        activateDetail(name, "snapshots")
        execute("snapshots", name, "")
    }
    function finishJob(job, exitCode) {
        if (!job.receivedResult) {
            job.commandFailed = true
            updateOutput(job.projectName, {failed: true, message: "Command exited without a result (" + exitCode + ")", text: job.capturedOutput, open: true})
        }
        if ((["snapshots", "domains"].indexOf(job.actionName) < 0 && !isCommandRead(job.actionName)) || (job.commandFailed && !isCommandRead(job.actionName))) {
            var failed = job.commandFailed || exitCode !== 0
            updateOutput(job.projectName, {failed: failed, open: failed, expanded: failed,
                dismissed: failed ? false : !!outputFor(job.projectName).dismissed})
        }
        if (!job.commandFailed && exitCode === 0 && ["start", "restart", "stop", "poweroff"].indexOf(job.actionName) >= 0) {
            statusRevision++
            var all = job.actionName === "poweroff"
            var status = job.actionName === "stop" || all ? "stopped" : "running"
            projects = projects.map(p => all || p.name === job.projectName ? Object.assign({}, p, {status: status}) : p)
            containers = containers.filter(c => !all && c.project !== job.projectName)
        }
        announce(Monitoring.completed(job.projectName, job.actionName, !job.commandFailed && exitCode === 0))
        if (job.actionName === "poweroff")
            for (var i = 0; i < projects.length; i++) announce(Monitoring.completed(projects[i].name, "stop", !job.commandFailed && exitCode === 0))
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
    Component.onCompleted: { refresh(); if (monitoringEnabled) eventWatcher.running = true }
    Timer { interval: root.opened && root.applicationProject ? 3000 : 10000; running: root.monitoringEnabled; repeat: true; onTriggered: root.refreshContainers() }
    Timer { interval: 5000; running: root.monitoringEnabled; repeat: true; onTriggered: if (!eventWatcher.running) eventWatcher.running = true }
    Timer {
        interval: 2000; running: root.opened; repeat: true
        onTriggered: {
            var names = Object.keys(root.logViews)
            for (var i = 0; i < names.length; i++) {
                var view = root.logFor(names[i])
                if (view.open && view.live) root.refreshLog(names[i])
            }
        }
    }
    onOpenedChanged: {
        if (opened) refresh()
        var names = Object.keys(logViews)
        for (var i = 0; i < names.length; i++) {
            var view = logFor(names[i])
            if (opened && view.open && view.live) refreshLog(names[i])
            else if (!opened) stopLog(names[i], false)
        }
    }
    Timer { interval: 2000; running: root.monitoringEnabled; repeat: true; onTriggered: root.flushAlerts() }
    Timer {
        interval: Math.max(5, root.refreshSeconds) * 1000
        running: true
        repeat: true
        onTriggered: root.refresh()
    }
    Process {
        id: listing
        property int revision: 0
        onStarted: revision = root.statusRevision
        property bool recheckRequested: false
        onExited: if (recheckRequested) Qt.callLater(root.refresh)
        command: ["python3", root.bridge, "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var data = JSON.parse(text)
                    if (listing.revision !== root.statusRevision) { listing.recheckRequested = true; return }
                    if (data.ok) { root.projects = data.projects; root.projectsLoaded = true; Monitoring.register(root.projects); root.warning = data.warning || ""; root.refreshContainers() }
                    else root.warning = data.message
                } catch (error) { root.warning = "Could not read DDEV status: " + error }
            }
        }
        stderr: StdioCollector { onStreamFinished: if (text.trim()) root.warning = text.trim() }
    }
    Process {
        id: monitor
        property int eventVersion: 0
        property bool recheckRequested: false
        onExited: if (recheckRequested) Qt.callLater(root.refreshContainers)
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var data = JSON.parse(text)
                    if (data.ok) {
                        root.monitorWarning = data.warning || ""
                        if (monitor.eventVersion !== Monitoring.eventVersion) { monitor.recheckRequested = true; return }
                        root.applyInventory(data.containers || [], true)
                    } else root.monitorWarning = data.message || "Container monitoring is unavailable"
                } catch (error) { root.monitorWarning = "Could not read container status" }
            }
        }
        stderr: StdioCollector { onStreamFinished: if (text.trim()) root.monitorWarning = text.trim() }
    }
    Process {
        id: eventWatcher
        command: ["python3", root.bridge, "watch"]
        stdout: SplitParser {
            onRead: function(line) {
                try {
                    var data = JSON.parse(line)
                    if (data.event === "container") { root.eventWarning = ""; root.receiveEvent(data) }
                    else if (data.ok === false) root.eventWarning = data.message
                } catch (error) { root.eventWarning = "Could not read a Docker event" }
            }
        }
        stderr: StdioCollector { onStreamFinished: if (text.trim()) root.eventWarning = "Docker events disconnected; retrying automatically" }
        onExited: root.eventWarning = "Docker events disconnected; retrying automatically"
    }
    Component {
        id: logReaderFactory
        Process {
            id: reader
            property string projectName: ""
            property string signature: ""
            property bool following: false
            property bool cancelled: false
            property bool restartRequested: false
            property bool received: false
            property string capturedOutput: ""
            stdout: SplitParser {
                onRead: function(line) {
                    if (!line.trim() || reader.cancelled) return
                    try {
                        var data = JSON.parse(line)
                        if (data.event === "log") {
                            reader.received = true
                            reader.capturedOutput = (reader.capturedOutput + root.cleanOutput(data.text)).slice(-24000)
                            root.updateLog(reader.projectName, {text: reader.capturedOutput, error: ""})
                        } else {
                            reader.received = true
                            var patch = {error: data.ok ? "" : data.message || "Project logs unavailable", notice: data.message || ""}
                            if (data.logs !== undefined) patch.text = root.cleanOutput(data.logs)
                            root.updateLog(reader.projectName, patch)
                        }
                    } catch (error) { root.updateLog(reader.projectName, {error: "Could not read project logs"}) }
                }
            }
            stderr: StdioCollector { onStreamFinished: if (text.trim() && !reader.cancelled) root.updateLog(reader.projectName, {error: text.trim()}) }
            onExited: {
                if (!reader.received && !reader.cancelled) root.updateLog(reader.projectName, {error: "Project log reader exited without a result"})
                var next = Object.assign({}, root.logJobs)
                delete next[reader.projectName]
                root.logJobs = next
                var restart = reader.restartRequested
                var name = reader.projectName
                Qt.callLater(function() {
                    reader.destroy()
                    if (restart && root.logFor(name).open) root.refreshLog(name)
                })
            }
        }
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
                        if (root.isCommandRead(job.actionName)) {
                            var next = Object.assign({}, root.commandViews)
                            next[job.projectName] = {items: data.commands || root.commandsFor(job.projectName).items, error: data.ok ? data.warning || "" : data.message || "Could not load commands"}
                            root.commandViews = next
                        } else if (job.actionName === "domains") {
                            root.updateDomains(job.projectName, {items: data.ok ? data.domains || [] : [], error: data.ok ? "" : data.message || "Could not read project domains"})
                        } else if (job.actionName === "snapshots" && data.ok) {
                            if (root.selectedName === job.projectName) {
                                root.snapshots = data.snapshots
                                if (!root.snapshots.some(s => s.path === root.pendingRestore)) root.pendingRestore = ""
                            }
                        } else {
                            if (job.actionName === "delete-snapshot" && data.ok && root.selectedName === job.projectName) root.snapshots = data.snapshots
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
        text: (root.busy ? "󰔟 " : "") + (root.warning ? "?" : root.runningCount) + "/" + root.projects.length
        labelVisible: false
        implicitWidth: vertical ? barSize : brandLabel.implicitWidth + scaledHorizontalMargin * 2
        implicitHeight: vertical ? brandLabel.implicitHeight + scaledVerticalPadding * 2 : barSize
        Grid {
            id: brandLabel
            anchors.centerIn: parent
            columns: button.vertical ? 1 : 2
            spacing: Style.space(6)
            Image {
                objectName: "ddevBarIcon"
                width: Style.bar.iconCanvas; height: Style.bar.iconCanvas
                source: Qt.resolvedUrl("ddev.svg")
                sourceSize: Qt.size(width, height)
                fillMode: Image.PreserveAspectFit
                smooth: true
            }
            Text {
                text: button.text
                color: button.foreground
                font.family: button.fontFamily; font.pixelSize: button.fontSize
                textFormat: Text.PlainText
                height: Math.max(implicitHeight, Style.bar.iconCanvas)
                verticalAlignment: Text.AlignVCenter
            }
        }
        onPressed: function(code) { if (code === Qt.MiddleButton) root.refresh(); else root.toggle() }
    }
    KeyboardPanel {
        id: panel
        anchorItem: button
        owner: root
        bar: root.bar
        open: root.opened
        focusTarget: content
        contentWidth: panel.fittedContentWidth(Style.space(650))
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
                        Image { objectName: "ddevHeaderIcon"; anchors.centerIn: parent; width: Style.space(30); height: Style.space(30); source: Qt.resolvedUrl("ddev.svg"); sourceSize: Qt.size(width, height); fillMode: Image.PreserveAspectFit; smooth: true }
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
                Toggle {
                    visible: root.settingsOpen
                    width: parent.width
                    label: "Project alerts"
                    description: "One notification per project transition"
                    checked: root.alertsEnabled
                    onClicked: root.saveAlerts(!root.alertsEnabled)
                }
                Label {
                    width: parent.width
                    visible: root.settingsOpen && root.eventWarning !== ""
                    text: root.eventWarning
                    color: root.progress
                    wrapMode: Text.Wrap
                }
                Label {
                    width: parent.width
                    visible: text !== ""
                    text: root.notificationWarning
                    color: root.progress
                    wrapMode: Text.Wrap
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
                        readonly property var serviceContainers: root.containersFor(modelData.name)
                        readonly property bool hasPaused: running && serviceContainers.some(c => c.state === "paused")
                        readonly property bool unhealthy: running && (modelData.status === "unhealthy" || serviceContainers.some(c => c.health === "unhealthy" && c.state === "running"))
                        readonly property var consoleState: root.outputFor(modelData.name)
                        readonly property bool consoleBusy: !!root.jobs[modelData.name] && ["snapshots", "domains"].indexOf(root.actionFor(modelData.name)) < 0 && !root.isCommandRead(root.actionFor(modelData.name))
                        required property var modelData
                        readonly property bool busy: root.projectBusy(modelData.name)
                        readonly property bool running: Monitoring.isActiveStatus(modelData.status)
                        readonly property color statusColor: busy || hasPaused ? root.progress : unhealthy ? Commons.Color.urgent : (running ? root.success : (modelData.status === "stopped" ? root.muted : root.progress))
                        width: content.width
                        implicitHeight: projectContent.implicitHeight + Style.space(24)
                        radius: Style.space(10)
                        color: Util.alpha(projectRow.statusColor, busy ? 0.08 : 0.035)
                        border.width: 1
                        border.color: root.detailProject === modelData.name ? Util.alpha(Commons.Color.accent, 0.65) : Util.alpha(projectRow.statusColor, busy ? 0.5 : 0.18)
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
                                    Label { objectName: "projectStatus-" + projectRow.modelData.name; Layout.fillWidth: true; elide: Text.ElideRight; text: projectRow.busy ? root.actionLabelFor(root.actionFor(projectRow.modelData.name)) + "… · " + root.elapsedFor(projectRow.modelData.name) + " s" : (projectRow.hasPaused ? "Paused services" : projectRow.unhealthy ? "Running · unhealthy" : projectRow.running ? "Running" : projectRow.modelData.status === "stopped" ? "Stopped" : projectRow.modelData.status); color: projectRow.statusColor; font.pixelSize: Style.font.caption }
                                }
                                Label { text: projectRow.modelData.type; color: root.muted; font.pixelSize: Style.font.caption }
                                }
                                ToolbarAction {
                                    id: restartProject
                                    objectName: "restartProject-" + projectRow.modelData.name
                                    anchors.right: powerSwitch.left
                                    anchors.rightMargin: Style.space(6)
                                    anchors.verticalCenter: parent.verticalCenter
                                    iconText: "󰜉"
                                    text: "Restart"
                                    tooltipText: projectRow.hasPaused ? "Restart is unavailable while a container is paused" : projectRow.running ? "Restart project" : "Start the project first"
                                    enabled: !projectRow.busy && projectRow.running && !projectRow.hasPaused
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
                            RowLayout {
                                width: parent.width
                                spacing: Style.space(10)
                                Label { Layout.fillWidth: true; elide: Text.ElideMiddle; text: projectRow.modelData.shortroot || projectRow.modelData.approot; color: root.muted; font.pixelSize: Style.font.caption }
                                Label { text: projectRow.serviceContainers.length + " containers"; color: root.muted; font.pixelSize: Style.font.caption }
                            }
                            RowLayout {
                                objectName: "projectActions-" + projectRow.modelData.name
                                width: parent.width
                                spacing: Style.space(5)
                                DetailTab {
                                    projectName: projectRow.modelData.name
                                    viewName: "domains"
                                    objectName: "openProjectSite-" + projectRow.modelData.name
                                    text: "Domains"; iconText: "󰖟"
                                    tooltipText: !projectRow.running ? "Start the project first" : selected ? "Close domains" : "Open project domains"
                                    enabled: projectRow.running && (selected || !projectRow.busy)
                                    onClicked: root.showDomains(projectRow.modelData.name)
                                }
                                DetailTab {
                                    projectName: projectRow.modelData.name
                                    viewName: "logs"
                                    objectName: "openProjectLogs-" + projectRow.modelData.name
                                    text: "Logs"; iconText: "󰆍"
                                    tooltipText: !projectRow.running ? "Start the project first" : selected ? "Close project logs" : "Open project logs"
                                    enabled: projectRow.running
                                    onClicked: root.toggleLog(projectRow.modelData.name)
                                }
                                DetailTab {
                                    projectName: projectRow.modelData.name
                                    viewName: "containers"
                                    objectName: "showProjectContainers-" + projectRow.modelData.name
                                    text: "Containers"; iconText: "󰡨"
                                    tooltipText: !projectRow.running ? "Start the project first" : selected ? "Close container overview" : "Open container overview"
                                    enabled: projectRow.running
                                    onClicked: root.showApplications(projectRow.modelData.name)
                                }
                                DetailTab {
                                    projectName: projectRow.modelData.name
                                    viewName: "snapshots"
                                    objectName: "showProjectSnapshots-" + projectRow.modelData.name
                                    text: "Snapshots"; iconText: "󰆼"
                                    tooltipText: selected ? "Close snapshots" : "Open database snapshots"
                                    enabled: selected || !projectRow.busy
                                    onClicked: root.selectProject(projectRow.modelData.name)
                                }
                                DetailTab {
                                    projectName: projectRow.modelData.name; viewName: "commands"
                                    objectName: "showProjectCommands-" + projectRow.modelData.name
                                    text: "Commands"; iconText: "󰘳"
                                    tooltipText: selected ? "Close command shortcuts" : "Project command shortcuts"
                                    enabled: selected || !projectRow.busy
                                    onClicked: root.showCommands(projectRow.modelData.name)
                                }
                                Rectangle {
                                    Layout.preferredWidth: 1
                                    Layout.preferredHeight: Style.space(20)
                                    Layout.leftMargin: Style.space(3)
                                    Layout.rightMargin: Style.space(3)
                                    Layout.alignment: Qt.AlignVCenter
                                    color: Util.alpha(root.foreground, 0.2)
                                }
                                ToolbarAction {
                                    objectName: "openProjectMailpit-" + projectRow.modelData.name
                                    text: "Mailpit"; iconText: "󰇮"; tooltipText: projectRow.running ? "Open Mailpit" : "Start the project first"
                                    enabled: !projectRow.busy && projectRow.running
                                    onClicked: root.execute("mailpit", projectRow.modelData.name, "")
                                }
                                ToolbarAction {
                                    objectName: "openProjectFolder-" + projectRow.modelData.name
                                    text: "Folder"; iconText: "󰉋"; tooltipText: "Open project folder"
                                    enabled: !projectRow.busy
                                    onClicked: root.execute("folder", projectRow.modelData.name, "")
                                }
                                Item { Layout.fillWidth: true }
                            }
                            Column {
                                objectName: "domains-" + projectRow.modelData.name
                                width: parent.width
                                spacing: Style.space(8)
                                visible: root.domainProject === projectRow.modelData.name
                                RowLayout {
                                    width: parent.width
                                    Label { text: "Project domains"; color: Commons.Color.accent; font.bold: true; Layout.fillWidth: true }
                                    IconAction { iconText: "󰑐"; tooltipText: "Refresh domains"; enabled: !projectRow.busy; onClicked: root.execute("domains", projectRow.modelData.name, "") }
                                    ToolbarAction {
                                        objectName: "openAllDomains-" + projectRow.modelData.name
                                        text: "Open all (" + root.domainFor(projectRow.modelData.name).items.length + ")"
                                        iconText: "󰖟"
                                        enabled: !projectRow.busy && projectRow.running && root.domainFor(projectRow.modelData.name).items.length > 0
                                        onClicked: root.execute("browse-all", projectRow.modelData.name, "")
                                    }
                                }
                                Label { width: parent.width; wrapMode: Text.Wrap; text: root.domainFor(projectRow.modelData.name).error || ""; visible: text !== ""; color: Commons.Color.urgent }
                                Label { width: parent.width; wrapMode: Text.Wrap; color: root.muted; text: projectRow.busy && root.actionFor(projectRow.modelData.name) === "domains" ? "Loading domains from DDEV…" : "No concrete project domains available."; visible: root.domainFor(projectRow.modelData.name).items.length === 0 }
                                Repeater {
                                    model: root.domainFor(projectRow.modelData.name).items
                                    Rectangle {
                                        id: domainRow
                                        required property var modelData
                                        width: parent.width
                                        implicitHeight: Math.max(domainText.implicitHeight, openDomain.implicitHeight) + Style.space(16)
                                        radius: Style.space(6)
                                        color: Util.alpha(root.foreground, 0.035)
                                        Column {
                                            id: domainText
                                            anchors { left: parent.left; leftMargin: Style.space(8); right: openDomain.left; rightMargin: Style.space(10); verticalCenter: parent.verticalCenter }
                                            spacing: Style.space(2)
                                            Label { width: parent.width; elide: Text.ElideMiddle; text: (domainRow.modelData.primary ? "Primary · " : "") + domainRow.modelData.host; font.bold: domainRow.modelData.primary }
                                            Label { width: parent.width; elide: Text.ElideMiddle; text: domainRow.modelData.url; color: root.muted; font.pixelSize: Style.font.caption }
                                        }
                                        ToolbarAction {
                                            id: openDomain
                                            objectName: "openDomain-" + projectRow.modelData.name + "-" + domainRow.modelData.host
                                            anchors { right: parent.right; rightMargin: Style.space(8); verticalCenter: parent.verticalCenter }
                                            text: "Open"; iconText: "󰖟"
                                            enabled: !projectRow.busy && projectRow.running
                                            onClicked: root.execute("browse", projectRow.modelData.name, domainRow.modelData.url)
                                        }
                                    }
                                }
                            }
                            Column {
                                objectName: "applications-" + projectRow.modelData.name
                                width: parent.width
                                spacing: Style.space(8)
                                visible: root.applicationProject === projectRow.modelData.name
                                Label { text: "Containers"; color: Commons.Color.accent; font.bold: true }
                                Label { width: parent.width; text: root.monitorWarning; visible: text !== ""; wrapMode: Text.Wrap; color: root.progress }
                                Label { text: "No containers found. Start the project to create them."; visible: projectRow.serviceContainers.length === 0; width: parent.width; wrapMode: Text.Wrap; color: root.muted }
                                Repeater {
                                    model: projectRow.serviceContainers
                                    Rectangle {
                                        id: serviceRow
                                        objectName: "containerOverview-" + modelData.id
                                        required property var modelData
                                        width: parent.width
                                        implicitHeight: Style.space(36)
                                        radius: Style.space(6)
                                        color: Util.alpha(root.foreground, 0.025)
                                        RowLayout {
                                            anchors { fill: parent; leftMargin: Style.space(8); rightMargin: Style.space(5) }
                                            spacing: Style.space(8)
                                            Rectangle { width: Style.space(6); height: width; radius: width / 2; color: serviceRow.modelData.state === "paused" ? root.progress : serviceRow.modelData.state === "running" && serviceRow.modelData.health === "unhealthy" ? Commons.Color.urgent : serviceRow.modelData.state === "running" ? root.success : root.muted }
                                            Label { text: serviceRow.modelData.service; Layout.preferredWidth: Style.space(55); elide: Text.ElideRight; font.bold: true; font.pixelSize: Style.font.caption }
                                            Label { text: serviceRow.modelData.state === "running" ? serviceRow.modelData.health || "running" : serviceRow.modelData.state; Layout.fillWidth: true; Layout.minimumWidth: 0; elide: Text.ElideRight; color: root.muted; font.pixelSize: Style.font.caption }
                                            Label {
                                                text: serviceRow.modelData.stats ? serviceRow.modelData.stats.cpu + " · " + serviceRow.modelData.stats.memory.split(" / ")[0] : "—"
                                                color: root.muted; font.pixelSize: Style.font.caption
                                                HoverHandler { id: metricHover }
                                                PanelToolTip {
                                                    visible: metricHover.hovered && !!serviceRow.modelData.stats
                                                    text: serviceRow.modelData.stats ? "CPU " + serviceRow.modelData.stats.cpu + " · RAM " + serviceRow.modelData.stats.memory + "\nNetwork " + serviceRow.modelData.stats.network + " · Disk " + serviceRow.modelData.stats.disk + " · " + serviceRow.modelData.stats.pids + " PIDs" : ""
                                                }
                                            }

                                        }
                                    }
                                }
                            }

                            Column {
                                width: parent.width
                                spacing: Style.space(8)
                                visible: root.isDetail(projectRow.modelData.name, "logs") && !!root.logFor(projectRow.modelData.name).open
                                RowLayout {
                                    width: parent.width
                                    Label { text: "Project logs"; color: Commons.Color.accent; Layout.fillWidth: true; elide: Text.ElideRight; font.bold: true }
                                    Action { text: "Live"; selected: !!root.logFor(projectRow.modelData.name).live; onClicked: root.setLogLive(projectRow.modelData.name, !root.logFor(projectRow.modelData.name).live) }
                                    IconAction { iconText: "󰑐"; tooltipText: "Refresh logs"; onClicked: root.stopLog(projectRow.modelData.name, true) }
                                    IconAction { objectName: "closeProjectLogs-" + projectRow.modelData.name; iconText: "󰅖"; tooltipText: "Close log viewer"; onClicked: root.closeLog(projectRow.modelData.name) }
                                }
                                Label { width: parent.width; wrapMode: Text.Wrap; visible: text !== ""; text: root.logFor(projectRow.modelData.name).error || ""; color: Commons.Color.urgent }
                                Controls.TextArea {
                                    objectName: "projectLogs-" + projectRow.modelData.name
                                    width: parent.width
                                    text: {
                                        var view = root.logFor(projectRow.modelData.name)
                                        return view.text ? view.expanded ? view.text : root.previewOutput(view.text) : root.logJobs[projectRow.modelData.name] ? "Loading project logs…" : view.notice || "No project log output."
                                    }
                                    readOnly: true; selectByMouse: true; wrapMode: TextEdit.Wrap; textFormat: TextEdit.PlainText
                                    color: root.foreground; font.family: "monospace"; font.pixelSize: Style.font.caption
                                    background: Rectangle { color: Util.alpha(Commons.Color.background, 0.65); radius: Style.space(6) }
                                }
                                RowLayout {
                                    width: parent.width
                                    Label { text: root.logFor(projectRow.modelData.name).live ? "Following all project services" : "Recent logs · all project services"; color: root.muted; font.pixelSize: Style.font.caption; Layout.fillWidth: true; wrapMode: Text.Wrap }
                                    Action { text: root.logFor(projectRow.modelData.name).expanded ? "Show less" : "Show all logs"; onClicked: root.updateLog(projectRow.modelData.name, {expanded: !root.logFor(projectRow.modelData.name).expanded}) }
                                }
                            }
                            Rectangle {
                                width: parent.width
                                height: 1
                                color: Util.alpha(root.foreground, 0.12)
                                visible: root.selectedName === projectRow.modelData.name || (!projectRow.consoleState.dismissed && (!!projectRow.consoleState.action || !!projectRow.consoleState.message))
                            }
                            Column {
                                id: commandPanel
                                width: parent.width; spacing: Style.space(8)
                                visible: root.isDetail(projectRow.modelData.name, "commands")
                                property bool editing: false
                                property bool managing: false
                                property string editId: ""
                                readonly property var filteredCommands: root.commandsFor(projectRow.modelData.name).items.filter(c => (c.label + " " + c.command + " " + (c.description || "")).toLowerCase().includes(commandFilter.text.trim().toLowerCase()))
                                property var savedItems: root.commandsFor(projectRow.modelData.name).items
                                onSavedItemsChanged: if (root.actionFor(projectRow.modelData.name) === "save-command" && !root.commandsFor(projectRow.modelData.name).error) editing = false
                                RowLayout {
                                    width: parent.width
                                    Label { text: "Command shortcuts"; color: Commons.Color.accent; font.bold: true; Layout.fillWidth: true }
                                    Action { objectName: "manageCommands-" + projectRow.modelData.name; text: commandPanel.managing ? "Done" : "Edit"; enabled: !projectRow.busy; visible: root.commandsFor(projectRow.modelData.name).items.length > 0; onClicked: commandPanel.managing = !commandPanel.managing }
                                    Action { objectName: "addCommand-" + projectRow.modelData.name; text: "Add"; iconText: "󰐕"; enabled: !projectRow.busy; onClicked: { commandPanel.editId = ""; commandLabel.text = ""; commandValue.text = ""; commandPanel.editing = !commandPanel.editing } }
                                    IconAction { iconText: "󰑐"; tooltipText: "Reload DDEV commands and shortcuts"; enabled: !projectRow.busy; onClicked: root.execute("commands", projectRow.modelData.name, "") }
                                }
                                Label { width: parent.width; wrapMode: Text.Wrap; text: "Available DDEV commands and your saved shortcuts. Hover for details; Edit lets you customize arguments."; color: root.muted }
                                Label { width: parent.width; wrapMode: Text.Wrap; text: root.commandsFor(projectRow.modelData.name).error; visible: text !== ""; color: Commons.Color.urgent }
                                TextField { id: commandFilter; objectName: "commandFilter-" + projectRow.modelData.name; width: parent.width; placeholderText: "Filter commands…" }
                                Label { objectName: "commandEmpty-" + projectRow.modelData.name; text: projectRow.busy && root.actionFor(projectRow.modelData.name) === "commands" ? "Loading commands…" : root.commandsFor(projectRow.modelData.name).items.length ? "No commands match this search." : "No custom DDEV commands or saved shortcuts found."; visible: commandPanel.filteredCommands.length === 0 }
                                Flow {
                                    width: parent.width; spacing: Style.space(6)
                                    Repeater {
                                        model: root.isDetail(projectRow.modelData.name, "commands") ? commandPanel.filteredCommands : []
                                        Row {
                                            required property var modelData
                                            id: shortcutRow
                                            spacing: Style.space(3)
                                            TextMetrics { id: shortcutMetrics; font.family: Style.font.family; font.pixelSize: Style.font.caption; text: shortcutRow.modelData.label; elide: Qt.ElideRight; elideWidth: commandPanel.width - Style.space(commandPanel.managing ? 120 : 48) }
                                            Action {
                                                objectName: "runCommand-" + shortcutRow.modelData.id
                                                width: Math.min(implicitWidth, commandPanel.width - (commandPanel.managing ? Style.space(72) : 0))
                                                text: shortcutMetrics.elidedText; iconText: "󰐊"
                                                enabled: projectRow.running && !projectRow.busy
                                                tooltipText: projectRow.running ? "ddev " + shortcutRow.modelData.command + (shortcutRow.modelData.description ? " · " + shortcutRow.modelData.description : "") : "Start the project first"
                                                onClicked: root.execute("custom-command", projectRow.modelData.name, shortcutRow.modelData.id)
                                            }
                                            IconAction {
                                                visible: commandPanel.managing; enabled: !projectRow.busy
                                                objectName: "editCommand-" + shortcutRow.modelData.id
                                                iconText: "󰏫"; tooltipText: shortcutRow.modelData.source === "ddev" ? "Create shortcut with arguments" : "Edit shortcut"
                                                onClicked: { commandPanel.editId = shortcutRow.modelData.source === "ddev" ? "" : shortcutRow.modelData.id; commandLabel.text = shortcutRow.modelData.label; commandValue.text = shortcutRow.modelData.command; commandPanel.editing = true }
                                            }
                                            IconAction {
                                                objectName: "deleteCommand-" + shortcutRow.modelData.id
                                                visible: commandPanel.managing && shortcutRow.modelData.source !== "ddev"; enabled: !projectRow.busy
                                                iconText: "󰆴"; tooltipText: "Remove shortcut"; foreground: Commons.Color.urgent
                                                onClicked: root.execute("delete-command", projectRow.modelData.name, shortcutRow.modelData.id)
                                            }
                                        }
                                    }
                                }
                                Column {
                                    width: parent.width; spacing: Style.space(6); visible: commandPanel.editing
                                    TextField { id: commandLabel; objectName: "commandLabel-" + projectRow.modelData.name; width: parent.width; placeholderText: "Button label, e.g. Clear cache" }
                                    TextField { id: commandValue; objectName: "commandValue-" + projectRow.modelData.name; width: parent.width; placeholderText: "DDEV command, e.g. drush cr" }
                                    Label { width: parent.width; wrapMode: Text.Wrap; text: "Enter a DDEV command and arguments. Use quotes for arguments with spaces. Interactive commands and shell pipelines are not supported."; color: root.muted; font.pixelSize: Style.font.caption }
                                    Row {
                                        spacing: Style.space(6)
                                        Action { objectName: "saveCommand-" + projectRow.modelData.name; text: "Save shortcut"; enabled: !projectRow.busy && commandLabel.text.trim() !== "" && commandValue.text.trim() !== ""; onClicked: root.execute("save-command", projectRow.modelData.name, JSON.stringify({id: commandPanel.editId, label: commandLabel.text.trim(), command: commandValue.text.trim()})) }
                                        Action { text: "Cancel"; onClicked: commandPanel.editing = false }
                                    }
                                }
                            }
                            Column {
                                id: snapshotPanel
                                readonly property var filteredSnapshots: root.snapshots.filter(s => s.name.toLowerCase().includes(snapshotName.text.trim().toLowerCase()))
                                objectName: "snapshots-" + projectRow.modelData.name
                                width: parent.width
                                spacing: Style.space(8)
                                visible: root.selectedName === projectRow.modelData.name
                                RowLayout {
                                    width: parent.width
                                    Label { text: "Database snapshots"; color: Commons.Color.accent; font.bold: true; Layout.fillWidth: true }
                                    Action { objectName: "openSnapshotFolder-" + projectRow.modelData.name; text: "Folder"; iconText: "󰉋"; tooltipText: "Open snapshot folder"; enabled: !projectRow.busy; onClicked: root.execute("snapshot-folder", projectRow.modelData.name, "") }
                                    IconAction { iconText: "󰅖"; tooltipText: "Close snapshots"; enabled: !projectRow.busy; onClicked: root.selectProject(projectRow.modelData.name) }
                                }
                                RowLayout {
                                    width: parent.width
                                    TextField { id: snapshotName; objectName: "snapshotName-" + projectRow.modelData.name; Layout.fillWidth: true; placeholderText: "Filter snapshots / name for new snapshot" }
                                    Action { objectName: "createSnapshot-" + projectRow.modelData.name; text: "Create"; iconText: "󰐕"; tooltipText: projectRow.running ? "Create database snapshot" : "Start the project first"; enabled: projectRow.running && !projectRow.busy; onClicked: root.execute("snapshot", root.selectedName, snapshotName.text.trim()) }
                                    IconAction { iconText: "󰑐"; tooltipText: "Reload snapshots"; enabled: !projectRow.busy; onClicked: root.execute("snapshots", root.selectedName, "") }
                                }
                                Label { text: "Type to filter by name, or use the text to create a new snapshot. Start the project to create or restore."; width: parent.width; wrapMode: Text.Wrap; opacity: 0.65 }
                                Label { objectName: "snapshotEmpty-" + projectRow.modelData.name; visible: snapshotPanel.filteredSnapshots.length === 0; text: projectRow.busy && root.actionFor(projectRow.modelData.name) === "snapshots" ? "Loading snapshots…" : root.snapshots.length ? "No snapshots match this name." : "No local snapshots found." }
                                Repeater {
                                    model: root.selectedName === projectRow.modelData.name ? snapshotPanel.filteredSnapshots : []
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
                                            anchors.right: snapshotActions.left
                                            anchors.rightMargin: Style.space(12)
                                            anchors.verticalCenter: parent.verticalCenter
                                            spacing: Style.space(3)
                                            Label { width: parent.width; text: snapshotRow.modelData.name; elide: Text.ElideMiddle }
                                            Label { width: parent.width; text: new Date(snapshotRow.modelData.modified * 1000).toLocaleString() + " · " + root.sizeLabel(snapshotRow.modelData.size); elide: Text.ElideRight; color: root.muted; font.pixelSize: Style.font.caption }
                                        }
                                        Row {
                                            id: snapshotActions
                                            anchors.right: parent.right; anchors.rightMargin: Style.space(10); anchors.verticalCenter: parent.verticalCenter
                                            spacing: Style.space(4)
                                            Action {
                                                id: restoreSnapshot
                                                objectName: "restoreSnapshot-" + snapshotRow.modelData.name
                                                text: "Restore…"
                                                iconText: "󰕍"
                                                tooltipText: projectRow.running ? "Restore this snapshot" : "Start the project first"
                                                enabled: projectRow.running && !projectRow.busy && root.pendingRestore !== snapshotRow.modelData.path
                                                onClicked: {
                                                    root.pendingDelete = ""
                                                    root.pendingRestore = snapshotRow.modelData.path
                                                    root.pendingLabel = snapshotRow.modelData.name
                                                }
                                            }
                                            IconAction {
                                                objectName: "deleteSnapshot-" + snapshotRow.modelData.name
                                                iconText: "󰆴"; foreground: Commons.Color.urgent; tooltipText: "Delete snapshot"
                                                enabled: !projectRow.busy
                                                onClicked: { root.pendingRestore = ""; root.pendingDelete = snapshotRow.modelData.path; root.deleteLabel = snapshotRow.modelData.name }
                                            }
                                        }
                                    }
                                }
                                Column {
                                    width: parent.width; spacing: Style.space(6); visible: root.pendingDelete !== ""
                                    Label { width: parent.width; wrapMode: Text.Wrap; color: Commons.Color.urgent; text: "Delete snapshot “" + root.deleteLabel + "” from “" + root.selectedName + "”? This permanently removes the snapshot file. The current database is unchanged." }
                                    Row {
                                        spacing: Style.space(6)
                                        Action { objectName: "cancelDeleteSnapshot-" + projectRow.modelData.name; text: "Cancel"; onClicked: root.pendingDelete = "" }
                                        Action { objectName: "confirmDeleteSnapshot-" + projectRow.modelData.name; text: "Delete snapshot"; iconText: "󰆴"; foreground: Commons.Color.urgent; enabled: !projectRow.busy; onClicked: { var path = root.pendingDelete; root.pendingDelete = ""; root.execute("delete-snapshot", projectRow.modelData.name, path) } }
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
                                        Action { objectName: "confirmRestore-" + projectRow.modelData.name; tooltipText: projectRow.running ? "Replace the current database" : "Start the project first"; text: "Restore database"; iconText: "󰕍"; foreground: Commons.Color.urgent; enabled: projectRow.running && !projectRow.busy; onClicked: { var path = root.pendingRestore; root.pendingRestore = ""; root.execute("restore", root.selectedName, path) } }
                                    }
                                }
                            }
                            Column {
                                objectName: "console-" + projectRow.modelData.name
                                width: parent.width
                                spacing: Style.space(8)
                                visible: !projectRow.consoleState.dismissed && (!!projectRow.consoleState.action || !!projectRow.consoleState.message)
                                RowLayout {
                                    width: parent.width
                                    Label {
                                        visible: !projectRow.consoleBusy
                                        text: projectRow.consoleState.failed ? "󰅚" : "󰄬"
                                        color: projectRow.consoleState.failed ? Commons.Color.urgent : root.success
                                    }
                                    Label {
                                        Layout.fillWidth: true
                                        text: projectRow.consoleBusy ? "Command output" : projectRow.consoleState.message || "Console"
                                        color: projectRow.consoleState.failed ? Commons.Color.urgent : root.foreground
                                        elide: Text.ElideRight
                                        font.pixelSize: Style.font.caption
                                    }
                                    IconAction {
                                        iconText: projectRow.consoleState.open ? "󰅀" : "󰅃"
                                        objectName: "toggleConsole-" + projectRow.modelData.name
                                        tooltipText: projectRow.consoleState.open ? "Hide console" : "Show console"
                                        onClicked: root.updateOutput(projectRow.modelData.name, {open: !projectRow.consoleState.open})
                                    }
                                    IconAction {
                                        objectName: "closeConsole-" + projectRow.modelData.name
                                        iconText: "󰅖"
                                        tooltipText: projectRow.consoleBusy ? "Dismiss output · command continues" : "Dismiss command output"
                                        onClicked: root.updateOutput(projectRow.modelData.name, {dismissed: true, open: false})
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
    component Action: Button {
        id: actionButton
        focusable: true; bordered: true; fontSize: Style.font.caption; opacity: enabled ? 1 : 0.4
        HoverHandler { id: disabledHover }
        Controls.ToolTip {
            visible: !actionButton.enabled && disabledHover.hovered && text !== ""
            text: actionButton.tooltipText
            delay: 400
            padding: 0
            background: BorderSurface {
                color: actionButton.tooltipBackground
                borderSpec: actionButton._tooltipBorderSpec
                radius: 0
            }
            contentItem: Text {
                textFormat: Text.PlainText
                text: actionButton.tooltipText
                color: actionButton.tooltipForeground
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                leftPadding: Border.left(actionButton._tooltipBorderSpec) + Style.spacing.controlPaddingX
                rightPadding: Border.right(actionButton._tooltipBorderSpec) + Style.spacing.controlPaddingX
                topPadding: Border.top(actionButton._tooltipBorderSpec) + Style.spacing.controlPaddingY
                bottomPadding: Border.bottom(actionButton._tooltipBorderSpec) + Style.spacing.controlPaddingY
            }
        }
    }
    component ToolbarAction: Action {
        implicitHeight: Style.space(32)
        Layout.minimumWidth: implicitWidth
        Layout.alignment: Qt.AlignVCenter
        horizontalPadding: Style.space(5)
        verticalPadding: 0
        iconSize: Style.space(14)
    }
    component DetailTab: ToolbarAction {
        id: detailTab
        property string projectName: ""
        property string viewName: ""
        selected: root.isDetail(projectName, viewName)
        foreground: selected ? Commons.Color.accent : root.foreground
        color: selected ? Util.alpha(Commons.Color.accent, 0.24) : (hot || activeFocus ? Util.alpha(root.foreground, 0.08) : "transparent")
        borderSpec: Border.flat(selected || activeFocus ? Commons.Color.accent : Util.alpha(root.foreground, 0.2), 1)
        Rectangle {
            visible: detailTab.selected
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: Style.space(7); rightMargin: Style.space(7); bottomMargin: Style.space(2) }
            height: Style.space(3)
            radius: height / 2
            color: Commons.Color.accent
        }
    }
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
