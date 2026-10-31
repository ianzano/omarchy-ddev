import QtQuick
import Quickshell
import "plugin/Monitoring.js" as Monitor
ShellRoot {
    id: test
    function check(ok, label) { if (!ok) throw new Error(label); console.log(label + " OK") }
    function inventory(health) { return [{project: "demo", service: "web", id: "web", state: "running", health: "healthy"}, {project: "demo", service: "admin", id: "old", state: "running", health: health}] }
    function event(action, id) { Monitor.event({project: "demo", service: "admin", id: id || "new", action: action}, true, [{name: "demo", status: "running"}]) }
    function flush(ms) { return Monitor.flush([], Date.now() + ms) }
    Timer { interval: 100; running: true; onTriggered: {
        var projects = [{name: "demo", status: "running"}]
        Monitor.inventory(inventory("healthy"), true, projects)
        Monitor.beginning("demo", "restart")
        event("start")
        event("die", "old")
        test.check(Monitor.states[Monitor.key("demo", "admin")].id === "new" && Monitor.states[Monitor.key("demo", "admin")].state === "running", "LATE_OLD_CONTAINER_EVENT_IGNORED")
        event("health_status: unhealthy")
        Monitor.completed("demo", "restart", true)
        test.check(flush(3000).length === 0, "TRANSIENT_ADDON_FAILURE_SUPPRESSED_AFTER_COMMAND_COMPLETES")
        event("health_status: healthy")
        var alerts = flush(3000)
        test.check(alerts.length === 1 && alerts[0].kind === "restarted", "STARTUP_RECOVERY_EMITS_ONLY_RESTARTED")
        event("health_status: unhealthy")
        alerts = flush(3000)
        test.check(alerts.length === 1 && alerts[0].kind === "unhealthy", "FAILURE_AFTER_READY_REPORTED_WITHOUT_STARTUP_DELAY")
        event("health_status: healthy")
        test.check(flush(3000)[0].kind === "recovered", "REAL_FAILURE_RECOVERY_REPORTED")
        event("start", "third")
        event("health_status: unhealthy", "third")
        test.check(flush(3000).length === 0, "EXTERNAL_SERVICE_START_HAS_WARMUP")
        // Inventory polling must not renew the deadline indefinitely.
        Monitor.inventory([{project: "demo", service: "web", id: "web", state: "running", health: "healthy"}, {project: "demo", service: "admin", id: "third", state: "running", health: "unhealthy"}], true, projects)
        alerts = flush(61000)
        test.check(alerts.length === 1 && alerts[0].kind === "unhealthy", "PERSISTENT_STARTUP_FAILURE_REPORTED_AFTER_GRACE")
        var late = [{name: "late", status: "running"}]
        Monitor.inventory([{project: "late", service: "admin", id: "late", state: "running", health: "starting"}], true, late)
        Monitor.inventory([{project: "late", service: "admin", id: "late", state: "running", health: "unhealthy"}], true, late)
        test.check(flush(3000).length === 0, "POLL_DISCOVERED_STARTUP_HAS_GRACE_WITHOUT_START_EVENT")
        Monitor.register([{name: "empty", status: "stopped"}])
        Monitor.beginning("empty", "start")
        Monitor.completed("empty", "start", true)
        test.check(flush(3000).length === 0, "NO_CONTAINERS_WAIT_FOR_STARTUP")
        alerts = flush(61000)
        test.check(alerts.some(a => a.project === "empty" && a.kind === "unhealthy"), "START_WITH_NO_SURVIVING_CONTAINERS_EVENTUALLY_ALERTS")
        console.log("STARTUP_ALERTS_CHECKS_PASSED")
        Qt.quit()
    } }
    Timer { interval: 5000; running: true; onTriggered: Qt.quit() }
}
