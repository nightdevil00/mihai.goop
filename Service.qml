import QtQuick
import qs.Commons

// Shared state for goop: whether the creature is "at home" in the bar.
Item {
    id: root

    property bool homeMode: false

    function goHome() { homeMode = true }
    function summon() { homeMode = false }
}
