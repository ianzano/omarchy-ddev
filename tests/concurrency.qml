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
            test.check(!root.testFind("restartProject-stopped").enabled, "RESTART_DISABLED_FOR_STOPPED_PROJECT")
            test.check(!root.execute("restart", "stopped", ""), "RESTART_STOPPED_PROJECT_REJECTED")
            test.check(root.testFind("restartProject-spare").enabled && root.canRun("restart", "spare"), "RESTART_AVAILABLE_FOR_RUNNING_PROJECT")
            test.check(root.execute("stop", "demo", ""), "FIRST_STOP_ACCEPTED")
            test.check(!root.execute("restart", "demo", ""), "SAME_PROJECT_CONFLICT_BLOCKED")
            test.check(root.execute("stop", "other", ""), "SECOND_STOP_ACCEPTED")
            test.check(!root.execute("poweroff", "__all__", ""), "GLOBAL_CONFLICT_BLOCKED")
        }
    }
    Timer {
        interval: 900; running: true
        onTriggered: {
            var root = plugin.item
            test.check(Object.keys(root.jobs).length === 2, "TWO_CONCURRENT_PROCESSES")
            test.check(root.outputFor("demo").text.indexOf("demo stop first") >= 0 && root.outputFor("other").text.indexOf("other stop first") >= 0, "INDEPENDENT_LIVE_LOGS")
            test.check(!root.projectBusy("spare") && !root.testFind("powerSwitch-spare").busy, "THIRD_PROJECT_CONTROLS_AVAILABLE")
            test.check(root.testFind("powerSwitch-demo").busy && root.testFind("powerSwitch-other").busy, "INDEPENDENT_BUSY_SWITCHES")
            test.check(root.actionFor("demo") === "stop" && root.actionFor("other") === "stop", "INDEPENDENT_ACTION_LABELS")
            root.query = "other"
            test.check(Object.keys(root.jobs).length === 2, "FILTER_PRESERVES_JOBS")
        }
    }
    Timer {
        interval: 1500; running: true
        onTriggered: {
            var root = plugin.item
            test.check(!!root.jobs.demo && !root.jobs.other, "JOBS_FINISH_INDEPENDENTLY")
            test.check(root.outputFor("other").failed && !root.outputFor("demo").failed, "FAILURE_ISOLATED_TO_PROJECT")
            test.check(!root.canRun("poweroff", "__all__"), "GLOBAL_BLOCKED_UNTIL_ALL_FINISH")
            root.query = ""
        }
    }
    Timer {
        interval: 2400; running: true
        onTriggered: {
            var root = plugin.item
            test.check(!root.busy && Object.keys(root.jobs).length === 0, "JOBS_CLEANED_UP")
            test.check(root.outputFor("demo").message === "Completed" && root.outputFor("other").message === "Command failed", "INDEPENDENT_FINAL_RESULTS")
            test.check(root.execute("poweroff", "__all__", ""), "GLOBAL_ACTION_AFTER_PROJECTS")
            test.check(!root.execute("start", "demo", ""), "PROJECT_BLOCKED_DURING_GLOBAL_ACTION")
        }
    }
    Timer {
        interval: 3500; running: true
        onTriggered: {
            test.check(!plugin.item.busy && plugin.item.outputFor("__all__").message === "Completed", "GLOBAL_JOB_CLEANUP")
            console.log("CONCURRENCY_CHECKS_PASSED")
            Qt.quit()
        }
    }
    Timer { interval: 6000; running: true; onTriggered: Qt.quit() }
}
