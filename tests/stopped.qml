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
            var input = root.testFind("snapshotName-stopped")
            test.check(input.enabled, "OFFLINE_SNAPSHOT_FILTER_ENABLED")
            input.text = "EXAMPLE"
            test.check(root.testFind("snapshots-stopped").filteredSnapshots.length === 1, "SNAPSHOT_FILTER_IGNORES_CASE")
            input.text = "missing"
            test.check(root.testFind("snapshots-stopped").filteredSnapshots.length === 0 && root.testFind("snapshotEmpty-stopped").text === "No snapshots match this name.", "SNAPSHOT_FILTER_EMPTY_STATE")
            input.text = ""
            test.check(root.testFind("snapshots-stopped").filteredSnapshots.length === 1 && root.snapshots.length === 1, "CLEAR_FILTER_RESTORES_LIST")
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
            var root = plugin.item
            root.projects = root.projects.map(p => Object.assign({}, p, {status: p.name === "demo" ? "running" : "stopped"}))
            root.selectProject("demo")
        }
    }
    Timer {
        interval: 2000; running: true
        onTriggered: {
            var root = plugin.item
            root.testFind("snapshotName-demo").text = "new-backup"
            root.testFind("createSnapshot-demo").clicked()
            test.check(root.jobs.demo.actionName === "snapshot" && root.jobs.demo.command[4] === "new-backup", "FILTER_INPUT_STILL_NAMES_NEW_SNAPSHOT")
        }
    }
    Timer {
        interval: 2800; running: true
        onTriggered: {
            test.check(!plugin.item.busy, "NAMED_SNAPSHOT_ACTION_COMPLETED")
            console.log("STOPPED_CHECKS_PASSED")
            Qt.quit()
        }
    }
    Timer { interval: 5000; running: true; onTriggered: Qt.quit() }
}
