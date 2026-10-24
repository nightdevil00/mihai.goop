import QtQuick
import Quickshell
import Quickshell.Io

// Talks to agents.py and editor.py. Each call runs its own short-lived process, so
// requests can overlap, and the result comes back through a signal carrying the caller's tag.
QtObject {
    id: root

    // The scripts sit beside this file, in the plugin folder.
    readonly property string agentScript: decodeURIComponent(Qt.resolvedUrl("agents.py").toString().replace("file://", ""))
    readonly property string editorScript: decodeURIComponent(Qt.resolvedUrl("editor.py").toString().replace("file://", ""))
    property var config: ({ agents: [], active: "" })

    signal configLoaded()
    signal saved()
    signal replied(string tag, string text, string proposal)
    signal contextReady(string tag, string contextFile)
    signal applied(string tag, string target)
    signal reverted(string tag, string target)
    signal typed(string tag, string command)
    signal opened(string tag, string app)
    signal failed(string tag, string message)

    property Component runner: Component {
        Process {
            id: proc
            property string kind: ""
            property string tag: ""

            stdout: StdioCollector {
                id: out
                waitForEnd: true
            }
            stderr: StdioCollector {
                id: err
                waitForEnd: true
            }
            onExited: (code) => {
                root.handle(proc.kind, proc.tag, code, out.text.trim(), err.text.trim());
                proc.destroy();
            }
        }
    }

    function run(kind, tag, command) {
        const proc = runner.createObject(root, { kind: kind, tag: tag, command: command });
        proc.running = true;
    }

    function loadConfig() {
        run("config", "", ["python3", agentScript, "config"]);
    }

    function save(newConfig) {
        run("save", "", ["python3", agentScript, "save", JSON.stringify(newConfig)]);
    }

    // contextFile is "" when the request is not about a file.
    function ask(agentId, prompt, contextFile, tag) {
        run("ask", tag, ["python3", agentScript, "ask", agentId, JSON.stringify({ prompt: prompt, context_file: contextFile })]);
    }

    // request is the user's text, so a file it names can be found when the window shows none.
    function captureContext(title, windowClass, pid, request, tag) {
        run("context", tag, ["python3", editorScript, "context", title, windowClass, String(pid), request]);
    }

    function applyProposal(path, tag) {
        run("apply", tag, ["python3", editorScript, "apply", path]);
    }

    function revertProposal(path, tag) {
        run("revert", tag, ["python3", editorScript, "revert", path]);
    }

    function typeInto(address, windowClass, command, tag) {
        run("type", tag, ["python3", editorScript, "type", address, windowClass, command]);
    }

    function openApp(name, tag) {
        run("open", tag, ["python3", editorScript, "open", name]);
    }

    function browserAction(address, windowClass, action, arg, tag) {
        run("browser", tag, ["python3", editorScript, "browser", address, windowClass, action, arg]);
    }

    function parse(stdout) {
        try {
            return JSON.parse(stdout);
        } catch (error) {
            return null;
        }
    }

    function handle(kind, tag, code, stdout, stderr) {
        if (kind === "config") {
            const parsed = code === 0 ? parse(stdout) : null;
            if (parsed) {
                root.config = parsed;
                root.configLoaded();
            } else {
                root.failed("", stderr || "Could not read agents.json");
            }
        } else if (kind === "save") {
            if (code === 0) {
                root.loadConfig();
                root.saved();
            } else {
                root.failed("save", stderr || "Could not save");
            }
        } else if (kind === "ask") {
            const answer = parse(stdout);
            if (answer && answer.ok)
                root.replied(tag, answer.reply, answer.proposal || "");
            else
                root.failed(tag, answer && answer.error ? answer.error : (stderr || "No answer from the agent"));
        } else if (kind === "context") {
            const answer = parse(stdout);
            if (answer && answer.ok)
                root.contextReady(tag, answer.context_file || "");
            else
                root.failed(tag, answer && answer.error ? answer.error : (stderr || "Could not read the window"));
        } else if (kind === "apply") {
            const answer = parse(stdout);
            if (answer && answer.ok)
                root.applied(tag, answer.target);
            else
                root.failed(tag, answer && answer.error ? answer.error : (stderr || "Could not apply the change"));
        } else if (kind === "type") {
            const answer = parse(stdout);
            if (answer && answer.ok)
                root.typed(tag, answer.typed);
            else
                root.failed(tag, answer && answer.error ? answer.error : (stderr || "Could not type the command"));
        } else if (kind === "open") {
            const answer = parse(stdout);
            if (answer && answer.ok)
                root.opened(tag, answer.launched || "");
            else
                root.failed(tag, answer && answer.error ? answer.error : (stderr || "Could not open the application"));
        } else if (kind === "browser") {
            const answer = parse(stdout);
            if (answer && answer.ok)
                root.typed(tag, answer.action + (answer.arg ? ": " + answer.arg : ""));
            else
                root.failed(tag, answer && answer.error ? answer.error : (stderr || "Could not control the browser"));
        } else if (kind === "revert") {
            const answer = parse(stdout);
            if (answer && answer.ok)
                root.reverted(tag, answer.target);
            else
                root.failed(tag, answer && answer.error ? answer.error : (stderr || "Could not undo the change"));
        }
    }

    Component.onCompleted: loadConfig()
}
