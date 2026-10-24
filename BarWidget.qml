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
            if (bar && bar.shell && typeof bar.shell.serviceFor === "function")
                svc = bar.shell.serviceFor(moduleName)
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
            if (buttonCode === Qt.LeftButton && root.svc) root.svc.summon()
        }

        Text {
            id: content
            anchors.centerIn: parent
            text: "😈"
            font.pixelSize: Math.round(Style.bar.iconCanvas * 1.1)
        }
    }
}
