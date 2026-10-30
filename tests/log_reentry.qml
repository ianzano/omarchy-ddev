import QtQuick
import Quickshell
ShellRoot {
    id: test
    property var initialReader: null
    function check(ok, label) { if (!ok) throw new Error(label); console.log(label + " OK") }
    Loader { id: plugin; source: "plugin/Panel.qml" }
    Timer { interval: 400; running: true; onTriggered: plugin.item.testFind("openProjectLogs-demo").clicked() }
    Timer {
        interval: 800; running: true
        onTriggered: {
            var root = plugin.item
            test.initialReader = root.logJobs.demo
            test.check(!!test.initialReader && root.logFor("demo").text.indexOf("[web]") >= 0, "INITIAL_LOG_STREAM_RUNNING")
            var text = root.logFor("demo").text
            root.updateLog("demo", {expanded: true})
            for (var i = 0; i < 20; i++) root.testFind("openProjectLogs-demo").clicked()
            test.check(root.logFor("demo").text === text, "REPEATED_LOG_CLICKS_PRESERVE_TEXT")
            test.check(root.logJobs.demo === test.initialReader && Object.keys(root.logJobs).length === 1, "REPEATED_LOG_CLICKS_KEEP_ONE_READER")
            test.check(root.logFor("demo").expanded, "REPEATED_CLICKS_PRESERVE_EXPANSION")
            root.setLogLive("demo", false)
        }
    }
    Timer {
        interval: 1200; running: true
        onTriggered: {
            var root = plugin.item
            test.check(!root.logJobs.demo, "PAUSED_FOLLOWER_CLEANED_UP")
            root.testFind("openProjectLogs-demo").clicked()
            test.check(!root.logFor("demo").live, "REOPEN_PRESERVES_LIVE_OFF")
        }
    }
    Timer {
        interval: 1500; running: true
        onTriggered: {
            var root = plugin.item
            test.check(root.logFor("demo").text.indexOf("[db]") >= 0 && !root.logJobs.demo, "REOPENED_SNAPSHOT_LOADED")
            root.setLogLive("demo", true)
            root.testFind("closeProjectLogs-demo").clicked()
            root.testFind("openProjectLogs-demo").clicked()
        }
    }
    Timer {
        interval: 2000; running: true
        onTriggered: {
            var root = plugin.item
            test.check(!!root.logJobs.demo && !root.logJobs.demo.cancelled && root.logFor("demo").text.indexOf("[web]") >= 0, "IMMEDIATE_CLOSE_REOPEN_RECOVERS_FOLLOWER")
            for (var i = 0; i < 20; i++) {
                root.testFind("closeProjectLogs-demo").clicked()
                root.testFind("openProjectLogs-demo").clicked()
            }
        }
    }
    Timer {
        interval: 2500; running: true
        onTriggered: {
            var root = plugin.item
            test.check(Object.keys(root.logJobs).length === 1 && !root.logJobs.demo.cancelled && root.logFor("demo").open, "RAPID_CLOSE_REOPEN_HAS_ONE_ACTIVE_FOLLOWER")
            test.check(root.logFor("demo").text.indexOf("[db]") >= 0 && !root.logFor("demo").error, "RAPID_REOPEN_PRESERVES_WORKING_LOGS")
            root.testFind("closeProjectLogs-demo").clicked()
        }
    }
    Timer {
        interval: 3000; running: true
        onTriggered: {
            test.check(!plugin.item.logJobs.demo && !plugin.item.logFor("demo").open, "FINAL_CLOSE_RELEASES_READER")
            console.log("LOG_REENTRY_CHECKS_PASSED")
            Qt.quit()
        }
    }
    Timer { interval: 6000; running: true; onTriggered: Qt.quit() }
}
