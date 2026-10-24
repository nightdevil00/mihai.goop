# goop: how requests are handled

goop sends each request to the agent with the rules below. In type mode the agent cannot run
commands or change files itself; goop does those steps only after the user presses a button.
In agent mode the agent may run commands in the window's folder.

## When the creature is over a terminal window

- The agent replies with a short explanation and one shell command in a fenced `sh` block.
- goop shows the command with **Type** and **Discard**.
- **Type** focuses that terminal window, types the command, and presses Enter.
- A request that starts with `run ` or `!` skips the agent and types the rest right away.
- `open <app>`, `launch <app>`, and `start <app>` launch an application directly (for example
  `open nautilus`, `open foot`), with no agent round-trip. URLs are not treated as apps.
- Common, already-command-like requests (such as `ls`, `pwd`, `clear`, `git status`, or any
  command whose first word is a usual shell command) are typed straight into the terminal
  without an agent round-trip, so goop answers them instantly. Natural-language requests
  still go to the agent.

## When the creature is over an editor window with a file

- The agent replies with a short explanation and the complete corrected file in one fenced block.
- goop shows **Apply** and **Discard** (or applies it at once when auto-apply is on).
- **Apply** backs up the file first, then writes the new version. **Undo** restores the backup.
- If the file changed since goop read it, Apply refuses.
- Zed and VS Code reload the file themselves; for Neovim, enable autoread.

## When the creature is over a browser window

- Recognised requests are handled locally: `open tab`, `new window`, `reload`, `back`,
  `forward`, `close tab`, `close tab called <name>`, `switch to tab <name>`,
  `navigate to <url>` / `open <url>`, and `search for <text>` / `find <text>` /
  `click <text>` / `open <name>'s profile page`, which find the text on the page and
  open the matching link.
- Other requests are sent to the agent with the window title as context.

## Media controls (any window)

- `play`, `pause`, `resume`, `stop`, and `play/pause` (or `toggle`) control the current
  media player through Omarchy's media service, with no agent round-trip.

## When the creature is over a Nautilus window

- The agent runs the requested command in the folder Nautilus is showing and reports the result.
- No typing is involved; the folder is detected from the window title.

## Limits

- Typed text goes to whichever application has focus inside the terminal. A full-screen app
  such as opencode takes the text as its own input.
- Commands are never typed without a Type press. In agent mode, or for Nautilus folders, the
  agent runs them itself in the window's folder and reports the result.
