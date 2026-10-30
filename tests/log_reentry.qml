import QtQuick
import Quickshell
ShellRoot {
    id: test
    function check(ok, label) { if (!ok) throw new Error(label); console.log(label + " OK") }
    function click() { plugin.item.testFind("openProjectLogs-demo").clicked() }
    Loader { id: plugin; source: "plugin/Panel.qml" }
    Timer { interval: 400; running: true; onTriggered: test.click() }
    Timer {
        interval: 800; running: true
        onTriggered: {
            var root = plugin.item
            test.check(!!root.logJobs.demo && root.logFor("demo").text.indexOf("[web]") >= 0, "INITIAL_LOG_STREAM_RUNNING")
            var text = root.logFor("demo").text
            root.updateLog("demo", {expanded: true})
            test.click()
            test.check(!root.logFor("demo").open && root.logJobs.demo.cancelled, "SECOND_CLICK_CLOSES_LOGS_AND_STOPS_FOLLOWER")
            test.click()
            test.check(root.logFor("demo").open && root.logFor("demo").expanded && root.logFor("demo").live, "THIRD_CLICK_REOPENS_WITH_SETTINGS")
            for (var i = 0; i < 20; i++) { test.click(); test.click() }
            test.check(root.logFor("demo").text === text && root.logFor("demo").open, "RAPID_TOGGLES_PRESERVE_OUTPUT_AND_FINAL_OPEN_STATE")
        }
    }
    Timer {
        interval: 1300; running: true
        onTriggered: {
            var root = plugin.item
            test.check(Object.keys(root.logJobs).length === 1 && !root.logJobs.demo.cancelled && root.logFor("demo").text.indexOf("[web]") >= 0, "RAPID_TOGGLES_HAVE_ONE_ACTIVE_FOLLOWER")
            root.setLogLive("demo", false)
        }
    }
    Timer {
        interval: 1600; running: true
        onTriggered: {
            var root = plugin.item
            test.check(!root.logJobs.demo, "PAUSED_FOLLOWER_CLEANED_UP")
            test.click()
            test.click()
            test.check(!root.logFor("demo").live && root.logFor("demo").expanded, "REOPEN_PRESERVES_LIVE_OFF_AND_EXPANSION")
        }
    }
    Timer {
        interval: 1900; running: true
        onTriggered: {
            var root = plugin.item
            test.check(root.logFor("demo").text.indexOf("[db]") >= 0 && !root.logJobs.demo, "REOPENED_SNAPSHOT_LOADED")
            root.setLogLive("demo", true)
            test.click()
            test.click()
        }
    }
    Timer {
        interval: 2400; running: true
        onTriggered: {
            var root = plugin.item
            test.check(!!root.logJobs.demo && !root.logJobs.demo.cancelled, "IMMEDIATE_TOGGLE_RECOVERS_FOLLOWER")
            for (var i = 0; i < 20; i++) { test.click(); test.click() }
        }
    }
    Timer {
        interval: 2900; running: true
        onTriggered: {
            var root = plugin.item
            test.check(Object.keys(root.logJobs).length === 1 && !root.logJobs.demo.cancelled && root.logFor("demo").open, "REPEATED_TOGGLES_KEEP_ONE_WORKING_STREAM")
            test.check(root.logFor("demo").text.indexOf("[db]") >= 0 && !root.logFor("demo").error, "REOPENED_LOGS_REMAIN_USABLE")
            test.click()
        }
    }
    Timer {
        interval: 3400; running: true
        onTriggered: {
            test.check(!plugin.item.logJobs.demo && !plugin.item.logFor("demo").open, "FINAL_TOGGLE_RELEASES_READER")
            console.log("LOG_REENTRY_CHECKS_PASSED")
            Qt.quit()
        }
    }
    Timer { interval: 6000; running: true; onTriggered: Qt.quit() }
}
