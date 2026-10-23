import Quickshell
import Quickshell.Wayland
import QtQuick
import QtQuick.Controls
import qs.Commons

// goop, the Omarchy shell panel: a creature you can drop anywhere on the desktop, on
// any monitor. Click it to type a request; the request runs for the window under it.
// Its plugin manifest is manifest.json.
//
// The creature's position and mood live here, in global layout coordinates, so it
// can sit across monitors. Each monitor has one overlay window that draws the creature
// wherever it overlaps that monitor, and the prompt and bubble on the monitor it is on.
Scope {
    id: root

    // Global position of the creature's centre. It starts at the top of the first monitor.
    property real posGX: Quickshell.screens.length ? Quickshell.screens[0].x + Quickshell.screens[0].width / 2 : 0
    property real posGY: Quickshell.screens.length ? Quickshell.screens[0].y + 70 : 0
    // When docked, the creature is attached to a window and follows it; otherwise it floats.
    readonly property bool dockMode: agents.config.dockMode === "dock"
    onDockModeChanged: {
        if (!dockMode && dock.docked) {
            posGX = dock.centerX !== 0 ? dock.centerX : posGX;
            posGY = dock.topY !== 0 ? dock.topY + 20 : posGY;
            dock.detach();
        }
    }
    readonly property bool attached: dockMode && dock.docked && dock.shown
    readonly property real displayGX: attached ? dock.centerX : posGX
    readonly property real displayGY: attached ? dock.topY + 20 : posGY
    readonly property var creatureScreen: screenAt(displayGX, displayGY)
    property real offsetGX: 0
    property real offsetGY: 0

    property string mood: "rest"
    property bool dragging: false
    property bool promptOpen: false

    readonly property color bodyColor: (dragging || mood !== "rest") ? Commons.Color.accent : Commons.Color.muted

    // What the bubble under the creature shows: "", "reply", "error", "proposal", "applied", "busy".
    property string bubbleState: ""
    property string reply: ""
    property string proposal: ""
    property string pendingPrompt: ""
    property string pendingAskText: ""
    // The terminal a request came from, and the command the agent proposed for it.
    property string terminalAddress: ""
    property string terminalClass: ""
    property string command: ""

    property bool menuOpen: false

    Shortcut {
        sequence: "Escape"
        context: Qt.ApplicationShortcut
        onActivated: if (root.promptOpen) root.promptOpen = false
    }
    property real menuGX: 0
    property real menuGY: 0
    property var menuScreen: null

    GoopAgents {
        id: agents

        onContextReady: (tag, contextFile) => {
            if (tag === "reply")
                agents.ask(root.agentId(), root.pendingPrompt, contextFile, "reply");
        }
        onReplied: (tag, text, proposalPath) => {
            if (tag !== "reply")
                return;
            const shellCommand = root.terminalAddress !== "" && agents.config.terminal_mode !== "agent" ? root.commandIn(text) : "";
            if (shellCommand !== "") {
                root.command = shellCommand;
                root.show("command", text);
                root.celebrate();
                return;
            }
            root.proposal = proposalPath;
            if (proposalPath && agents.config.auto_apply) {
                root.show("busy", "Applying…");
                agents.applyProposal(proposalPath, "apply");
                root.celebrate();
                return;
            }
            root.show(proposalPath ? "proposal" : "reply", text);
            root.celebrate();
        }
        onApplied: (tag, target) => {
            if (tag === "apply")
                root.show("applied", "Applied to " + target + ". Your editor should reload it. The original is backed up, so you can undo.");
        }
        onTyped: (tag, command) => {
            if (tag === "type") {
                root.show("reply", "Typed in the terminal: " + command);
                root.mood = "rest";
            }
        }
        onReverted: (tag, target) => {
            if (tag === "revert")
                root.show("reply", "Undone. " + target + " is back to how it was.");
        }
        onFailed: (tag, message) => {
            if (tag === "save" || tag === "test")
                return;
            root.show("error", message);
            if (tag !== "")
                root.mood = "rest";
        }
    }

    GoopSettings {
        id: settings
        agents: agents
    }

    GoopDock {
        id: dock
    }

    Connections {
        target: dock
        function onActiveChanged() {
            if (root.pendingAskText !== "" && dock.activeClient && dock.activeClient.cls) {
                const text = root.pendingAskText;
                root.pendingAskText = "";
                root.doAsk(dock.activeClient, text);
            }
        }
    }

    // Remember where the docked window was, so detaching keeps the creature in place.
    property real lastDockGX: 0
    property real lastDockGY: 0
    onDisplayGXChanged: if (attached) { lastDockGX = displayGX; lastDockGY = displayGY; }

    Connections {
        target: dock
        function onDockedChanged() {
            if (!dock.docked && root.lastDockGX !== 0 && !root.dragging) {
                root.posGX = root.lastDockGX;
                root.posGY = root.lastDockGY;
            }
        }
    }

    Timer {
        id: happyTimer
        interval: 1400
        onTriggered: if (root.mood === "happy") root.mood = "rest"
    }

    Timer {
        id: menuTimer
        interval: 6000
        onTriggered: root.menuOpen = false
    }

    function screenAt(x, y) {
        for (const screen of Quickshell.screens)
            if (x >= screen.x && x < screen.x + screen.width && y >= screen.y && y < screen.y + screen.height)
                return screen;
        return Quickshell.screens.length ? Quickshell.screens[0] : null;
    }

    function agentId() {
        if (agents.config.active)
            return agents.config.active;
        return agents.config.agents.length ? agents.config.agents[0].id : "";
    }

    function show(state, text) {
        bubbleState = state;
        reply = text;
    }

    // The first fenced shell block in a reply, or "" if there is none.
    function commandIn(text) {
        const match = /```(?:sh|bash|shell|zsh)?\n([\s\S]*?)```/.exec(text);
        return match ? match[1].trim() : "";
    }

    function celebrate() {
        mood = "happy";
        happyTimer.restart();
    }

    function openMenu(x, y) {
        menuGX = x;
        menuGY = y;
        menuScreen = screenAt(x, y);
        menuOpen = true;
        menuTimer.restart();
    }

    function beginDrag(x, y) {
        // If currently docked, undock first so it can be moved freely.
        if (attached) {
            posGX = lastDockGX !== 0 ? lastDockGX : dock.centerX;
            posGY = lastDockGY !== 0 ? lastDockGY : dock.topY + 20;
            dock.detach();
        }
        offsetGX = x - posGX;
        offsetGY = y - posGY;
        dragging = true;
        happyTimer.stop();
        mood = "rest";
        promptOpen = false;
        dock.refresh();
    }

    function moveDrag(x, y) {
        posGX = x - offsetGX;
        posGY = y - offsetGY;
    }

    function endDrag(x, y, dragged) {
        dragging = false;
        dock.refresh();
        if (!dragged) {
            // A click, not a drag: ask for a request.
            mood = "prompting";
            promptOpen = true;
            return;
        }
        const hit = dock.clientAt(posGX, posGY);
        if (hit && dockMode) {
            dock.attach(hit.address);
            // Keep pos in sync so undocking later stays in place.
            posGX = hit.x + hit.width / 2;
            posGY = hit.y + 20;
        }
        celebrate();
    }

    function askAgent(text) {
        if (agentId() === "") {
            show("error", "No agent yet. Right-click goop, then Settings, to add one.");
            mood = "rest";
            return;
        }
        // Prefer the focused window; refresh first so activeClient is current.
        pendingAskText = text;
        mood = "thinking";
        if (dock.activeClient && dock.activeClient.cls) {
            pendingAskText = "";
            doAsk(dock.activeClient, text);
        } else {
            dock.refresh();
            // activeChanged will trigger doAsk via the connection below
        }
    }

    function doAsk(target, text) {
        if (!target || !target.cls) {
            target = dock.clientAt(displayGX, displayGY);
        }
        if (!target) {
            show("error", "No window is focused. Focus a window, or move goop over one.");
            mood = "rest";
            return;
        }
        // Over a terminal, "run <command>" or "!<command>" types the command into it and presses Enter, with no agent.
        // Only real terminal emulators can receive typed keystrokes. Nautilus and editors
        // are handled through their own context (run in folder / apply file change).
        const terminal = ["foot", "alacritty", "kitty", "com.mitchellh.ghostty", "org.wezfurlong.wezterm"].indexOf(target.cls.toLowerCase()) >= 0;
        const typed = text.startsWith("!") ? text.slice(1) : (terminal && /^run\s+/i.test(text) ? text.replace(/^run\s+/i, "") : null);
        if (typed !== null) {
            agents.typeInto(target.address, target.cls, typed.trim(), "type");
            return;
        }
        pendingPrompt = text;
        proposal = "";
        command = "";
        terminalAddress = terminal ? target.address : "";
        terminalClass = target.cls;
        agents.captureContext(target.title, target.cls, target.pid, text, "reply");
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: win

            required property var modelData

            // The creature's prompt, bubble, and menu are drawn on the monitor it is on.
            readonly property bool here: root.creatureScreen === modelData

            screen: modelData
            anchors { top: true; bottom: true; left: true; right: true }
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "goop"
            WlrLayershell.keyboardFocus: (root.promptOpen && here) ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

            // Only the things the user can click take input; everything else reaches the windows below.
            mask: Region {
                Region { item: blobHit }
                Region { item: promptHit }
                Region { item: bubbleHit }
                Region { item: menuHit }
            }

            Item {
                id: stage
                anchors.fill: parent

                // The creature's centre, in this screen's coordinates.
                readonly property real px: root.displayGX - win.modelData.x
                readonly property real py: root.displayGY - win.modelData.y

                GoopBlob {
                    id: blob
                    originX: win.modelData.x
                    originY: win.modelData.y
                    pullX: stage.px
                    pullY: stage.py
                    dragging: root.dragging
                    mood: root.mood

                    onPressed: (x, y) => root.beginDrag(x, y)
                    onMoved: (x, y) => root.moveDrag(x, y)
                    onReleased: (x, y, dragged) => root.endDrag(x, y, dragged)
                    onContextRequested: (x, y) => root.openMenu(x, y)
                }

                // Click targets for the mask. Each one has no size while its element is hidden.
                Item {
                    id: blobHit
                    x: blob.x
                    y: blob.y
                    width: blob.width
                    height: blob.height
                }

                GoopTab {
                    id: prompt
                    collapsedWidth: 120
                    centerX: stage.px
                    topY: stage.py + 52
                    expanded: root.promptOpen
                    visible: root.promptOpen && win.here

                    onSubmitted: (text) => {
                        root.promptOpen = false;
                        root.askAgent(text);
                    }
                    onCancelled: {
                        root.promptOpen = false;
                        root.mood = "rest";
                    }
                }

                Item {
                    id: promptHit
                    x: prompt.x
                    y: prompt.y
                    width: prompt.visible ? prompt.width : 0
                    height: prompt.height
                }

                Rectangle {
                    id: bubble
                    visible: root.bubbleState !== "" && win.here
                    x: stage.px - width / 2
                    y: stage.py + 96
                    width: 340
                    height: bubbleColumn.implicitHeight + 20
                    radius: 12
                    color: Commons.Color.popups.background
                    border.width: 1
                    border.color: root.bubbleState === "error" ? Commons.Color.urgent : Commons.Color.popups.border

                    Column {
                        id: bubbleColumn
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 10
                        spacing: 10

                        Text {
                            textFormat: Text.PlainText
                            width: parent.width
                            text: root.reply
                            color: root.bubbleState === "error" ? Commons.Color.urgent : Commons.Color.popups.text
                            font.pixelSize: 13
                            wrapMode: Text.Wrap
                        }

                        Row {
                            spacing: 8

                            GoopButton {
                                text: "Type"
                                primary: true
                                visible: root.bubbleState === "command"
                                onClicked: {
                                    root.show("busy", "Typing…");
                                    agents.typeInto(root.terminalAddress, root.terminalClass, root.command, "type");
                                }
                            }
                            GoopButton {
                                text: "Apply"
                                primary: true
                                visible: root.bubbleState === "proposal"
                                onClicked: {
                                    root.show("busy", "Applying…");
                                    agents.applyProposal(root.proposal, "apply");
                                }
                            }
                            GoopButton {
                                text: "Discard"
                                visible: root.bubbleState === "proposal" || root.bubbleState === "command"
                                onClicked: {
                                    root.bubbleState = "";
                                    root.proposal = "";
                                    root.command = "";
                                    root.terminalAddress = "";
                                    root.mood = "rest";
                                }
                            }
                            GoopButton {
                                text: "Undo"
                                visible: root.bubbleState === "applied"
                                onClicked: agents.revertProposal(root.proposal, "revert")
                            }
                            GoopButton {
                                text: "Close"
                                visible: root.bubbleState === "reply" || root.bubbleState === "error" || root.bubbleState === "applied"
                                onClicked: {
                                    root.bubbleState = "";
                                    root.mood = "rest";
                                }
                            }
                        }
                    }
                }

                Item {
                    id: bubbleHit
                    x: bubble.x
                    y: bubble.y
                    width: bubble.visible ? bubble.width : 0
                    height: bubble.visible ? bubble.height : 0
                }

                Rectangle {
                    id: menu
                    visible: root.menuOpen && root.menuScreen === win.modelData
                    x: root.menuGX - win.modelData.x
                    y: root.menuGY - win.modelData.y
                    width: 150
                    height: 74
                    radius: 10
                    color: Commons.Color.menu.background
                    border.width: 1
                    border.color: Commons.Color.menu.border

                    Column {
                        anchors.fill: parent
                        anchors.margins: 6

                        Repeater {
                            model: [
                                { label: "Settings…", action: "settings" },
                                { label: "Quit goop", action: "quit" }
                            ]
                            delegate: Rectangle {
                                required property var modelData
                                width: menu.width - 12
                                height: 30
                                radius: 6
                                color: itemArea.containsMouse ? Commons.Color.menu.selectedBackground : "transparent"

                                Text {
                                    textFormat: Text.PlainText
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.left: parent.left
                                    anchors.leftMargin: 10
                                    text: modelData.label
                                    color: Commons.Color.menu.text
                                    font.pixelSize: 13
                                }

                                MouseArea {
                                    id: itemArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: {
                                        root.menuOpen = false;
                                        if (modelData.action === "settings")
                                            settings.visible = true;
                                        else
                                            Qt.quit();
                                    }
                                }
                            }
                        }
                    }
                }

                Item {
                    id: menuHit
                    x: menu.x
                    y: menu.y
                    width: menu.visible ? menu.width : 0
                    height: menu.visible ? menu.height : 0
                }
            }
        }
    }
}
