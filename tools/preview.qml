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
