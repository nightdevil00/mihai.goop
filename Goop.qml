import Quickshell
import Quickshell.Wayland
import QtQuick
import QtQuick.Controls
import qs.Commons as Commons

// goop, the Omarchy shell panel: a creature you can drop anywhere on the desktop, on
// any monitor. Click it to type a request; the request runs for the window under it.
// Its plugin manifest is manifest.json.
//
// The creature's position and mood live here, in global layout coordinates, so it
// can sit across monitors. Each monitor has one overlay window that draws the creature
// wherever it overlaps that monitor, and the prompt and bubble on the monitor it is on.
Scope {
    id: root

    property var service: null

    Connections {
        target: root.service
        enabled: root.service !== null
        function onMenuRequestedChanged() {
            if (root.service && root.service.menuRequested) {
                root.openMenu(root.service.menuX, root.service.menuY);
                root.service.menuRequested = false;
            }
        }
    }

    // Start on the leftmost monitor so the creature is visible.
    property real posGX: {
        if (!Quickshell.screens.length) return 0;
        let s = Quickshell.screens[0];
        for (const sc of Quickshell.screens) if (sc.x < s.x) s = sc;
        return s.x + s.width / 2;
    }
    property real posGY: {
        if (!Quickshell.screens.length) return 0;
        let s = Quickshell.screens[0];
        for (const sc of Quickshell.screens) if (sc.x < s.x) s = sc;
        return s.y + 70;
    }
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

    // The creature keeps its signature pink when active; only the idle body follows the theme.
    readonly property color bodyColor: (dragging || mood !== "rest") ? "#ff3d6e" : Commons.Color.muted

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
        onActivated: {
            if (root.promptOpen) root.promptOpen = false;
            if (root.menuOpen) root.menuOpen = false;
        }
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
        onOpened: (tag, app) => {
            if (tag === "open") {
                root.show("reply", "Opened " + (app || "application"));
                autoCloseTimer.restart();
                root.mood = "rest";
            }
        }
        onMediaChanged: (tag, action) => {
            root.show("reply", "Media: " + action);
            autoCloseTimer.restart();
            root.mood = "rest";
        }
        onTyped: (tag, command) => {
            if (tag === "type") {
                if (/^(new_tab|new_window|close_tab|reload|back|forward|navigate|switch_tab|close_tab_named|search)(:|$)/.test(command)) {
                    root.show("reply", "Browser: " + command);
                    autoCloseTimer.restart();
                } else
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
        pluginDir: decodeURIComponent(Qt.resolvedUrl(".").toString().replace("file://", ""))
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
        id: autoCloseTimer
        interval: 1000
        onTriggered: {
            root.bubbleState = "";
            root.mood = "rest";
        }
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

    // Common command names goop can type straight into a terminal without asking an agent.
    readonly property var usualCommands: ["ls", "ll", "la", "pwd", "clear", "cls", "cd", "mkdir", "rmdir", "rm", "cp", "mv", "touch", "cat", "less", "more", "head", "tail", "grep", "find", "locate", "which", "whereis", "echo", "printf", "wc", "sort", "uniq", "diff", "patch", "tar", "zip", "unzip", "gzip", "gunzip", "chmod", "chown", "ln", "du", "df", "free", "top", "htop", "btop", "ps", "kill", "killall", "pkill", "jobs", "bg", "fg", "nohup", "time", "date", "whoami", "id", "uname", "hostname", "uptime", "history", "alias", "export", "source", "exit", "logout", "man", "tldr", "help", "sudo", "su", "apt", "pacman", "yay", "paru", "dnf", "brew", "npm", "npx", "pnpm", "yarn", "bun", "pip", "pip3", "poetry", "uv", "cargo", "rustc", "rustup", "go", "gofmt", "java", "javac", "mvn", "gradle", "node", "deno", "python", "python3", "make", "cmake", "ninja", "meson", "gcc", "g++", "clang", "clang++", "swift", "swiftc", "xcodebuild", "git", "gh", "docker", "podman", "kubectl", "helm", "terraform", "ansible", "ssh", "scp", "rsync", "curl", "wget", "ping", "traceroute", "ip", "ifconfig", "ss", "netstat", "systemctl", "journalctl", "loginctl", "hyprctl", "omarchy", "code", "zed", "nvim", "vim", "nano", "emacs", "wtype", "tree", "bat", "eza", "fd", "rg", "fzf", "zoxide", "lazygit", "lazydocker", "btop", "fastfetch", "neofetch"]

    // Turn a terminal request into a shell command goop can type directly, or null to ask the agent.
    function terminalCommand(text) {
        const t = (text || "").trim();
        if (!t)
            return null;
        // Natural-language shortcuts for the commands people ask for most.
        if (/^(git\s+)?status$/i.test(t))
            return "git status";
        if (/^(show\s+)?(git\s+)?diff$/i.test(t))
            return "git diff";
        if (/^(git\s+)?log$/i.test(t) || /^commits?$/i.test(t) || /^recent\s+commits?$/i.test(t) || /^history$/i.test(t))
            return "git log --oneline -10";
        if (/^(git\s+)?pull$/i.test(t))
            return "git pull";
        if (/^(git\s+)?push$/i.test(t))
            return "git push";
        if (/^(git\s+)?fetch$/i.test(t))
            return "git fetch";
        if (/^branches?$/i.test(t))
            return "git branch -a";
        if (/^stash$/i.test(t))
            return "git stash";
        if (/^(stage|add)\s+all$/i.test(t))
            return "git add -A";
        if (/^clear$/i.test(t) || /^cls$/i.test(t))
            return "clear";
        if (/^pwd$/i.test(t) || /^where\s+am\s+i\??$/i.test(t) || /^current\s+(dir|directory)$/i.test(t))
            return "pwd";
        if (/^ls$/i.test(t) || /^list(\s+files)?$/i.test(t))
            return "ls -la";
        // Looks like a question or a natural-language request: let the agent handle it.
        if (/[?]/.test(t))
            return null;
        if (/\b(please|explain|why|how|what|tell|describe|help|can you|could you|i want|i need|fix|implement|refactor|optimize|bug|error|summarize|review)\b/i.test(t))
            return null;
        const first = t.split(/\s+/)[0].toLowerCase().replace(/^.*\//, "");
        if (root.usualCommands.indexOf(first) >= 0)
            return t;
        return null;
    }

    // Extract the text to look for when searching inside the page.
    function searchArg(text) {
        let s = (text || "").trim();
        // Drop a leading verb.
        s = s.replace(/^(search\s+for|search|find|locate|look\s+for|click\s+on|click|open|go\s+to|visit)\s+/i, "");
        // Drop a trailing "and click ..." clause.
        s = s.replace(/\s+and\s+click.*$/i, "");
        // Drop trailing filler words.
        s = s.replace(/\s+(profile\s+page|profile|page|link|on\s+this\s+page|in\s+this\s+page|that\s+link|this\s+link)$/i, "");
        // Drop a possessive 's so "DHH's profile" becomes "DHH".
        s = s.replace(/'s\b/g, "");
        s = s.replace(/^["']|["']$/g, "").trim();
        return s;
    }

    // Parse a browser-control request. Returns {action, arg} or null.
    function browserCommand(text) {
        const t = (text || "").trim();
        if (!t)
            return null;
        let m;
        if (/^(open|create|new)\s+(a\s+)?(new\s+)?tab$/i.test(t))
            return { action: "new_tab", arg: "" };
        if (/^(open|create|new)\s+(a\s+)?(new\s+)?window$/i.test(t))
            return { action: "new_window", arg: "" };
        if (/^(reload|refresh)(\s+(page|tab))?$/i.test(t))
            return { action: "reload", arg: "" };
        if (/^(back|go\s+back)$/i.test(t))
            return { action: "back", arg: "" };
        if (/^(forward|go\s+forward)$/i.test(t))
            return { action: "forward", arg: "" };
        if (/^close\s+(this|the)?\s*tab$/i.test(t))
            return { action: "close_tab", arg: "" };
        m = t.match(/^close\s+tab\s+(called|named)\s+(.+)$/i);
        if (m)
            return { action: "close_tab_named", arg: m[2] };
        m = t.match(/^close\s+(.+?)\s+tab$/i);
        if (m && !/^(this|the)$/i.test(m[1]))
            return { action: "close_tab_named", arg: m[1] };
        m = t.match(/^(switch|go)\s+to\s+tab\s+(.+)$/i) || t.match(/^focus\s+tab\s+(.+)$/i);
        if (m)
            return { action: "switch_tab", arg: m[1] };
        // Search for text inside the current page and open the matching link
        // (browser quick find). Triggered by an explicit search/find/click request,
        // or by requests that mention a profile or link. Skip this when the request
        // already contains a URL or host, so navigation still works.
        const hasUrlOrHost = /(https?:\/\/\S+)/i.test(t) ||
            /\b[a-z0-9][a-z0-9.-]*\.[a-z]{2,}(?:\/\S*)?\b/i.test(t);
        if (!hasUrlOrHost && /\b(search|find|locate|click|profile|link)\b/i.test(t)) {
            const sa = searchArg(t);
            if (sa)
                return { action: "search", arg: sa };
        }
        // Typo-tolerant navigation: "go to", "got to", "goto", "navigate", "open", "visit".
        m = t.match(/^(g(?:oto|ot|o)|navigate(?:\s+to)?|open|visit)\s+(.+)$/i);
        if (m) {
            // Drop a stray leading "to" left by typos like "got to URL".
            const arg = m[2].trim().replace(/^to\s+/i, "");
            return { action: "navigate", arg: arg };
        }
        // If the request contains a URL anywhere, navigate to it.
        m = t.match(/(https?:\/\/\S+)/i);
        if (m)
            return { action: "navigate", arg: m[1] };
        // A bare host like "x.com" or "example.com/path".
        m = t.match(/\b([a-z0-9][a-z0-9.-]*\.[a-z]{2,}(?:\/\S*)?)\b/i);
        if (m && !/\s/.test(m[1]))
            return { action: "navigate", arg: m[1] };
        return null;
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
        // Media controls, handled directly without an agent.
        const mediaMatch = text.trim().match(/^(?:(media|media player)\s+)?(play|pause|resume|stop|play\s*\/\s*pause|play\s+pause|toggle)$/i);
        if (mediaMatch) {
            let verb = mediaMatch[2].toLowerCase().replace(/\s+/g, "");
            if (verb === "resume")
                verb = "play";
            if (verb === "stop")
                verb = "pause";
            if (verb === "playpause" || verb === "play/pause" || verb === "toggle")
                verb = "playPause";
            root.show("busy", "Controlling media\u2026");
            root.mood = "thinking";
            agents.mediaControl(verb, "media");
            return;
        }
        // Open an application by name without an agent round-trip.
        const appMatch = text.match(/^(open|launch|start)\s+(.+)$/i);
        if (appMatch) {
            const arg = appMatch[2].trim();
            const lowArg = arg.toLowerCase();
            const browserWords = ["tab", "new tab", "window", "new window", "page", "this tab", "the tab"];
            const naturalWords = /\b(the|this|that|these|those|a|an|my|your|file|folder|document|project|it|page|url|profile|link|click|search|find)\b/i;
            const wordCount = arg.split(/\s+/).length;
            if (browserWords.indexOf(lowArg) < 0 && wordCount <= 3 && !naturalWords.test(arg) && !/^(https?:\/\/|www\.)/i.test(arg) && !/\.[a-z]{2,}(\/|$)/i.test(arg)) {
                root.show("busy", "Opening " + arg + "…");
                root.mood = "thinking";
                agents.openApp(arg, "open");
                return;
            }
        }
        if (!target || !target.cls) {
            target = dock.clientAt(displayGX, displayGY);
        }
        if (!target) {
            show("error", "No window is focused. Focus a window, or move goop over one.");
            mood = "rest";
            return;
        }
        const cls = target.cls.toLowerCase();
        const browser = ["google-chrome", "google-chrome-stable", "chromium", "chromium-browser",
            "brave-browser", "brave", "microsoft-edge", "microsoft-edge-stable",
            "firefox", "firefox-esr", "zen-browser", "zen", "vivaldi", "vivaldi-stable",
            "opera"].indexOf(cls) >= 0;
        // Browser commands are handled locally, without an agent.
        if (browser) {
            const cmd = root.browserCommand(text);
            if (cmd) {
                root.show("busy", "Controlling the browser…");
                agents.browserAction(target.address, target.cls, cmd.action, cmd.arg, "type");
                return;
            }
        }
        // Over a terminal, "run <command>" or "!<command>" types the command into it and presses Enter, with no agent.
        // Only real terminal emulators can receive typed keystrokes. Nautilus and editors
        // are handled through their own context (run in folder / apply file change).
        const terminal = ["foot", "alacritty", "kitty", "com.mitchellh.ghostty", "org.wezfurlong.wezterm"].indexOf(cls) >= 0;
        const typed = text.startsWith("!") ? text.slice(1) : (terminal && /^run\s+/i.test(text) ? text.replace(/^run\s+/i, "") : null);
        if (typed !== null) {
            agents.typeInto(target.address, target.cls, typed.trim(), "type");
            return;
        }
        // Usual commands are typed straight into a terminal, with no agent round-trip.
        if (terminal) {
            const usual = root.terminalCommand(text);
            if (usual !== null) {
                agents.typeInto(target.address, target.cls, usual.trim(), "type");
                return;
            }
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
            visible: root.service ? !root.service.homeMode : true
            anchors { top: true; bottom: true; left: true; right: true }
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "goop"
            WlrLayershell.keyboardFocus: (root.promptOpen && here) ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

            // Hide the prompt when the overlay loses keyboard focus (e.g. a click elsewhere).
            Connections {
                target: win
                function onActiveChanged() {
                    if (!win.active && root.promptOpen) {
                        root.promptOpen = false;
                        root.mood = "rest";
                    }
                }
            }

            Region {
                id: normalMask
                Region { item: blobHit }
                Region { item: promptHit }
                Region { item: bubbleHit }
                Region { item: menuHit }
            }
            Region {
                id: fullMask
                x: 0; y: 0
                width: win.width; height: win.height
            }
            // While the prompt is open, accept input everywhere so a click anywhere
            // dismisses it; otherwise only the interactive bits take input.
            mask: root.promptOpen ? fullMask : normalMask

            // Clicking anywhere outside the prompt while it is open dismisses it.
            MouseArea {
                anchors.fill: parent
                z: -1
                enabled: root.promptOpen
                onClicked: {
                    root.promptOpen = false;
                    root.mood = "rest";
                }
            }

            // Only the things the user can click take input; everything else reaches the windows below.
            // (mask above already handles the input region.)

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
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.RightButton
                    onClicked: (mouse) => {
                        const g = mapToGlobal(mouse.x, mouse.y);
                        root.openMenu(g.x, g.y);
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
                    height: menuColumn.implicitHeight + 12
                    radius: 10
                    color: Commons.Color.menu.background
                    border.width: 1
                    border.color: Commons.Color.menu.border

                    Column {
                        id: menuColumn
                        anchors.fill: parent
                        anchors.margins: 6

                        Repeater {
                            model: [
                                { label: "Go home", action: "home" },
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
                                        if (modelData.action === "home") {
                                            if (root.service) root.service.homeMode = true;
                                        } else if (modelData.action === "settings")
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
