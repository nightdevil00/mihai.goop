import QtQuick
import QtQuick.Shapes
import qs.Commons as Commons

// One view of the creature. The shell owns its position and mood and gives every
// screen the same values, so it can sit across monitors. It follows the pointer through
// a spring, so it lags behind while moving and stretches.
Item {
    id: root

    property real pullX: 0
    property real pullY: 0
    property string mood: "rest"
    property bool dragging: false
    property real breath: 0
    // The screen's position in the global layout, to report pointer positions globally.
    property real originX: 0
    property real originY: 0

    readonly property real targetX: pullX
    readonly property real targetY: pullY
    readonly property real radius: 26
    readonly property real kappa: 0.5523
    readonly property real centerX: x + width / 2
    readonly property real centerY: y + height / 2
    readonly property real stretch: Math.min(Math.hypot(targetX - centerX, targetY - centerY) / 120, 1) * 0.7
    readonly property real angle: Math.atan2(targetY - centerY, targetX - centerX) * 180 / Math.PI
    readonly property real rx: radius * (1 + stretch * 0.6) * (1 + 0.025 * breath)
    readonly property real ry: radius * (1 - stretch * 0.3) * (1 - 0.02 * breath)
    readonly property bool active: dragging || mood !== "rest"
    readonly property color bodyColor: active ? "#ff3d6e" : Commons.Color.muted
    readonly property real gazeX: Math.max(-1, Math.min(1, (targetX - centerX) / 200)) * 4

    signal pressed(real pointX, real pointY)
    signal moved(real pointX, real pointY)
    signal released(real pointX, real pointY, bool dragged)
    signal contextRequested(real pointX, real pointY)

    width: 90
    height: 90
    x: targetX - width / 2
    y: targetY - height / 2

    // Spring gives the elastic stretch while dragging.
    Behavior on x { SpringAnimation { spring: 8; damping: 0.6; mass: 0.4 } }
    Behavior on y { SpringAnimation { spring: 8; damping: 0.6; mass: 0.4 } }


    SequentialAnimation on breath {
        loops: Animation.Infinite
        running: !root.dragging
        NumberAnimation { to: 1; duration: 1400; easing.type: Easing.InOutSine }
        NumberAnimation { to: 0; duration: 1400; easing.type: Easing.InOutSine }
    }

    // Ears sit behind the body and turn with it.
    Item {
        anchors.centerIn: parent
        width: 90
        height: 90
        rotation: root.angle
        transformOrigin: Item.Center

        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                fillColor: root.bodyColor
                strokeColor: "transparent"
                startX: 45 - root.rx * 0.8; startY: 45 - root.ry * 0.45
                PathLine { x: 45 - root.rx * 0.9; y: 45 - root.ry * 1.35 }
                PathLine { x: 45 - root.rx * 0.2; y: 45 - root.ry * 0.8 }
            }
            ShapePath {
                fillColor: root.bodyColor
                strokeColor: "transparent"
                startX: 45 + root.rx * 0.8; startY: 45 - root.ry * 0.45
                PathLine { x: 45 + root.rx * 0.9; y: 45 - root.ry * 1.35 }
                PathLine { x: 45 + root.rx * 0.2; y: 45 - root.ry * 0.8 }
            }
        }

        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                fillColor: root.bodyColor
                strokeColor: "transparent"

                startX: 45 + root.rx; startY: 45
                PathCubic {
                    x: 45; y: 45 + root.ry
                    control1X: 45 + root.rx; control1Y: 45 + root.kappa * root.ry
                    control2X: 45 + root.kappa * root.rx; control2Y: 45 + root.ry
                }
                PathCubic {
                    x: 45 - root.rx; y: 45
                    control1X: 45 - root.kappa * root.rx; control1Y: 45 + root.ry
                    control2X: 45 - root.rx; control2Y: 45 + root.kappa * root.ry
                }
                PathCubic {
                    x: 45; y: 45 - root.ry
                    control1X: 45 - root.rx; control1Y: 45 - root.kappa * root.ry
                    control2X: 45 - root.kappa * root.rx; control2Y: 45 - root.ry
                }
                PathCubic {
                    x: 45 + root.rx; y: 45
                    control1X: 45 + root.kappa * root.rx; control1Y: 45 - root.ry
                    control2X: 45 + root.rx; control2Y: 45 - root.kappa * root.ry
                }
            }
        }
    }

    // Face stays upright and looks toward the pull direction.
    Item {
        id: face
        anchors.centerIn: parent
        width: 90
        height: 90

        readonly property real eyeHeight: root.mood === "happy" ? 5 : 16
        readonly property real eyeLift: root.mood === "thinking" ? -3 : 0

        Rectangle {
            width: 7; height: face.eyeHeight; radius: 3.5
            color: Commons.Color.foreground
            x: 45 - 12 - 3.5 + root.gazeX
            y: 45 - 2 - face.eyeHeight / 2 + face.eyeLift
            Behavior on height { NumberAnimation { duration: 180; easing.type: Easing.OutBack } }
            Behavior on y { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        }
        Rectangle {
            width: 7; height: face.eyeHeight; radius: 3.5
            color: Commons.Color.foreground
            x: 45 + 12 - 3.5 + root.gazeX
            y: 45 - 2 - face.eyeHeight / 2 + face.eyeLift
            Behavior on height { NumberAnimation { duration: 180; easing.type: Easing.OutBack } }
            Behavior on y { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        }
    }

    // Hearts drift up while happy.
    Repeater {
        model: 3
        Text {
            textFormat: Text.PlainText
            id: heart
            required property int index
            text: "♥"
            color: "#ff8fab"
            font.pixelSize: 11 + index * 2
            x: 56 + index * 9
            y: 4
            opacity: 0
            visible: root.mood === "happy"
            SequentialAnimation on opacity {
                running: root.mood === "happy"
                loops: Animation.Infinite
                PauseAnimation { duration: heart.index * 350 }
                NumberAnimation { from: 0; to: 1; duration: 200 }
                NumberAnimation { to: 0; duration: 900 }
                PauseAnimation { duration: 800 - heart.index * 350 }
            }
            SequentialAnimation on y {
                running: root.mood === "happy"
                loops: Animation.Infinite
                PauseAnimation { duration: heart.index * 350 }
                NumberAnimation { from: 4; to: -14; duration: 1100; easing.type: Easing.OutCubic }
                PauseAnimation { duration: 800 - heart.index * 350 }
                NumberAnimation { to: 4; duration: 0 }
            }
        }
    }

    // Status dot and bouncing marks, shown while the backend works.
    Rectangle {
        x: 74; y: 14
        width: 8; height: 8; radius: 4
        color: Commons.Color.accent
        opacity: root.mood === "thinking" ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 200 } }
    }
    Repeater {
        model: 3
        Rectangle {
            required property int index
            x: 4 + index * 7
            y: 8
            width: 4; height: 4; radius: 2
            color: Commons.Color.foreground
            opacity: root.mood === "thinking" ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 200 } }
            SequentialAnimation on y {
                running: root.mood === "thinking"
                loops: Animation.Infinite
                PauseAnimation { duration: index * 120 }
                NumberAnimation { to: 2; duration: 220; easing.type: Easing.OutQuad }
                NumberAnimation { to: 8; duration: 220; easing.type: Easing.InQuad }
                PauseAnimation { duration: 360 - index * 120 }
            }
        }
    }

    MouseArea {
        id: pointer
        anchors.fill: parent
        preventStealing: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        property real pressX: 0
        property real pressY: 0
        property bool dragged: false

        function globalPoint(mouse) {
            const p = mapToItem(root.parent, mouse.x, mouse.y);
            return { x: root.originX + p.x, y: root.originY + p.y };
        }

        onPressed: (mouse) => {
            if (mouse.button === Qt.RightButton)
                return;
            const g = pointer.globalPoint(mouse);
            pointer.pressX = g.x;
            pointer.pressY = g.y;
            pointer.dragged = false;
            root.pressed(g.x, g.y);
        }
        onPositionChanged: (mouse) => {
            if (!root.dragging)
                return;
            const g = pointer.globalPoint(mouse);
            if (Math.hypot(g.x - pointer.pressX, g.y - pointer.pressY) > 6)
                pointer.dragged = true;
            root.moved(g.x, g.y);
        }
        onReleased: (mouse) => {
            if (mouse.button === Qt.RightButton)
                return;
            const g = pointer.globalPoint(mouse);
            root.released(g.x, g.y, pointer.dragged);
        }
        onClicked: (mouse) => {
            if (mouse.button === Qt.RightButton) {
                const g = pointer.globalPoint(mouse);
                root.contextRequested(g.x, g.y);
            }
        }
    }
}
