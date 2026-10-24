#!/usr/bin/env python3
"""goop's editor bridge. It finds the file shown by an editor window, snapshots it
for the agent, and applies or reverts the agent's proposed file.

  editor.py context <window-title> <window-class> <window-pid> [request]
      The request is searched for a file name when the window shows none.
      Writes a snapshot of the file (plus diagnostics, when a checker applies) and prints
      {"ok", "context_file", "file", "editor", "diagnostics", "error"}.
  editor.py apply <proposal-file>
      Backs up the file and writes the proposal. Refuses if the file changed since the snapshot.
  editor.py revert <proposal-file>
      Restores the backup written by apply.
  editor.py type <window-address> <window-class> <command>
      Focuses a terminal window and types the command into it, then presses Enter.

Supported windows: Neovim running in a terminal (read from the process tree, so the file
is the one it was started with), Zed and VS Code (read from the window title).
"""

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

STATE = os.path.expanduser("~/.local/state/goop")
CONTEXT_DIR = os.path.join(STATE, "context")
PROPOSAL_DIR = os.path.join(STATE, "proposals")
BACKUP_DIR = os.path.join(STATE, "backups")

SEARCH_ROOTS = ["~/Projects", "~/Work", "~/src", "~/code"]
SKIP_DIRS = {"node_modules", ".build", "target", "build", "dist", "__pycache__", "venv", ".venv"}
PROJECT_MARKERS = [".git", "Package.swift", "Cargo.toml", "go.mod", "package.json", "pyproject.toml"]
MAX_CONTENT_BYTES = 400_000
MAX_FILE_DEPTH = 8
HOME_SEARCH_DEPTH = 3
CHECK_TIMEOUT = 120
LANGUAGES = {
    ".swift": "swift", ".py": "python", ".rs": "rust", ".go": "go", ".ts": "typescript",
    ".tsx": "tsx", ".js": "javascript", ".jsx": "jsx", ".c": "c", ".h": "c", ".cpp": "cpp",
    ".hpp": "cpp", ".md": "markdown", ".qml": "qml", ".sh": "bash", ".json": "json",
    ".lua": "lua", ".java": "java", ".kt": "kotlin",
}
TITLE_SEPARATOR = re.compile(r"\s[—–-]\s")
TERMINALS = {"foot", "alacritty", "kitty", "com.mitchellh.ghostty", "org.wezfurlong.wezterm"}
NAUTILUS = {"org.gnome.nautilus", "nautilus"}
BROWSERS = {"google-chrome", "google-chrome-stable", "chromium", "chromium-browser",
            "brave-browser", "brave", "microsoft-edge", "microsoft-edge-stable",
            "firefox", "firefox-esr", "zen-browser", "zen", "vivaldi", "vivaldi-stable",
            "opera", "org.mozilla.firefox"}
SHELLS = {"bash", "zsh", "fish", "sh", "dash"}


def stamp():
    return time.strftime("%Y%m%d-%H%M%S") + "-" + format(time.time_ns() % 1_000_000, "06d")


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2)
    return path


def write_atomic(path, data):
    # Write beside the target and rename, so the file is never half-written.
    directory = os.path.dirname(path)
    fd, temp = tempfile.mkstemp(dir=directory, prefix=".goop-")
    with os.fdopen(fd, "wb") as handle:
        handle.write(data)
    shutil.copymode(path, temp)
    os.replace(temp, path)


def parse_title(title, cls):
    """Returns (editor, file name, project name) from a window title such as 'Face.swift — goop'."""
    parts = [p.strip() for p in TITLE_SEPARATOR.split(title or "") if p.strip()]
    low = (cls or "").lower()
    editor = None
    if (parts and parts[-1] == "Visual Studio Code") or low in ("code", "code-oss", "codium"):
        editor = "vscode"
    elif (parts and parts[-1] == "Zed") or "zed" in low:
        editor = "zed"
    if editor and parts and parts[-1] in ("Visual Studio Code", "Zed"):
        parts = parts[:-1]
    # Zed titles a window as "<workspace> — <file>" (workspace first), while
    # VS Code uses "<file> — <project> — Visual Studio Code" (file first).
    if editor == "zed" and len(parts) >= 2:
        file_name = parts[-1]
        project = parts[0]
        if project == file_name:
            project = ""
    else:
        file_name = parts[0] if parts else ""
        project = parts[1] if len(parts) > 1 else ""
    if "/" in file_name or not os.path.splitext(file_name)[1]:
        return editor, "", ""
    return editor, file_name, project


def children_of(pid):
    tree = {}
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open(f"/proc/{entry}/stat", encoding="utf-8") as handle:
                stat = handle.read()
        except OSError:
            continue
        # The command name can contain spaces and brackets, so parse after its closing ')'.
        fields = stat[stat.rfind(")") + 2:].split()
        tree.setdefault(int(fields[1]), []).append(int(entry))
    found, stack = [], [pid]
    while stack:
        for child in tree.get(stack.pop(), []):
            found.append(child)
            stack.append(child)
    return found


def neovim_file(pid):
    """The file a Neovim process under this window was started with, or None."""
    for candidate in [pid] + children_of(pid):
        try:
            with open(f"/proc/{candidate}/comm", encoding="utf-8") as handle:
                name = handle.read().strip()
            if name not in ("nvim", "vim"):
                continue
            with open(f"/proc/{candidate}/cmdline", "rb") as handle:
                args = [a.decode(errors="replace") for a in handle.read().split(b"\0") if a]
            cwd = os.readlink(f"/proc/{candidate}/cwd")
        except OSError:
            continue
        for arg in args[1:]:
            path = os.path.abspath(os.path.join(cwd, arg))
            if not arg.startswith("-") and os.path.isfile(path):
                return path
    return None


def terminal_cwd(pid):
    """The working directory of the first shell running under a terminal window, or None."""
    for candidate in children_of(pid):
        try:
            with open(f"/proc/{candidate}/comm", encoding="utf-8") as handle:
                name = handle.read().strip()
            if name in SHELLS:
                return os.readlink(f"/proc/{candidate}/cwd")
        except OSError:
            continue
    return None


def nautilus_cwd(title):
    """Best-effort working directory for a Nautilus window, from its title."""
    name = (title or "").strip()
    if not name or name.lower() in ("home", "~", "files", "nautilus"):
        return os.path.expanduser("~")
    # Search common roots for a folder with this name.
    for root in SEARCH_ROOTS:
        root = os.path.expanduser(root)
        if not os.path.isdir(root):
            continue
        for dirpath, dirnames, _ in os.walk(root):
            rel = os.path.relpath(dirpath, root)
            depth = 0 if rel == "." else rel.count(os.sep) + 1
            if depth > 4:
                dirnames[:] = []
                continue
            dirnames[:] = [d for d in dirnames if not d.startswith(".") and d not in SKIP_DIRS]
            if os.path.basename(dirpath) == name and os.path.isdir(dirpath):
                return dirpath
    # Last resort: a top-level folder in the home directory.
    candidate = os.path.expanduser("~/" + name)
    if os.path.isdir(candidate):
        return candidate
    return None


def find_project_dir(name):
    for root in SEARCH_ROOTS:
        root = os.path.expanduser(root)
        if not os.path.isdir(root):
            continue
        for dirpath, dirnames, _ in os.walk(root):
            rel = os.path.relpath(dirpath, root)
            depth = 0 if rel == "." else rel.count(os.sep) + 1
            if depth > 0 and os.path.basename(dirpath) == name:
                return dirpath
            if depth >= 3:
                dirnames[:] = []
            else:
                dirnames[:] = [d for d in dirnames if not d.startswith(".") and d not in SKIP_DIRS]
    return None


def find_file(directory, name, max_depth=MAX_FILE_DEPTH):
    best = None
    for dirpath, dirnames, filenames in os.walk(directory):
        rel = os.path.relpath(dirpath, directory)
        depth = 0 if rel == "." else rel.count(os.sep) + 1
        if depth >= max_depth:
            dirnames[:] = []
        else:
            dirnames[:] = [d for d in dirnames if not d.startswith(".") and d not in SKIP_DIRS]
        if name in filenames:
            path = os.path.join(dirpath, name)
            if best is None or len(path) < len(best):
                best = path
    return best


def project_root(file_path):
    directory = os.path.dirname(file_path)
    while True:
        if any(os.path.exists(os.path.join(directory, m)) for m in PROJECT_MARKERS):
            return directory
        parent = os.path.dirname(directory)
        if parent == directory:
            return os.path.dirname(file_path)
        directory = parent


def run_check(file_path, root):
    """Runs the project's compiler or checker, if one is installed. Returns None when there is none."""
    checks = [
        ("Package.swift", ["swift", "build"]),
        ("Cargo.toml", ["cargo", "check", "--message-format", "short"]),
        ("go.mod", ["go", "vet", "./..."]),
        ("tsconfig.json", ["npx", "--no-install", "tsc", "--noEmit"]),
    ]
    for marker, command in checks:
        if os.path.exists(os.path.join(root, marker)) and shutil.which(command[0]):
            break
    else:
        if file_path.endswith(".py") and shutil.which("python3"):
            command = ["python3", "-m", "py_compile", file_path]
        else:
            return None
    try:
        result = subprocess.run(command, cwd=root, capture_output=True, text=True, timeout=CHECK_TIMEOUT)
    except subprocess.TimeoutExpired:
        return {"tool": " ".join(command), "ok": False, "output": "timed out"}
    output = (result.stdout + result.stderr).strip()
    return {"tool": " ".join(command), "ok": result.returncode == 0, "output": output[-6000:]}


def find_file_in_roots(name):
    """Looks for a file in the project folders first, then a few levels into the home folder."""
    for root in SEARCH_ROOTS:
        root = os.path.expanduser(root)
        if os.path.isdir(root):
            found = find_file(root, name)
            if found:
                return found
    return find_file(os.path.expanduser("~"), name, max_depth=HOME_SEARCH_DEPTH)


def file_named_in(text):
    """A file whose name appears in the request, or None."""
    for token in re.findall(r"[\w./-]+\.\w+", text or ""):
        if os.path.isabs(token) and os.path.isfile(token):
            return token
        found = find_file_in_roots(os.path.basename(token))
        if found:
            return found
    return None


def context(title, cls, pid, request=""):
    editor, file_path, error = None, None, None
    window_pid = int(pid or 0)
    nvim = neovim_file(window_pid) if window_pid > 0 else None
    if nvim:
        editor, file_path = "neovim", nvim
    elif (cls or "").lower() in NAUTILUS:
        editor = "nautilus"
    elif (cls or "").lower() in BROWSERS:
        editor = "browser"
    else:
        editor, file_name, project_name = parse_title(title, cls)
        if file_name:
            # Zed titles a single opened file as "name — name", so the project name may be the file itself.
            project_dir = find_project_dir(project_name) if project_name and project_name != file_name else None
            file_path = find_file(project_dir, file_name) if project_dir else None
            if file_path is None:
                file_path = find_file_in_roots(file_name)
            if file_path is None:
                error = f"Could not find {file_name}. Name its folder in your request, for example \"{file_name} is in ~/notes\"."

    if file_path is None and request:
        file_path = file_named_in(request)
    if file_path is None and editor in ("zed", "vscode"):
        # An editor with no visible file: answering as chat would not touch the code the user sees.
        name = "Zed" if editor == "zed" else "VS Code"
        return {"ok": False, "error": error or f"{name} shows no file. Open one, or name it in your request, "
                                               "for example \"fix broken.py\"."}

    if file_path is None and editor == "nautilus":
        cwd = nautilus_cwd(title)
        if cwd is None:
            return {"ok": False, "error": "goop cannot tell which folder Nautilus is showing. "
                                          "Name the folder in your request, for example \"in ~/Projects\"."}
        path = write_json(os.path.join(CONTEXT_DIR, stamp() + ".json"), {
            "editor": "nautilus",
            "window_title": title,
            "window_class": cls,
            "file": None,
            "cwd": cwd,
        })
        return {"ok": True, "context_file": path, "file": None, "editor": "nautilus", "diagnostics": None,
                "error": ""}

    if file_path is None and editor == "browser":
        path = write_json(os.path.join(CONTEXT_DIR, stamp() + ".json"), {
            "editor": "browser",
            "window_title": title,
            "window_class": cls,
            "file": None,
        })
        return {"ok": True, "context_file": path, "file": None, "editor": "browser", "diagnostics": None,
                "error": ""}

    if file_path is None:
        if window_pid > 0 and (cls or "").lower() in TERMINALS:
            cwd = terminal_cwd(window_pid)
            if cwd is None or not os.path.isdir(cwd):
                # Running in the wrong folder would be worse than not running, so stop and say why.
                return {"ok": False, "error": "The shell in this terminal is in a folder that no longer exists. "
                                              "Run cd into a folder in it, then ask again."
                        if cwd else "goop cannot find a shell in this terminal."}
        else:
            return {"ok": True, "context_file": "", "file": None, "editor": editor, "diagnostics": None,
                    "error": error or ""}
        path = write_json(os.path.join(CONTEXT_DIR, stamp() + ".json"), {
            "editor": "terminal",
            "window_title": title,
            "window_class": cls,
            "file": None,
            "cwd": cwd,
        })
        return {"ok": True, "context_file": path, "file": None, "editor": "terminal", "diagnostics": None,
                "error": error or ""}

    with open(file_path, "rb") as handle:
        raw = handle.read()
    if len(raw) > MAX_CONTENT_BYTES:
        return {"ok": False, "error": "The file is too large to send to an agent."}
    if b"\0" in raw:
        return {"ok": False, "error": "The file is binary."}

    root = project_root(file_path)
    diagnostics = run_check(file_path, root)
    path = write_json(os.path.join(CONTEXT_DIR, stamp() + ".json"), {
        "editor": editor,
        "window_title": title,
        "window_class": cls,
        "file": file_path,
        "relative": os.path.relpath(file_path, root),
        "project": root,
        "language": LANGUAGES.get(os.path.splitext(file_path)[1], ""),
        "content": raw.decode("utf-8", errors="replace"),
        "base_sha256": sha256(raw),
        "diagnostics": diagnostics,
    })
    return {"ok": True, "context_file": path, "file": file_path, "editor": editor,
            "diagnostics": diagnostics["tool"] + (" ok" if diagnostics["ok"] else " failed") if diagnostics else None,
            "error": error or ""}


def save_proposal(target, base_sha, content, explanation):
    return write_json(os.path.join(PROPOSAL_DIR, stamp() + ".json"), {
        "target": target,
        "base_sha256": base_sha,
        "content": content,
        "explanation": explanation,
        "applied": False,
        "applied_sha256": None,
        "backup": None,
    })


def load_proposal(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def apply(path):
    proposal = load_proposal(path)
    if proposal["applied"]:
        raise RuntimeError("This change is already applied.")
    target = proposal["target"]
    with open(target, "rb") as handle:
        current = handle.read()
    if sha256(current) != proposal["base_sha256"]:
        raise RuntimeError("The file changed since goop read it. Ask again to get a fresh change.")
    os.makedirs(BACKUP_DIR, exist_ok=True)
    backup = os.path.join(BACKUP_DIR, stamp() + "-" + os.path.basename(target))
    shutil.copy2(target, backup)
    new = proposal["content"].encode("utf-8")
    write_atomic(target, new)
    proposal.update(applied=True, applied_sha256=sha256(new), backup=backup)
    write_json(path, proposal)
    return {"ok": True, "target": target, "backup": backup}


def revert(path):
    proposal = load_proposal(path)
    if not proposal["applied"]:
        raise RuntimeError("This change has not been applied.")
    target = proposal["target"]
    with open(target, "rb") as handle:
        current = handle.read()
    if sha256(current) != proposal["applied_sha256"]:
        raise RuntimeError("The file changed after goop applied its change, so it was not reverted.")
    with open(proposal["backup"], "rb") as handle:
        write_atomic(target, handle.read())
    proposal["applied"] = False
    write_json(path, proposal)
    return {"ok": True, "target": target}


DESKTOP_DIRS = ["/usr/share/applications", os.path.expanduser("~/.local/share/applications")]


def _desktop_entries():
    entries = []
    for directory in DESKTOP_DIRS:
        if not os.path.isdir(directory):
            continue
        for filename in os.listdir(directory):
            if not filename.endswith(".desktop"):
                continue
            path = os.path.join(directory, filename)
            name = ""
            exec_line = ""
            try:
                with open(path, encoding="utf-8", errors="replace") as handle:
                    for line in handle:
                        if line.startswith("Name=") and not name:
                            name = line[len("Name="):].strip()
                        elif line.startswith("Exec=") and not exec_line:
                            exec_line = line[len("Exec="):].strip()
                        elif line.strip() == "[Desktop Entry]":
                            continue
            except OSError:
                continue
            if name or exec_line:
                entries.append((filename, name, exec_line))
    return entries


def find_desktop_entry(name):
    low = (name or "").strip().lower()
    if not low:
        return None
    entries = _desktop_entries()
    # Exact name match first.
    for filename, entry_name, exec_line in entries:
        if entry_name and entry_name.lower() == low:
            return filename, entry_name, exec_line
    # Then a name or desktop id containing the request.
    for filename, entry_name, exec_line in entries:
        desktop_id = filename[:-len(".desktop")]
        if low in (entry_name or "").lower() or low in desktop_id.lower():
            return filename, entry_name, exec_line
    # Finally, match the executable basename.
    for filename, entry_name, exec_line in entries:
        if not exec_line:
            continue
        binary = exec_line.split()[0].split("/")[-1].lower()
        if low == binary or low in binary:
            return filename, entry_name, exec_line
    return None


def open_app(name):
    name = (name or "").strip().strip("\"'")
    if not name:
        raise RuntimeError("No application name given.")
    aliases = {
        "files": "nautilus", "file manager": "nautilus", "filemanager": "nautilus",
        "terminal": os.environ.get("TERMINAL", "foot"),
        "browser": None,
    }
    low = name.lower()
    if low in aliases and aliases[low]:
        name = aliases[low]
        low = name.lower()

    # Direct executable on PATH.
    binary = shutil.which(name) or shutil.which(name.lower())
    if binary:
        subprocess.Popen([binary], start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return {"ok": True, "launched": os.path.basename(binary)}

    entry = find_desktop_entry(name)
    if entry:
        filename, entry_name, exec_line = entry
        desktop_id = filename[:-len(".desktop")]
        if shutil.which("gtk-launch"):
            subprocess.Popen(["gtk-launch", desktop_id], start_new_session=True,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return {"ok": True, "launched": entry_name or desktop_id}
        # Fall back to parsing the Exec line.
        if exec_line:
            parts = exec_line.replace("%u", "").replace("%U", "").replace("%f", "").replace("%F", "").split()
            if parts:
                subprocess.Popen(parts, start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                return {"ok": True, "launched": entry_name or parts[0]}

    # Last resort: let xdg-open try (handles urls and registered types).
    if shutil.which("xdg-open"):
        subprocess.Popen(["xdg-open", name], start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return {"ok": True, "launched": name}

    raise RuntimeError(f"Could not find an application called {name!r}.")


def type_into(address, window_class, command):
    if (window_class or "").lower() not in TERMINALS:
        raise RuntimeError("Commands can only be typed into a terminal window.")
    if not command.strip():
        raise RuntimeError("There is no command to type.")
    # Hyprland 0.56 dispatches are Lua calls.
    focus = f'hl.dsp.focus({{ window = "address:{address}" }})'
    subprocess.run(["hyprctl", "dispatch", focus], check=True, capture_output=True)
    # Give Hyprland a moment to move keyboard focus before the keys are sent.
    time.sleep(0.15)
    subprocess.run(["wtype", "--", command], check=True)
    subprocess.run(["wtype", "-k", "Return"], check=True)
    return {"ok": True, "typed": command}


def browser_action(address, window_class, action, arg=""):
    if (window_class or "").lower() not in BROWSERS:
        raise RuntimeError("Browser actions only work in a browser window.")
    focus = f'hl.dsp.focus({{ window = "address:{address}" }})'
    subprocess.run(["hyprctl", "dispatch", focus], check=True, capture_output=True)
    time.sleep(1.0)
    action = (action or "").lower()
    if action == "new_tab":
        subprocess.run(["wtype", "-M", "ctrl", "-k", "t"], check=True)
    elif action == "new_window":
        subprocess.run(["wtype", "-M", "ctrl", "-k", "n"], check=True)
    elif action == "close_tab":
        subprocess.run(["wtype", "-M", "ctrl", "-k", "w"], check=True)
    elif action == "reload":
        subprocess.run(["wtype", "-M", "ctrl", "-k", "r"], check=True)
    elif action == "back":
        subprocess.run(["wtype", "-M", "alt", "-k", "Left"], check=True)
    elif action == "forward":
        subprocess.run(["wtype", "-M", "alt", "-k", "Right"], check=True)
    elif action == "navigate":
        if not arg.strip():
            raise RuntimeError("No address to navigate to.")
        subprocess.run(["wtype", "-M", "ctrl", "-k", "l"], check=True)
        time.sleep(0.15)
        subprocess.run(["wtype", "--", arg.strip()], check=True)
        subprocess.run(["wtype", "-k", "Return"], check=True)
    elif action == "switch_tab":
        if not arg.strip():
            raise RuntimeError("No tab name given.")
        subprocess.run(["wtype", "-M", "ctrl", "-M", "shift", "-k", "a"], check=True)
        time.sleep(0.25)
        subprocess.run(["wtype", "--", arg.strip()], check=True)
        time.sleep(0.15)
        subprocess.run(["wtype", "-k", "Return"], check=True)
    elif action == "close_tab_named":
        if not arg.strip():
            raise RuntimeError("No tab name given.")
        subprocess.run(["wtype", "-M", "ctrl", "-M", "shift", "-k", "a"], check=True)
        time.sleep(0.25)
        subprocess.run(["wtype", "--", arg.strip()], check=True)
        time.sleep(0.15)
        subprocess.run(["wtype", "-k", "Return"], check=True)
        time.sleep(0.2)
        subprocess.run(["wtype", "-M", "ctrl", "-k", "w"], check=True)
    elif action == "search":
        if not arg.strip():
            raise RuntimeError("No text to search for.")
        cls = (window_class or "").lower()
        if cls in ("firefox", "firefox-esr", "zen", "zen-browser"):
            # Firefox/Zen quick find for links: apostrophe, text, Enter.
            subprocess.run(["wtype", "'"], check=True)
            time.sleep(0.25)
            subprocess.run(["wtype", "--", arg.strip()], check=True)
            time.sleep(0.15)
            subprocess.run(["wtype", "-k", "Return"], check=True)
        else:
            # Chrome/Chromium and friends: find the text, close the find bar
            # (focus lands on the matched link), then open it with Enter.
            subprocess.run(["wtype", "-M", "ctrl", "-k", "f"], check=True)
            time.sleep(0.8)
            subprocess.run(["wtype", "--", arg.strip()], check=True)
            time.sleep(0.6)
            subprocess.run(["wtype", "-k", "Escape"], check=True)
            time.sleep(0.6)
            subprocess.run(["wtype", "-k", "Return"], check=True)
    else:
        raise RuntimeError(f"Unknown browser action {action!r}.")
    return {"ok": True, "action": action, "arg": arg.strip()}


def main(argv):
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    command = argv[1]
    try:
        if command == "context":
            result = context(argv[2], argv[3] if len(argv) > 3 else "", argv[4] if len(argv) > 4 else "0",
                             argv[5] if len(argv) > 5 else "")
        elif command == "apply":
            result = apply(argv[2])
        elif command == "revert":
            result = revert(argv[2])
        elif command == "type":
            result = type_into(argv[2], argv[3], argv[4])
        elif command == "open":
            result = open_app(argv[2] if len(argv) > 2 else "")
        elif command == "media":
            action = argv[2].strip() if len(argv) > 2 else "playPause"
            mapping = {"playpause": "playPause", "play/pause": "playPause", "toggle": "playPause",
                       "play": "play", "pause": "pause", "resume": "play", "stop": "pause"}
            action = mapping.get(action.lower().replace(" ", ""), action)
            if action not in ("play", "pause", "playPause"):
                raise RuntimeError(f"Unknown media action {action!r}.")
            subprocess.run(["omarchy", "shell", "media", action], check=True)
            result = {"ok": True, "action": action}
        elif command == "browser":
            result = browser_action(argv[2], argv[3], argv[4], argv[5] if len(argv) > 5 else "")
        else:
            print(f"unknown command {command!r}", file=sys.stderr)
            return 2
    except Exception as error:
        print(json.dumps({"ok": False, "error": str(error)}))
        return 0
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
