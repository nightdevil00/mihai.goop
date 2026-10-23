import QtQuick

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
        color: "#9a9aa6"
        font.pixelSize: 12
    }

    Rectangle {
        width: root.width
        height: 32
        radius: 8
        color: "#1c1c21"
        border.width: 1
        border.color: input.activeFocus ? "#ff3d6e" : "#2e2e36"

        TextInput {
            id: input
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            verticalAlignment: TextInput.AlignVCenter
            color: "#ffffff"
            font.pixelSize: 13
            clip: true
            echoMode: root.secret ? TextInput.Password : TextInput.Normal
            onTextEdited: root.edited(text)
        }
    }
}
