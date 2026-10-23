import QtQuick
import Quickshell.Io
import Quickshell.Hyprland

// Finds the window under a point. Positions are in global layout coordinates across
// all monitors, which is how Hyprland reports them. A window counts only when it is
// on its monitor's active workspace.
Item {
    id: root

    property var clients: []
    property var monitors: []
    property string address: ""
    property var activeClient: null
    signal activeChanged()

    readonly property bool docked: address !== ""
    readonly property var current: findClient(address)
    readonly property bool shown: docked && current !== null && isVisible(current)
    readonly property real centerX: shown ? current.x + current.width / 2 : 0
    readonly property real topY: shown ? current.y : 0

    function findClient(wanted) {
        for (const client of clients)
            if (client.address === wanted)
                return client;
        return null;
    }

    function isVisible(client) {
        const monitor = monitors.find(m => m.id === client.monitor);
        return client.mapped && monitor !== undefined && monitor.activeWorkspaceId === client.workspaceId;
    }

    // The window under a global point. Among overlapping windows, the most recently focused one wins.
    function clientAt(x, y) {
        let best = null;
        for (const client of clients) {
            if (!isVisible(client))
                continue;
            if (x < client.x || x >= client.x + client.width || y < client.y || y >= client.y + client.height)
                continue;
            if (best === null || client.focusRank < best.focusRank)
                best = client;
        }
        return best;
    }

    function attach(clientAddress) {
        address = clientAddress;
        refresh();
    }

    function detach() {
        address = "";
    }

    function refresh() {
        if (!queryClients.running)
            queryClients.running = true;
        if (!queryMonitors.running)
            queryMonitors.running = true;
        if (!queryActive.running)
            queryActive.running = true;
    }

    function parseJson(text) {
        try {
            return JSON.parse(text);
        } catch (error) {
            return null;
        }
    }

    function applyClients(text) {
        const parsed = parseJson(text);
        if (!parsed)
            return;
        if (docked && !parsed.some(c => c.address === address))
            detach();
        clients = parsed.map(c => ({
            address: c.address,
            x: c.at[0],
            y: c.at[1],
            width: c.size[0],
            height: c.size[1],
            workspaceId: c.workspace.id,
            monitor: c.monitor,
            mapped: c.mapped && !c.hidden,
            focusRank: c.focusHistoryID,
            title: c.title,
            cls: c.class,
            pid: c.pid
        }));
    }

    function applyMonitors(text) {
        const parsed = parseJson(text);
        if (!parsed)
            return;
        monitors = parsed.map(m => ({ id: m.id, activeWorkspaceId: m.activeWorkspace.id }));
    }

    Process {
        id: queryClients
        command: ["hyprctl", "-j", "clients"]
        stdout: StdioCollector {
            id: clientsOutput
            waitForEnd: true
        }
        onExited: (code) => {
            if (code === 0)
                root.applyClients(clientsOutput.text);
        }
    }

    Process {
        id: queryMonitors
        command: ["hyprctl", "-j", "monitors"]
        stdout: StdioCollector {
            id: monitorsOutput
            waitForEnd: true
        }
        onExited: (code) => {
            if (code === 0)
                root.applyMonitors(monitorsOutput.text);
        }
    }

    Process {
        id: queryActive
        command: ["hyprctl", "-j", "activewindow"]
        stdout: StdioCollector {
            id: activeOutput
            waitForEnd: true
        }
        onExited: (code) => {
            if (code === 0) {
                try {
                    const c = JSON.parse(activeOutput.text);
                    root.activeClient = {
                        address: c.address,
                        x: c.at[0],
                        y: c.at[1],
                        width: c.size[0],
                        height: c.size[1],
                        workspaceId: c.workspace.id,
                        monitor: c.monitor,
                        mapped: c.mapped && !c.hidden,
                        focusRank: c.focusHistoryID,
                        title: c.title,
                        cls: c.class,
                        pid: c.pid
                    };
                } catch (e) {
                    root.activeClient = null;
                }
            }
            root.activeChanged();
        }
    }

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            root.refresh();
        }
    }

    Component.onCompleted: refresh()
}
