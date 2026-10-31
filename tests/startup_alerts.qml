import QtQuick
import Quickshell
import "plugin/Monitoring.js" as Monitor
ShellRoot {
    id: test
    property var registered: [{name: "demo", status: "running"}]
    function check(ok, label) { if (!ok) throw new Error(label); console.log(label + " OK") }
    function inventory(health) { return [{project: "demo", service: "web", id: "web", state: "running", health: "healthy"}, {project: "demo", service: "admin", id: "new", state: "running", health: health}] }
    function event(action, service, id) { Monitor.event({project: "demo", service: service || "admin", id: id || "new", action: action}, true, registered) }
    function flush(ms) { return Monitor.flush([], Date.now() + (ms || 2100)) }
    Timer { interval: 100; running: true; onTriggered: {
        Monitor.inventory(inventory("healthy"), true, registered)
        Monitor.beginning("demo", "restart")
        event("start", "admin", "replacement")
        event("die", "admin", "new")
        test.check(Monitor.states[Monitor.key("demo", "admin")].id === "replacement" && Monitor.states[Monitor.key("demo", "admin")].state === "running", "OLD_CONTAINER_EXIT_IGNORED")
        event("health_status: unhealthy", "admin", "replacement")
        test.check(flush().length === 0, "NO_HEALTH_ALERT_DURING_RESTART")
        var alerts = Monitor.completed("demo", "restart", true)
        test.check(alerts.length === 1 && alerts[0].kind === "restarted", "RESTART_SUCCESS_IS_IMMEDIATE_WITHOUT_WAITING_FOR_CACHED_HEALTH")
        test.check(flush(61000).length === 0, "NO_DELAYED_STARTUP_WARNING_FROM_OLD_OBSERVATIONS")
        Monitor.inventory(inventory("healthy"), true, registered)
        test.check(flush().length === 0, "FRESH_POST_START_INVENTORY_DOES_NOT_DUPLICATE_SUCCESS")
        event("health_status: unhealthy")
        test.check(flush()[0].kind === "unhealthy", "REAL_POST_START_FAILURE_HAS_NO_EXTRA_DELAY")
        event("health_status: healthy")
        test.check(flush()[0].kind === "recovered", "REAL_RECOVERY_REPORTED")
        Monitor.beginning("demo", "stop")
        event("die")
        event("health_status: unhealthy")
        test.check(Monitor.states[Monitor.key("demo", "admin")].state === "exited", "LATE_HEALTH_CANNOT_RESURRECT_EXITED_CONTAINER")
        test.check(flush().length === 0, "PARTIAL_SHUTDOWN_DOES_NOT_ALERT")
        alerts = Monitor.completed("demo", "stop", true)
        test.check(alerts.length === 1 && alerts[0].kind === "stopped", "STOP_SUCCESS_IS_IMMEDIATE")
        event("health_status: unhealthy", "web", "web")
        event("die", "web", "web")
        Monitor.inventory(inventory("unhealthy"), true, registered)
        test.check(flush().length === 0 && flush(61000).length === 0, "NO_ATTENTION_OR_DUPLICATE_STOP_AFTER_SHUTDOWN")
        // A real external start releases the completed-stop barrier.
        event("start", "web", "web")
        event("start")
        event("health_status: healthy", "web", "web")
        event("health_status: healthy")
        test.check(flush()[0].kind === "started", "EXTERNAL_START_AFTER_STOP_IS_DETECTED")
        Monitor.beginning("demo", "start")
        test.check(Monitor.completed("demo", "start", false).length === 0, "FAILED_COMMAND_HAS_NO_SUCCESS_NOTIFICATION")
        // Polling can also detect a start when the event stream was unavailable.
        Monitor.beginning("demo", "stop")
        Monitor.completed("demo", "stop", true)
        Monitor.inventory([], true, [{name: "demo", status: "stopped"}])
        Monitor.inventory(inventory("healthy"), true, registered)
        test.check(flush()[0].kind === "started", "POLL_DETECTED_START_RELEASES_COMPLETED_STOP")
        console.log("STARTUP_ALERTS_CHECKS_PASSED")
        Qt.quit()
    } }
    Timer { interval: 5000; running: true; onTriggered: Qt.quit() }
}
