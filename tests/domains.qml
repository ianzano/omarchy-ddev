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
            root.testFind("openProjectSite-demo").clicked()
            test.check(root.domainProject === "demo", "DOMAINS_BUTTON_OPENS_PICKER")
            var toolbar = root.testFind("projectActions-demo")
            var names = ["openProjectSite-demo", "openProjectLogs-demo", "showProjectContainers-demo", "showProjectSnapshots-demo", "showProjectCommands-demo", "openProjectMailpit-demo", "openProjectFolder-demo"]
            var edge = -1
            var top = -1
            for (var i = 0; i < names.length; i++) {
                var button = root.testFind(names[i])
                var point = button.mapToItem(toolbar, 0, 0)
                if (i === 0) top = point.y
                test.check(button.text.length > 0 && Math.abs(point.y - top) < 1 && point.x >= edge && point.x + button.width <= toolbar.width + 1, "LABELED_ACTION_FITS_" + i)
                edge = point.x + button.width
            }
        }
    }
    Timer {
        interval: 800; running: true
        onTriggered: {
            var root = plugin.item
            test.check(root.domainFor("demo").items.length === 2 && !root.busy, "MULTIPLE_DOMAINS_LOADED")
            test.check(root.testFind("openAllDomains-demo").enabled, "OPEN_ALL_AVAILABLE")
            root.testFind("openDomain-demo-admin.example.test").clicked()
            test.check(root.jobs.demo.actionName === "browse" && root.jobs.demo.command[4] === "https://admin.example.test", "INDIVIDUAL_DOMAIN_SELECTED")
        }
    }
    Timer {
        interval: 1500; running: true
        onTriggered: {
            var root = plugin.item
            test.check(!root.busy && root.outputFor("demo").action === "browse", "INDIVIDUAL_DOMAIN_ACTION_COMPLETED")
            root.testFind("openAllDomains-demo").clicked()
            test.check(root.jobs.demo.actionName === "browse-all" && root.jobs.demo.command.length === 4, "OPEN_ALL_ACTION_DISPATCHED")
        }
    }
    Timer {
        interval: 2200; running: true
        onTriggered: {
            var root = plugin.item
            test.check(!root.busy && root.outputFor("demo").action === "browse-all", "OPEN_ALL_COMPLETED")
            root.testFind("openProjectSite-demo").clicked()
            test.check(root.domainProject === "", "DOMAINS_BUTTON_CLOSES_PICKER")
            root.testFind("openProjectSite-demo").clicked()
        }
    }
    Timer {
        interval: 2500; running: true
        onTriggered: {
            var root = plugin.item
            test.check(!root.busy && root.domainFor("demo").items.length === 2 && root.outputFor("demo").action === "browse-all", "DOMAIN_REFRESH_PRESERVES_COMMAND_OUTPUT")
            console.log("DOMAINS_CHECKS_PASSED")
            Qt.quit()
        }
    }
    Timer { interval: 5000; running: true; onTriggered: Qt.quit() }
}
