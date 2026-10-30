import QtQuick
import Quickshell
import qs.Commons
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
    function event(action, service) { return {id: service === "db" ? dbid : cid, project: "demo", service: service || "web", action: action} }
    Loader { id: plugin; source: "plugin/Panel.qml" }
    Timer {
        interval: 400; running: true
        onTriggered: {
            var root = plugin.item
            root.applyInventory(test.inventory("running", "healthy"), true)
            root.flushAlerts()
            test.check(root.testAlerts.length === 0, "NO_INITIAL_INVENTORY_ALERTS")
            root.applicationProject = "demo"
            test.check(root.containersFor("demo").length === 2 && root.containersFor("demo")[0].stats.cpu === "2.5%", "CONTAINER_INVENTORY_AND_STATS")
            root.receiveEvent(test.event("health_status: unhealthy"))
            root.receiveEvent(test.event("health_status: unhealthy", "db"))
            root.testFlushEarly()
            test.check(root.testAlerts.length === 0, "PROJECT_ALERTS_WAIT_FOR_EVENT_BURST_TO_SETTLE")
            root.flushAlerts()
            test.check(root.testAlerts.length === 1 && root.testAlerts[0].kind === "unhealthy" && root.testAlerts[0].project === "demo", "MULTIPLE_UNHEALTHY_SERVICES_ONE_PROJECT_ALERT")
            root.receiveEvent(test.event("health_status: healthy"))
            root.flushAlerts()
            test.check(root.testAlerts.length === 1, "PARTIAL_RECOVERY_IS_SILENT")
            root.receiveEvent(test.event("health_status: healthy", "db"))
            root.flushAlerts()
            test.check(root.testAlerts.length === 2 && root.testAlerts[1].kind === "recovered", "PROJECT_HEALTH_RECOVERY_ALERT")
            root.receiveEvent(test.event("die"))
            root.receiveEvent(test.event("die", "db"))
            root.flushAlerts()
            test.check(root.testAlerts.length === 3 && root.testAlerts[2].kind === "stopped", "MULTIPLE_CONTAINER_STOPS_ONE_PROJECT_ALERT")
            root.receiveEvent(test.event("start"))
            root.receiveEvent(test.event("start", "db"))
            root.flushAlerts()
            test.check(root.testAlerts.length === 3, "PROJECT_START_WAITS_UNTIL_READY")
            root.receiveEvent(test.event("health_status: healthy"))
            root.receiveEvent(test.event("health_status: healthy", "db"))
            root.flushAlerts()
            test.check(root.testAlerts.length === 4 && root.testAlerts[3].kind === "started", "MULTIPLE_CONTAINER_STARTS_ONE_PROJECT_ALERT")
            root.receiveEvent(test.event("health_status: healthy"))
            root.receiveEvent({project: "unregistered", service: "web", id: test.cid, action: "die"})
            root.flushAlerts()
            test.check(root.testAlerts.length === 4, "PROJECT_ALERTS_DEDUPLICATED_AND_SCOPED")
            root.selectLog("demo")
            test.check(root.execute("pause", "demo", test.cid), "PAUSE_ACCEPTED_WITH_PROJECT_LOG_STREAM_ACTIVE")
        }
    }
    Timer {
        interval: 1200; running: true
        onTriggered: {
            var root = plugin.item
            test.check(root.logFor("demo").text.indexOf("[web]") >= 0 && root.logFor("demo").text.indexOf("[db]") >= 0 && !!root.logJobs.demo, "ALL_SERVICES_IN_ONE_LIVE_LOG_STREAM")
            test.check(!root.busy && root.outputFor("demo").message === "Completed", "LOG_FOLLOW_DOES_NOT_LOCK_PROJECT_ACTIONS")
            root.setLogLive("demo", false)
            root.applyInventory(test.inventory("paused", "healthy"), true)
            root.flushAlerts()
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
            test.check(!!pauseButton && pauseButton.tooltipText === "Resume container" && pauseButton.enabled, "PAUSED_CONTAINER_SHOWS_RESUME")
            test.check(pauseButton.parent.parent.implicitHeight <= Style.space(48), "CONTAINER_OVERVIEW_IS_COMPACT")
            test.check(root.testFind("projectLogs-demo").text.indexOf("[db]") >= 0, "INLINE_PROJECT_LOG_VIEWER_RENDERED")
            test.check(!root.logJobs.demo && !root.logFor("demo").error, "STOPPING_LIVE_LOGS_CLEANS_UP_READER")
            pauseButton.clicked()
        }
    }
    Timer {
        interval: 2300; running: true
        onTriggered: {
            var root = plugin.item
            test.check(!root.busy && root.outputFor("demo").action === "resume", "RESUME_COMMAND_COMPLETED")
            root.applyInventory(test.inventory("running", "healthy"), true)
            root.flushAlerts()
            test.check(root.testAlerts.length === 4, "RESUME_IS_NOT_A_START_ALERT")
            root.applyInventory([], true)
            root.flushAlerts()
            test.check(root.testAlerts.length === 5 && root.testAlerts[4].kind === "stopped", "MISSING_CONTAINERS_ONE_PROJECT_STOP_ALERT")
            root.applyInventory([], true)
            root.flushAlerts()
            test.check(root.testAlerts.length === 5, "POLLING_PROJECT_ALERTS_DEDUPLICATED")
            root.updateLog("demo", {open: false})
            root.stopLog("demo", false)
            test.check(!root.logFor("demo").open, "LOG_VIEWER_CLOSES")
        }
    }
    Timer {
        interval: 2600; running: true
        onTriggered: {
            var root = plugin.item
            test.check(root.execute("start", "demo", ""), "MANAGED_START_ACCEPTED")
            root.receiveEvent(test.event("start"))
            root.receiveEvent(test.event("start", "db"))
            root.flushAlerts()
            test.check(root.testAlerts.length === 5, "NO_INTERMEDIATE_ALERTS_DURING_MANAGED_START")
        }
    }
    Timer {
        interval: 3500; running: true
        onTriggered: {
            var root = plugin.item
            test.check(!root.busy, "MANAGED_START_COMPLETED")
            root.flushAlerts()
            test.check(root.testAlerts.length === 5, "START_SUCCESS_WAITING_FOR_HEALTH")
            root.receiveEvent(test.event("health_status: healthy"))
            root.receiveEvent(test.event("health_status: healthy", "db"))
            root.flushAlerts()
            test.check(root.testAlerts.length === 6 && root.testAlerts[5].title === "Project started", "SINGLE_MANAGED_PROJECT_STARTED_NOTIFICATION")
            console.log("FEATURE_CHECKS_PASSED")
            Qt.quit()
        }
    }
    Timer { interval: 6000; running: true; onTriggered: Qt.quit() }
}
