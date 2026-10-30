import QtQuick
import Quickshell
ShellRoot {
    id: test
    property string cid: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    property string dbid: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    function check(ok, label) { if (!ok) throw new Error(label); console.log(label + " OK") }
    function inventory(state, health) {
        return [{id: cid, name: "ddev-demo-web", project: "demo", service: "web", state: state, health: health,
            stats: state === "running" ? {cpu: "2.5%", memory: "32MiB / 8GiB", network: "1kB / 2kB", disk: "0B / 1MB", pids: "12"} : null},
            {id: dbid, name: "ddev-demo-db", project: "demo", service: "db", state: "running", health: "healthy", stats: null}]
    }
    function event(action) { return {id: cid, project: "demo", service: "web", action: action} }
    Loader { id: plugin; source: "plugin/Panel.qml" }
    Timer {
        interval: 400; running: true
        onTriggered: {
            var root = plugin.item
            root.applyInventory(test.inventory("running", "healthy"), true)
            test.check(root.testAlerts.length === 0, "NO_INITIAL_INVENTORY_ALERTS")
            root.applicationProject = "demo"
            test.check(root.containersFor("demo").length === 2 && root.containersFor("demo")[0].stats.cpu === "2.5%", "CONTAINER_INVENTORY_AND_STATS")
            root.receiveEvent(test.event("health_status: unhealthy"))
            root.receiveEvent(test.event("health_status: unhealthy"))
            test.check(root.testAlerts.length === 1 && root.testAlerts[0].kind === "unhealthy", "UNHEALTHY_ALERT_DEDUPLICATED")
            root.receiveEvent(test.event("health_status: healthy"))
            test.check(root.testAlerts.length === 2 && root.testAlerts[1].kind === "recovered", "HEALTH_RECOVERY_ALERT")
            root.receiveEvent(test.event("die"))
            root.receiveEvent(test.event("die"))
            test.check(root.testAlerts.length === 3 && root.testAlerts[2].kind === "stopped", "STOP_ALERT_DEDUPLICATED")
            root.receiveEvent(test.event("start"))
            root.receiveEvent(test.event("start"))
            test.check(root.testAlerts.length === 4 && root.testAlerts[3].kind === "started", "START_ALERT_DEDUPLICATED")
            root.receiveEvent({project: "unregistered", service: "web", id: test.cid, action: "die"})
            test.check(root.testAlerts.length === 4, "UNREGISTERED_PROJECT_EVENTS_IGNORED")
            root.selectLog("demo", root.containersFor("demo")[0])
            test.check(root.execute("pause", "demo", test.cid), "PAUSE_ACCEPTED_WITH_LOG_READER_ACTIVE")
        }
    }
    Timer {
        interval: 1200; running: true
        onTriggered: {
            var root = plugin.item
            test.check(root.logFor("demo").text.indexOf("Example request accepted") >= 0 && !root.logJobs.demo, "CONTAINER_LOGS_LOADED")
            test.check(!root.busy && root.outputFor("demo").message === "Completed", "PAUSE_COMMAND_COMPLETED")
            root.applyInventory(test.inventory("paused", "healthy"), true)
            test.check(root.testAlerts.length === 4, "PAUSE_IS_NOT_A_STOP_ALERT")
            test.check(!root.canRun("restart", "demo"), "RESTART_BLOCKED_WHILE_PAUSED")
            root.updateLog("demo", {expanded: true})
        }
    }
    Timer {
        interval: 1500; running: true
        onTriggered: {
            var root = plugin.item
            var pauseButton = root.testFind("pauseContainer-" + test.cid)
            test.check(!!pauseButton && pauseButton.text === "Resume" && pauseButton.enabled, "PAUSED_CONTAINER_SHOWS_RESUME")
            test.check(root.testFind("containerLogs-demo").text.indexOf("Example response sent") >= 0, "INLINE_LOG_VIEWER_RENDERED")
            pauseButton.clicked()
        }
    }
    Timer {
        interval: 2300; running: true
        onTriggered: {
            var root = plugin.item
            test.check(!root.busy && root.outputFor("demo").action === "resume", "RESUME_COMMAND_COMPLETED")
            root.applyInventory(test.inventory("running", "healthy"), true)
            test.check(root.testAlerts.length === 4, "RESUME_IS_NOT_A_START_ALERT")
            root.applyInventory([], true)
            var count = root.testAlerts.length
            test.check(count === 6, "MISSING_CONTAINERS_TRIGGER_STOP_ALERTS")
            root.applyInventory([], true)
            test.check(root.testAlerts.length === count, "POLLING_STOP_ALERTS_DEDUPLICATED")
            root.updateLog("demo", {open: false})
            test.check(!root.logFor("demo").open, "LOG_VIEWER_CLOSES")
            console.log("FEATURE_CHECKS_PASSED")
            Qt.quit()
        }
    }
    Timer { interval: 5000; running: true; onTriggered: Qt.quit() }
}
