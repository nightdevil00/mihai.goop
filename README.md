# goop

A pink desktop creature for Omarchy. It floats anywhere on the desktop, across monitors,
and takes a request for whichever window it is over. The request goes to an agent you
connect: a command-line agent, or an OpenAI-compatible API.

![goop](assets/goop.png)

It runs as an Omarchy shell plugin (`mihai.goop`). It is theme-aware and follows the
active Omarchy theme via `qs.Commons.Color`.

## How it works

1. **Pick a window.** Drag the creature over the window you want and drop it there, or
   leave it floating and click it. When you ask, goop uses the *focused* window (via
   `hyprctl activewindow`), falling back to the window under the creature.
2. **Type a request** and press Enter. Escape cancels.
3. **Context capture.** `editor.py` figures out what the window is showing:
   - **Neovim** in a terminal: reads the file from the process tree (the file Neovim was
     started with).
   - **Zed / VS Code**: parses the file and project from the window title.
   - **Terminal**: reads the shell's current working directory.
   - **Nautilus**: resolves the folder from the window title.
4. **Agent request.** `agents.py` sends the prompt plus that context to your configured
   agent. The agent never touches files or runs commands itself in *type* mode; in
   *agent* mode (or for Nautilus) it may run commands in the window's folder.
5. **Action.**
   - Terminal (type mode): the agent replies with one shell command; goop offers **Type**,
     which focuses that terminal, types the command and presses Enter.
   - Editor with a file: the agent replies with the complete corrected file; goop offers
     **Apply** (backs up first) and **Undo**. Zed and VS Code reload the file; for
     Neovim enable `autoread`.
   - Nautilus: the agent runs the command in that folder and reports the result.

## Install (Omarchy)

Prerequisites: `python3`, Hyprland, `wtype`, and (for the bundled agent) `opencode`.

```sh
omarchy plugin add https://github.com/nightdevil00/mihai.goop --enable --yes
```

Edits to the QML files reload automatically. Right-click the creature for **Settings**
or **Quit**.

## Configure agents

Configuration lives in `~/.config/goop/agents.json` (mode `0600`, since it can hold API
keys). You can edit it by hand or through the Settings window.

### Example: bundled opencode agent (CLI)

```json
{
  "active": "opencode",
  "agents": [
    {
      "id": "opencode",
      "name": "opencode",
      "type": "cli",
      "command": [
        "python3",
        "/home/$USER/.config/omarchy/plugins/mihai.goop/agents/opencode.py",
        "--model",
        "opencode-go/beam-free"
      ],
      "timeout": 290
    }
  ],
  "terminal_mode": "agent",
  "auto_apply": false,
  "dockMode": "float"
}
```

### Adding other opencode agents

The bundled `agents/opencode.py` accepts an optional `--model provider/model`. To add
another opencode agent, add another CLI agent whose command points at the same script
with a different model:

```json
{
  "id": "opencode-gpt",
  "name": "opencode (GPT)",
  "type": "cli",
  "command": [
    "python3",
    "/home/$USER/.config/omarchy/plugins/mihai.goop/agents/opencode.py",
    "--model",
    "openai/gpt-4.1"
  ],
  "timeout": 290
}
```

You can also point `command` at any program that reads `{"prompt", "context"}` on stdin
and prints its reply on stdout.

### OpenAI-compatible agent

```json
{
  "id": "openai",
  "name": "OpenAI",
  "type": "openai",
  "base_url": "https://api.openai.com/v1",
  "model": "gpt-4.1",
  "api_key": "sk-..."
}
```

### Options

- `terminal_mode`: `"agent"` (the agent runs commands in the window's folder and reports)
  or `"type"` (the agent returns a command and goop types it into the terminal).
- `auto_apply`: when true, file changes are applied automatically instead of showing
  **Apply**.
- `dockMode`: `"float"` (draggable anywhere) or `"dock"` (sticks to a window).

## Use

- **Move it:** drag the creature anywhere, across any monitor. It has no home and no leash.
- **Fast commands:** usual shell commands (`ls`, `pwd`, `clear`, `git status`, `cargo test`, …)
  and requests that are already commands are typed straight into a terminal without an agent
  round-trip. Prefix any command with `run ` or `!` to force it, or type a natural-language
  request to let the agent answer.
- **Choose a window:** drop it over the window you want. Whatever window is under the
  creature when you ask is the one the request applies to (the focused window is
  preferred).
- **Ask:** click the creature, type a request, press Enter. Escape cancels.
- **Menu:** right-click the creature for Settings or Quit.

For a terminal window, the agent may run commands in that terminal's folder. For an
editor window, the request applies to the file it shows (or a file named in the
request). A reply that contains a full corrected file appears with **Apply**. Applying
backs up the original first, and **Undo** restores it.

## Editors

- **Neovim** in a terminal: the file the Neovim process was started with. Neovim does
  not reload changed files by itself. Add `vim.opt.autoread = true` and a `FocusGained`
  autocmd that runs `:checktime`.
- **Zed** and **VS Code**: the file and project come from the window title. Both reload
  files that have no unsaved edits.
- **Nautilus**: commands run in the folder its window is showing.
- **Browser** (Chrome, Chromium, Brave, Firefox, Zen, Vivaldi, Edge, Opera): local
  commands such as `open tab`, `close tab called X`, `navigate to example.com`, and
  `search for <text>` / `find <text>` / `click <text>` / `open <name>'s profile page`,
  which find the text on the page and open the matching link.

## Checks

When the project has one of these, goop runs its checker and sends the output to the
agent: `Package.swift` (`swift build`), `Cargo.toml` (`cargo check`),
`go.mod` (`go vet ./...`), `tsconfig.json` (`tsc --noEmit`), or a Python file
(`py_compile`). The checker runs in the project folder and may write build output there.

## Files it reads and writes

| Path | Contents |
|------|----------|
| `~/.config/goop/agents.json` | Agents, default agent, tail length. Holds API keys, readable only by you. |
| `~/.local/state/goop/context/` | File snapshots sent to agents |
| `~/.local/state/goop/proposals/` | Proposed changes |
| `~/.local/state/goop/backups/` | Files as they were before Apply |

## Troubleshooting

- **"Zed shows no file"**: open a file in Zed, or name it in your request, e.g.
  `fix broken.py`.
- **Commands not appearing in the terminal**: in type mode press **Type**; in agent mode
  the agent runs them in the folder and reports the output.
- **Typed text goes to the wrong app**: typed text goes to whatever has focus inside the
  terminal (a full-screen app such as opencode takes it as its own input).

## Layout

```
manifest.json      Omarchy plugin manifest
Goop.qml           panel: the creature, the prompt, the reply bubble, the menu
GoopBlob.qml       the creature's body, face, hearts, and drag handling
GoopTab.qml        the black prompt field
GoopDock.qml       finds the window under the creature, through hyprctl
GoopAgents.qml     runs agents.py and editor.py
GoopSettings.qml   settings window
GoopField.qml, GoopButton.qml   small controls for the settings window
agents.py          agent configuration and requests
editor.py          file snapshots, checks, apply, and undo
agents/opencode.py bundled opencode agent
```
