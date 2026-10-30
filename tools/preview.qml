import QtQuick
import QtQuick.Window
import Quickshell
import qs.Commons
import qs.Commons as Commons

ShellRoot {
    id: preview
    readonly property string scene: Quickshell.env("DDEV_PREVIEW_SCENE")
    readonly property string outputPath: Quickshell.env("DDEV_PREVIEW_OUTPUT")
    function project(name, state, type) {
        return {name: name, status: state, type: type, approot: "/projects/" + name, shortroot: "~/Projects/" + name}
    }
    function configure() {
        var panel = plugin.item
        if (!panel) return
        panel.projects = scene === "overview"
            ? [project("storefront", "running", "php"), project("api-service", "running", "laravel"), project("docs-site", "stopped", "php")]
            : [project("storefront", scene === "console" ? "stopped" : "running", "php"), project("docs-site", "stopped", "php")]
        if (scene === "applications" || scene === "logs") panel.projects = [project("storefront", "running", "php")]
        var demoContainers = []
        for (var i = 0; i < panel.projects.length; i++) {
            var application = panel.projects[i]
            if (application.status !== "running") continue
            demoContainers.push({id: "a".repeat(64), project: application.name, service: "web", name: "ddev-" + application.name + "-web", state: "running", health: "healthy", stats: {cpu: "2.5%", memory: "128MiB / 8GiB", network: "24kB / 18kB", disk: "1MB / 4MB", pids: "18"}})
            demoContainers.push({id: "b".repeat(64), project: application.name, service: "db", name: "ddev-" + application.name + "-db", state: "running", health: "healthy", stats: {cpu: "0.7%", memory: "64MiB / 8GiB", network: "8kB / 12kB", disk: "12MB / 3MB", pids: "9"}})
        }
        panel.applyInventory(demoContainers, false)
        if (scene === "applications") panel.applicationProject = "storefront"
        if (scene === "logs") panel.updateLog("storefront", {id: "a".repeat(64), service: "web", open: true, live: true, expanded: true, error: "", text: "2026-01-01T12:00:00Z Web server ready\n2026-01-01T12:00:01Z GET / 200\n2026-01-01T12:00:02Z GET /assets/app.css 200\n2026-01-01T12:00:05Z GET /api/products 200"})
        if (scene === "snapshots") {
            panel.selectedName = "storefront"
            panel.snapshots = [
                {name: "before-release-mariadb_11.8.zst", path: "/example/snapshots/before-release-mariadb_11.8.zst", size: 48234496, modified: 1768471200},
                {name: "baseline-mariadb_11.8.zst", path: "/example/snapshots/baseline-mariadb_11.8.zst", size: 36700160, modified: 1768384800}
            ]
        }
        if (scene === "console") {
            panel.updateOutput("storefront", {
                action: "start", message: "", open: true, expanded: false, failed: false,
                text: "Starting storefront…\nCreating project containers…\nContainer ddev-storefront-db Started\nContainer ddev-storefront-web Started\nWaiting for containers to become ready…\nChecking database health…"
            })
            panel.jobs = {storefront: {actionName: "start", startedAt: Date.now() - 5000}}
            panel.clockNow = Date.now()
            panel.open()
        }
    }
    Component.onCompleted: {
        Commons.Color.background = "#141b25"
        Commons.Color.foreground = "#e4eaf3"
        Commons.Color.accent = "#8ab8f4"
        Commons.Color.urgent = "#ed9292"
        Commons.Color.muted = "#8998ac"
        Style.fontFamily = "JetBrainsMono Nerd Font"
        Style.fontBaseSize = 14
        Style.cornerRadius = 8
    }
    Window {
        id: window
        visible: true
        width: plugin.item ? plugin.item.previewWidth + 32 : 542
        height: plugin.item ? plugin.item.previewHeight + 32 : 700
        color: "transparent"
        title: "DDEV Projects preview"
        Rectangle {
            id: panelImage
            anchors.fill: parent
            color: Commons.Color.background
            border.width: 1
            border.color: "#30435c"
            radius: Style.cornerRadius
            Loader {
                id: plugin
                x: 16
                y: 16
                width: item ? item.previewWidth : 510
                height: item ? item.previewHeight : 668
                source: "plugin/Panel.qml"
                onLoaded: preview.configure()
            }
        }
        Timer {
            interval: 900
            running: true
            onTriggered: {
                panelImage.grabToImage(function(result) {
                    if (!result.saveToFile(preview.outputPath)) console.error("Could not save preview")
                    else console.log("PREVIEW_SAVED")
                    Qt.quit()
                })
            }
        }
    }
}
