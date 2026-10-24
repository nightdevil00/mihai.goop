import QtQuick
import qs.Commons

// Shared state for goop: whether the creature is "at home" in the bar,
// plus a request to open the right-click menu from the bar icon.
Item {
    id: root

    property bool homeMode: false
    property bool menuRequested: false
    property real menuX: 0
    property real menuY: 0

    function goHome() { homeMode = true }
    function summon() { homeMode = false }
    function requestMenu(x, y) {
        menuX = x;
        menuY = y;
        menuRequested = true;
    }
}
