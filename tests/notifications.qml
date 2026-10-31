import QtQuick
import Quickshell
ShellRoot {
    id: test
    function check(ok, label) { if (!ok) throw new Error(label); console.log(label + " OK") }
    Loader { id: plugin; source: "plugin/Panel.qml" }
    Timer {
        interval: 400; running: true
        onTriggered: {
            var root = plugin.item
            root.testAlertTransport = true
            root.announce([{project: "demo", title: "Project unhealthy", detail: "private-service-雪", kind: "unhealthy"}, {project: "unknown", title: "Unknown", kind: "stopped"}])
        }
    }
    Timer {
        interval: 900; running: true
        onTriggered: {
            var root = plugin.item
            test.check(root.testNotifications.argv.length === 0, "NO_ALERT_PAYLOAD_IN_HELPER_ARGUMENTS")
            test.check(root.testNotifications.alerts.length === 1 && root.testNotifications.alerts[0].project === "demo" && root.testNotifications.alerts[0].detail === "private-service-雪", "DETAILS_ARRIVE_OVER_STDIN_AND_UNKNOWN_PROJECTS_FILTERED")
            test.check(root.notificationWarning === "", "NOTIFICATION_TRANSPORT_SUCCEEDED")
            root.alertsEnabled = false
            root.announce([{project: "demo", title: "Disabled", kind: "stopped"}])
        }
    }
    Timer {
        interval: 1300; running: true
        onTriggered: {
            test.check(plugin.item.testNotifications.alerts[0].title === "Project unhealthy", "DISABLED_ALERTS_DO_NOT_SEND")
            console.log("NOTIFICATIONS_CHECKS_PASSED")
            Qt.quit()
        }
    }
    Timer { interval: 4000; running: true; onTriggered: Qt.quit() }
}
