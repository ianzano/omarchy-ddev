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
            var actions = ["openProjectSite", "openProjectLogs", "showProjectContainers", "openProjectMailpit", "restartProject"]
            for (var i = 0; i < actions.length; i++) {
                var button = root.testFind(actions[i] + "-stopped")
                test.check(!button.enabled && button.opacity < 0.5 && button.tooltipText === "Start the project first", "STOPPED_ACTION_DISABLED_" + i)
                test.check(root.testFind(actions[i] + "-demo").enabled, "RUNNING_ACTION_ENABLED_" + i)
            }
            test.check(root.testFind("openProjectFolder-stopped").enabled && root.testFind("showProjectSnapshots-stopped").enabled, "OFFLINE_ACTIONS_AVAILABLE")
            for (var action of ["snapshot", "restore", "domains", "browse", "browse-all", "mailpit", "restart"])
                test.check(!root.execute(action, "stopped", ""), "OFFLINE_EXECUTION_GUARD_" + action)
            root.selectLog("stopped")
            root.showApplications("stopped")
            test.check(!root.detailProject && !root.logJobs.stopped, "OFFLINE_DETAIL_GUARDS")
            root.selectProject("stopped")
        }
    }
    Timer {
        interval: 800; running: true
        onTriggered: {
            var root = plugin.item
            test.check(root.selectedName === "stopped" && root.snapshots.length === 1, "OFFLINE_SNAPSHOTS_LOADED")
            test.check(!root.testFind("createSnapshot-stopped").enabled && !root.testFind("restoreSnapshot-example.sql.gz").enabled, "OFFLINE_SNAPSHOT_MUTATIONS_DISABLED")
            root.closeDetails()
            root.selectLog("demo")
        }
    }
    Timer {
        interval: 1200; running: true
        onTriggered: {
            var root = plugin.item
            test.check(!!root.logJobs.demo, "RUNNING_LOGS_STARTED")
            root.projects = root.projects.map(p => Object.assign({}, p, {status: "stopped"}))
            test.check(!root.detailProject && !root.logFor("demo").open, "PROJECT_STOP_CLOSES_UNAVAILABLE_TAB")
        }
    }
    Timer {
        interval: 1600; running: true
        onTriggered: {
            test.check(!plugin.item.logJobs.demo, "STOPPED_PROJECT_READER_RELEASED")
            console.log("STOPPED_CHECKS_PASSED")
            Qt.quit()
        }
    }
    Timer { interval: 5000; running: true; onTriggered: Qt.quit() }
}
