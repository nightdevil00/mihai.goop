import QtQuick
import qs.Commons as Commons

// The black tab the creature sits in. It is the notch at the top of the screen
// and the tab on a docked window's top border. Expanded, it becomes the message field.
Rectangle {
    id: root

    property real centerX: 0
    property real topY: 0
    property real collapsedWidth: 210
    property bool expanded: false
    property alias text: input.text
    readonly property real expandedWidth: 340

    signal submitted(string text)
    signal cancelled()

    x: centerX - width / 2
    y: topY
    width: expanded ? expandedWidth : collapsedWidth
    height: 36
    color: Commons.Color.background
    bottomLeftRadius: 18
    bottomRightRadius: 18

    Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutBack; easing.overshoot: 1.1 } }

    onExpandedChanged: {
        if (expanded) {
            input.text = "";
            input.forceActiveFocus();
        }
    }

    TextInput {
        id: input
        anchors.fill: parent
        anchors.leftMargin: 16
        anchors.rightMargin: 16
        verticalAlignment: TextInput.AlignVCenter
        color: Commons.Color.foreground
        font.pixelSize: 14
        clip: true
        opacity: root.expanded ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 180 } }

        Keys.onReturnPressed: {
            if (text.trim() !== "")
                root.submitted(text.trim());
        }
        Keys.onEnterPressed: Keys.onReturnPressed
        Keys.onEscapePressed: root.cancelled()

        Text {

            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: "Message…"
            color: Commons.Color.muted
            font: input.font
            visible: input.text === ""
        }
    }
}
