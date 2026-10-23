import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons as Commons as Commons

// Right-click goop > Settings. Edits a copy of the configuration and only writes
// it to disk when Save is pressed.
FloatingWindow {
    id: win

    required property var agents

    title: "goop settings"
    color: Commons.Color.menu.background
    implicitWidth: 760
    implicitHeight: 480
    visible: false

    property var draft: ({ agents: [], active: "" })
    property int selected: -1
    property int revision: 0
    property string status: ""
    property var modelList: []

    function agentModel() {
        if (!current || !current.command)
            return "";
        const i = current.command.indexOf("--model");
        if (i >= 0 && i + 1 < current.command.length)
            return current.command[i + 1];
        return "";
    }

    function setAgentModel(model) {
        if (!current)
            return;
        const cmd = (current.command || []).slice();
        const i = cmd.indexOf("--model");
        if (i >= 0 && i + 1 < cmd.length)
            cmd[i + 1] = model;
        else {
            cmd.push("--model");
            cmd.push(model);
        }
        setValue("command", cmd);
    }

    Process {
        id: modelProc
        command: ["opencode", "models"]
        stdout: StdioCollector {
            id: modelOut
            waitForEnd: true
        }
        onExited: (code) => {
            if (code === 0) {
                const lines = modelOut.text.trim().split("\n").map(s => s.trim()).filter(s => s.length > 0);
                win.modelList = lines;
            }
        }
    }

    readonly property var current: selected >= 0 && selected < draft.agents.length ? draft.agents[selected] : null

    function clone(value) {
        return JSON.parse(JSON.stringify(value));
    }

    function addAgent(kind) {
        const copy = clone(draft);
        const count = copy.agents.length + 1;
        if (kind === "cli")
            copy.agents.push({ id: "agent" + count, name: "CLI agent " + count, type: "cli", command: [] });
        else
            copy.agents.push({ id: "agent" + count, name: "API agent " + count, type: "openai", base_url: "https://api.openai.com/v1", model: "", api_key: "" });
        draft = copy;
        selectRow(copy.agents.length - 1);
        status = "Fill in the fields, then Save.";
    }

    function setValue(key, value) {
        if (!current)
            return;
        current[key] = value;
        revision++;
    }

    function removeSelected() {
        if (!current)
            return;
        const copy = clone(draft);
        copy.agents.splice(selected, 1);
        if (copy.active === current.id)
            copy.active = copy.agents.length ? copy.agents[0].id : "";
        draft = copy;
        selectRow(Math.min(selected, copy.agents.length - 1));
    }

    function setOption(key, value) {
        const copy = clone(draft);
        copy[key] = value;
        draft = copy;
    }

    function makeDefault() {
        if (!current)
            return;
        draft.active = current.id;
        revision++;
    }

    function selectRow(index) {
        selected = index;
        const a = current;
        idField.text = a ? a.id || "" : "";
        nameField.text = a ? a.name || "" : "";
        commandField.text = a && a.command ? a.command.join(" ") : "";
        urlField.text = a ? a.base_url || "" : "";
        modelField.text = a ? a.model || "" : "";
        keyField.text = a ? a.api_key || "" : "";
    }

    function validate() {
        const seen = {};
        for (const a of draft.agents) {
            if (!a.id || !a.id.trim())
                return "Every agent needs an ID.";
            if (seen[a.id])
                return "Agent IDs must be unique (" + a.id + " is used twice).";
            seen[a.id] = true;
            if (a.type === "cli" && (!a.command || a.command.length === 0))
                return a.name + " needs a command.";
            if (a.type === "openai" && (!a.base_url || !a.model))
                return a.name + " needs a base URL and a model.";
        }
        return "";
    }

    function save() {
        const problem = validate();
        if (problem !== "") {
            status = problem;
            return;
        }
        status = "Saving…";
        agents.save(draft);
    }

    onVisibleChanged: {
        if (visible) {
            draft = clone(agents.config);
            selectRow(draft.agents.length ? 0 : -1);
            status = "";
            if (!modelProc.running)
                modelProc.running = true;
        }
    }

    Connections {
        target: win.agents
        function onSaved() { win.status = "Saved."; }
        function onFailed(tag, message) {
            if (tag === "save" || tag === "")
                win.status = message;
            else if (tag === "test")
                win.status = "Test failed: " + message;
        }
        function onReplied(tag, text) {
            if (tag === "test")
                win.status = "Test reply: " + text;
        }
    }

    Row {
        anchors.fill: parent
        anchors.margins: 16
        anchors.bottomMargin: 90
        spacing: 16

        // Agent list
        Column {
            width: 200
            height: parent.height
            spacing: 8

            Text {

                textFormat: Text.PlainText
                text: "Agents"
                color: Commons.Color.menu.text
                font.pixelSize: 15
                font.bold: true
            }

            Repeater {
                model: win.draft.agents
                delegate: Rectangle {
                    id: row
                    required property var modelData
                    required property int index
                    width: 200
                    height: 44
                    radius: 8
                    color: index === win.selected ? Commons.Color.menu.selectedBackground : Commons.Color.menu.background

                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: 12
                        Text {
                            textFormat: Text.PlainText
                            text: { win.revision; return row.modelData.name; }
                            color: Commons.Color.menu.text
                            font.pixelSize: 13
                        }
                        Text {
                            textFormat: Text.PlainText
                            text: (row.modelData.type === "cli" ? "CLI" : "API") + (win.draft.active === row.modelData.id ? " · default" : "")
                            color: Commons.Color.muted
                            font.pixelSize: 11
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: win.selectRow(row.index)
                    }
                }
            }

            Item { width: 1; height: 8 }
            GoopButton { text: "+ CLI agent"; width: 200; onClicked: win.addAgent("cli") }
            GoopButton { text: "+ API agent"; width: 200; onClicked: win.addAgent("openai") }
        }

        // Editor for the selected agent
        Column {
            width: parent.width - 216
            height: parent.height
            spacing: 10
            visible: win.current !== null

            GoopField { id: nameField; label: "Name"; onEdited: (t) => win.setValue("name", t) }
            GoopField { id: idField; label: "ID (used by goop; no spaces)"; onEdited: (t) => win.setValue("id", t.replace(/\s/g, "")) }

            GoopField {
                id: commandField
                label: "Command (program and arguments, separated by spaces)"
                visible: win.current !== null && win.current.type === "cli"
                onEdited: (t) => win.setValue("command", t.split(" ").filter(s => s !== ""))
            }

            // Model picker for the bundled opencode agent.
            Row {
                spacing: 8
                visible: win.current !== null && win.current.type === "cli"
                         && win.current.command && win.current.command.join(" ").indexOf("opencode.py") >= 0
                width: parent.width

                Text {
                    textFormat: Text.PlainText
                    text: "Model:"
                    color: Commons.Color.muted
                    font.pixelSize: 12
                    anchors.verticalCenter: parent.verticalCenter
                }

                ComboBox {
                    id: modelCombo
                    width: 280
                    model: win.modelList
                    currentIndex: win.modelList.length ? win.modelList.indexOf(win.agentModel()) : -1
                    onActivated: (index) => win.setAgentModel(win.modelList[index])
                }

                GoopButton {
                    text: "Refresh"
                    onClicked: {
                        if (!modelProc.running)
                            modelProc.running = true;
                    }
                }
            }

            GoopField {
                id: urlField
                label: "Base URL (OpenAI-compatible, e.g. https://api.openai.com/v1)"
                visible: win.current !== null && win.current.type === "openai"
                onEdited: (t) => win.setValue("base_url", t.trim())
            }
            GoopField {
                id: modelField
                label: "Model"
                visible: win.current !== null && win.current.type === "openai"
                onEdited: (t) => win.setValue("model", t.trim())
            }
            GoopField {
                id: keyField
                label: "API key (stored in ~/.config/goop/agents.json, readable only by you)"
                secret: true
                visible: win.current !== null && win.current.type === "openai"
                onEdited: (t) => win.setValue("api_key", t)
            }

            Row {
                spacing: 8
                GoopButton { text: "Make default"; enabled: win.current !== null && win.draft.active !== win.current.id; onClicked: win.makeDefault() }
                GoopButton { text: "Remove"; enabled: win.current !== null; onClicked: win.removeSelected() }
                GoopButton {
                    text: "Test"
                    enabled: win.current !== null
                    onClicked: {
                        win.status = "Testing " + win.current.name + "… (uses the saved config)";
                        win.agents.ask(win.current.id, "Reply with the single word: ok", "", "test");
                    }
                }
            }

            Text {

                textFormat: Text.PlainText
                width: parent.width
                text: win.status
                color: Commons.Color.muted
                font.pixelSize: 12
                wrapMode: Text.Wrap
            }
        }
    }

    Column {
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.margins: 16
        spacing: 6

        Row {
            spacing: 8
            GoopButton {
                text: "Auto-apply file changes: " + (win.draft.auto_apply ? "on" : "off")
                onClicked: win.setOption("auto_apply", !win.draft.auto_apply)
            }
            GoopButton {
                text: "Terminal commands: " + (win.draft.terminal_mode === "agent" ? "agent runs them" : "I type them")
                onClicked: win.setOption("terminal_mode", win.draft.terminal_mode === "agent" ? "type" : "agent")
            }
        }
        Row {
            spacing: 8
            GoopButton {
                text: "Mode: " + (win.draft.dockMode === "dock" ? "docked" : "floating")
                onClicked: win.setOption("dockMode", win.draft.dockMode === "dock" ? "float" : "dock")
            }
        }
    }

    Row {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 16
        spacing: 8
        GoopButton { text: "Close"; onClicked: win.visible = false }
        GoopButton { text: "Save"; primary: true; onClicked: win.save() }
    }
}
