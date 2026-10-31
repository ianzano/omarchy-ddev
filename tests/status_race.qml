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
            root.applyInventory([{project: "demo", service: "admin", id: "stale", state: "running", health: "unhealthy"}], false)
            test.check(root.testFind("projectStatus-demo").text === "Running · unhealthy", "RUNNING_UNHEALTHY_PROJECT_IS_REPORTED")
            root.refresh()
            test.check(root.execute("stop", "demo", ""), "STOP_ACCEPTED_DURING_STATUS_READ")
        }
    }
    Timer {
        interval: 1000; running: true
        onTriggered: {
            var root = plugin.item
            test.check(!root.busy && root.testFind("projectStatus-demo").text === "Stopped", "STOP_RESULT_UPDATES_CARD_IMMEDIATELY")
            test.check(root.containersFor("demo").length === 0, "STOP_CLEARS_OLD_SERVICE_OBSERVATIONS")
        }
    }
    Timer {
        interval: 2100; running: true
        onTriggered: {
            test.check(plugin.item.testFind("projectStatus-demo").text === "Stopped", "PRE_STOP_RUNNING_RESPONSE_CANNOT_RESTORE_STALE_STATUS")
        }
    }
    Timer {
        interval: 3100; running: true
        onTriggered: {
            test.check(plugin.item.testFind("projectStatus-demo").text === "Stopped", "FRESH_STATUS_READ_CONFIRMS_STOPPED")
            console.log("STATUS_RACE_CHECKS_PASSED")
            Qt.quit()
        }
    }
    Timer { interval: 5000; running: true; onTriggered: Qt.quit() }
}
