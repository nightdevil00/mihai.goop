import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
    id: root

    moduleName: "mihai.goop"

    property var svc: null
    function lookup() {
        if (svc) return
        try {
            if (bar && bar.shell) {
                if (typeof bar.shell.serviceFor === "function")
                    svc = bar.shell.serviceFor(moduleName)
                else if (bar.shell.services && bar.shell.services[moduleName])
                    svc = bar.shell.services[moduleName]
            }
        } catch (e) { svc = null }
    }
    onBarChanged: lookup()
    onSvcChanged: {}
    Timer {
        interval: 250
        repeat: true
        running: root.svc === null
        onTriggered: root.lookup()
    }

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    WidgetButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        labelVisible: false
        hasVisualContent: true
        tooltipText: "goop"
        fixedWidth: root.vertical ? -1 : Math.round(content.implicitWidth + scaledHorizontalMargin * 2)
        fixedHeight: root.vertical ? Math.round(content.implicitHeight + scaledVerticalPadding * 2) : -1

        onPressed: function(buttonCode) {
            if (buttonCode === Qt.LeftButton && root.svc) {
                const g = mapToGlobal(content.x + content.width / 2, content.y + content.height + 8)
                root.svc.requestPrompt(g.x, g.y)
            }
        }

        Text {
            id: content
            anchors.centerIn: parent
            text: "😈"
            font.family: "Noto Color Emoji"
            font.pixelSize: Math.round(Style.bar.iconCanvas * 1.2)
        }
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        onClicked: (mouse) => {
            if (!root.svc) return
            const g = mapToGlobal(mouse.x, mouse.y)
            root.svc.requestMenu(g.x, g.y)
        }
    }
}
