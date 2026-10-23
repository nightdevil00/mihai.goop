import QtQuick
import qs.Commons as Commons

Rectangle {
    id: root

    property string text: ""
    property bool primary: false

    signal clicked()

    implicitWidth: label.implicitWidth + 24
    implicitHeight: 30
    radius: 8
    color: primary
        ? (area.containsMouse ? "#ff5a84" : "#ff3d6e")
        : (area.containsMouse ? Commons.Color.menu.selectedBackground : Commons.Color.menu.background)
    opacity: enabled ? 1 : 0.4

    Text {

        textFormat: Text.PlainText
        id: label
        anchors.centerIn: parent
        text: root.text
        color: Commons.Color.menu.text
        font.pixelSize: 13
    }

    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        onClicked: root.clicked()
    }
}
