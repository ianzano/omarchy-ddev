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
            root.testFind("showProjectContainers-demo").clicked()
            test.check(root.testFind("showProjectContainers-demo").selected, "CONTAINERS_TAB_HIGHLIGHTED")
            root.testFind("openProjectLogs-demo").clicked()
            test.check(!root.applicationProject && !root.testFind("showProjectContainers-demo").selected && root.testFind("openProjectLogs-demo").selected, "SWITCH_REPLACES_ACTIVE_TAB_AND_HIGHLIGHT")
            test.check(!root.testFind("openProjectFolder-demo").selected, "LAUNCH_ACTION_IS_NOT_A_TAB")
        }
    }
    Timer {
        interval: 800; running: true
        onTriggered: {
            var root = plugin.item
            test.check(!!root.logJobs.demo && root.logFor("demo").open, "LOG_READER_STARTED")
            root.activateDetail("other", "containers")
            test.check(root.applicationProject === "other" && !root.logFor("demo").open && root.logJobs.demo.cancelled, "CROSS_PROJECT_SWITCH_CLOSES_LOGS")
            test.check(!root.testFind("openProjectLogs-demo").selected, "PREVIOUS_PROJECT_HIGHLIGHT_CLEARED")
            root.selectProject("demo")
            test.check(root.selectedName === "demo" && !root.applicationProject, "SNAPSHOTS_REPLACE_OTHER_PROJECT_DETAIL")
            root.selectProject("demo")
            test.check(!root.detailProject && !root.selectedName, "SELECTED_TAB_CLOSES_WHILE_LOADING")
        }
    }
    Timer {
        interval: 1600; running: true
        onTriggered: {
            var root = plugin.item
            test.check(!root.logJobs.demo && !root.detailProject && root.snapshots.length === 0, "HIDDEN_READER_RELEASED_AND_LATE_RESULT_STAYS_CLOSED")
            root.showApplications("demo")
            root.showApplications("demo")
            test.check(!root.detailProject && !root.testFind("showProjectContainers-demo").selected, "SECOND_CLICK_CLEARS_SELECTION")
            console.log("TABS_CHECKS_PASSED")
            Qt.quit()
        }
    }
    Timer { interval: 5000; running: true; onTriggered: Qt.quit() }
}
