import QtQuick
import qs.Commons

// A labeled single-line text box for the settings window.
Column {
    id: root

    property string label: ""
    property alias text: input.text
    property bool secret: false

    signal edited(string text)

    spacing: 4
    width: 320

    Text {

        textFormat: Text.PlainText
        text: root.label
        color: Commons.Color.muted
        font.pixelSize: 12
    }

    Rectangle {
        width: root.width
        height: 32
        radius: 8
        color: Commons.Color.menu.background
        border.width: 1
        border.color: input.activeFocus ? Commons.Color.accent : Commons.Color.menu.border

        TextInput {
            id: input
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            verticalAlignment: TextInput.AlignVCenter
            color: Commons.Color.menu.text
            font.pixelSize: 13
            clip: true
            echoMode: root.secret ? TextInput.Password : TextInput.Normal
            onTextEdited: root.edited(text)
        }
    }
}
