import QtQuick
import Quickshell
ShellRoot {
    id: test
    function check(ok, label) { if (!ok) throw new Error(label); console.log(label + " OK") }
    Loader { id: plugin; source: "plugin/Panel.qml" }
    Timer { interval: 400; running: true; onTriggered: plugin.item.testFind("showProjectCommands-demo").clicked() }
    Timer {
        interval: 700; running: true
        onTriggered: {
            var root = plugin.item
            test.check(root.isDetail("demo", "commands") && !root.busy && root.testFind("runCommand-ddev:cache-clear"), "DISCOVERED_COMMANDS_SHOWN_WITHOUT_SAVED_SHORTCUTS")
            root.testFind("commandFilter-demo").text = "UNMATCHED"
            test.check(root.testFind("commandEmpty-demo").text === "No commands match this search.", "COMMAND_SEARCH_EMPTY_STATE")
            root.testFind("commandFilter-demo").text = ""
            root.testFind("addCommand-demo").clicked()
            root.testFind("commandLabel-demo").text = "Clear cache"
            root.testFind("commandValue-demo").text = "drush cr"
            root.testFind("saveCommand-demo").clicked()
        }
    }
    Timer {
        interval: 1000; running: true
        onTriggered: {
            var root = plugin.item
            test.check(root.commandsFor("demo").items.length === 2 && !root.outputFor("demo").action, "SAVE_SHORTCUT_WITHOUT_CONSOLE_NOISE")
            root.testFind("runCommand-shortcut-demo").clicked()
            test.check(root.jobs.demo.actionName === "custom-command", "SHORTCUT_EXECUTED")
        }
    }
    Timer {
        interval: 1500; running: true
        onTriggered: {
            var root = plugin.item
            test.check(!root.busy && root.outputFor("demo").text.indexOf("Example shortcut") >= 0, "SHORTCUT_OUTPUT_IN_EXISTING_CONSOLE")
            root.testFind("manageCommands-demo").clicked()
            root.testFind("editCommand-shortcut-demo").clicked()
            test.check(root.testFind("commandValue-demo").text === "drush cr", "EDIT_PREFILLS_COMMAND")
            root.testFind("commandLabel-demo").text = "Rebuild cache"
            root.testFind("saveCommand-demo").clicked()
        }
    }
    Timer {
        interval: 1800; running: true
        onTriggered: {
            var root = plugin.item
            test.check(root.commandsFor("demo").items.length === 2 && root.commandsFor("demo").items[0].label === "Rebuild cache", "EDIT_UPDATES_EXISTING_SHORTCUT")
            root.testFind("deleteCommand-shortcut-demo").clicked()
        }
    }
    Timer {
        interval: 2100; running: true
        onTriggered: {
            var root = plugin.item
            test.check(root.commandsFor("demo").items.length === 1 && root.testFind("runCommand-ddev:cache-clear"), "REMOVE_SHORTCUT_PRESERVES_DISCOVERED_COMMAND")
            root.selectProject("stopped")
        }
    }
    Timer {
        interval: 2400; running: true
        onTriggered: {
            var root = plugin.item
            test.check(root.snapshots.length === 1 && root.testFind("openSnapshotFolder-stopped").enabled, "OFFLINE_SNAPSHOT_FOLDER_AVAILABLE")
            root.testFind("deleteSnapshot-before.sql.gz").clicked()
            test.check(root.pendingDelete !== "" && !root.jobs.stopped && root.snapshots.length === 1, "DELETE_REQUIRES_CONFIRMATION")
            root.testFind("cancelDeleteSnapshot-stopped").clicked()
            test.check(root.pendingDelete === "" && root.snapshots.length === 1, "CANCEL_KEEPS_SNAPSHOT")
            root.testFind("deleteSnapshot-before.sql.gz").clicked()
            root.showCommands("demo")
            test.check(root.pendingDelete === "", "SWITCH_TAB_CLEARS_DELETE_CONFIRMATION")
        }
    }
    Timer { interval: 2700; running: true; onTriggered: plugin.item.selectProject("stopped") }
    Timer {
        interval: 3000; running: true
        onTriggered: {
            var root = plugin.item
            root.testFind("deleteSnapshot-before.sql.gz").clicked()
            root.testFind("confirmDeleteSnapshot-stopped").clicked()
            test.check(root.jobs.stopped.actionName === "delete-snapshot", "CONFIRMED_DELETE_EXECUTED")
        }
    }
    Timer {
        interval: 3300; running: true
        onTriggered: {
            test.check(plugin.item.snapshots.length === 0 && !plugin.item.busy, "DELETED_SNAPSHOT_REMOVED_FROM_LIST")
            plugin.item.open()
        }
    }
    Timer {
        interval: 3500; running: true
        onTriggered: {
            var root = plugin.item
            test.check(root.testFind("openProjectFolder-stopped").enabled && !root.testFind("openProjectMailpit-stopped").enabled, "SEPARATE_LAUNCH_BUTTONS_OFFLINE_AVAILABILITY")
            root.testFind("openProjectFolder-stopped").clicked()
            test.check(root.jobs.stopped.actionName === "folder", "FOLDER_BUTTON_DISPATCHES_ACTION")
        }
    }
    Timer {
        interval: 3900; running: true
        onTriggered: {
            test.check(!plugin.item.busy, "FOLDER_ACTION_COMPLETED")
            console.log("SHORTCUTS_CHECKS_PASSED")
            Qt.quit()
        }
    }
    Timer { interval: 6000; running: true; onTriggered: Qt.quit() }
}
