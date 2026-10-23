#!/usr/bin/env python3
"""goop agent for opencode. Reads {"prompt", "context"} on stdin and prints the reply.

opencode never runs commands or edits files itself. From a terminal it replies with
the one shell command to run, in a fenced block; goop types it into the terminal only
after the user presses Type. From an editor file it returns the complete corrected file
in a fenced block; goop applies it only after the user presses Apply.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile

TIMEOUT = 290
DENY = {"permission": {"edit": "deny", "bash": "deny"}}
FILES_ONLY_DENY = {"permission": {"edit": "deny"}}
FILE_RULES = (
    "Do not edit files or run commands. Explain the fix in one or two sentences, then give "
    "the complete corrected file in one fenced code block, with nothing after it."
)
TYPE_RULES = (
    "Do not run commands; you cannot. Reply with one or two sentences saying what the command does, "
    "then the single shell command to run, in one fenced ```sh block, with nothing after it."
)
AGENT_RULES = (
    "Run the command the user asks for in this directory, with your shell tool. Then reply with one "
    "or two sentences saying what you ran and what it showed."
)
CONFIG_PATH = os.path.expanduser("~/.config/goop/agents.json")


def terminal_mode():
    try:
        with open(CONFIG_PATH, encoding="utf-8") as handle:
            return json.load(handle).get("terminal_mode", "type")
    except (OSError, ValueError):
        return "type"


def fail(message):
    print(message, file=sys.stderr)
    sys.exit(1)


def find_opencode():
    # The shell that starts goop may not have the mise install directory on PATH.
    found = shutil.which("opencode")
    if found:
        return found
    fallback = os.path.expanduser("~/.local/share/mise/installs/opencode/latest/node_modules/.bin/opencode")
    if os.path.exists(fallback):
        return fallback
    fail("opencode is not installed or not on PATH")


def diagnostics_text(diagnostics):
    if not diagnostics:
        return ""
    status = "passed" if diagnostics["ok"] else "reported errors"
    return f"`{diagnostics['tool']}` {status}:\n```\n{diagnostics['output'] or '(no output)'}\n```"


def main():
    # `opencode.py [--model provider/model]`; without it, opencode uses its own default model.
    model = []
    if len(sys.argv) == 3 and sys.argv[1] == "--model":
        model = ["--model", sys.argv[2]]
    elif len(sys.argv) > 1:
        fail("usage: opencode.py [--model provider/model]")
    request = json.load(sys.stdin)
    prompt = request.get("prompt", "").strip()
    context = request.get("context") or {}
    if not prompt:
        fail("empty prompt")

    message = [prompt]
    attachments = []
    # Nautilus has no shell to type into, so commands there always run in the shown folder.
    # Terminals honour the user's "agent runs them / I type them" setting.
    is_nautilus = context.get("editor") == "nautilus"
    may_run = not context.get("file") and (is_nautilus or terminal_mode() == "agent")
    env = dict(os.environ)
    env["OPENCODE_CONFIG_CONTENT"] = json.dumps(FILES_ONLY_DENY if may_run else DENY)
    if context.get("file"):
        cwd = context.get("project") or os.path.dirname(context["file"])
        temp = tempfile.NamedTemporaryFile("w", suffix="-" + os.path.basename(context["file"]),
                                           delete=False, encoding="utf-8")
        temp.write(context["content"])
        temp.close()
        attachments = ["--file", temp.name]
        message.append(f"The file is {context['relative']} (attached as {os.path.basename(context['file'])}).")
        diagnostics = diagnostics_text(context.get("diagnostics"))
        if diagnostics:
            message.append(diagnostics)
        message.append(FILE_RULES)
    else:
        cwd = context.get("cwd") or os.path.expanduser("~")
        if context.get("editor") == "nautilus":
            message.append(f"The request comes from a Nautilus window showing the folder {cwd}.")
        else:
            message.append(f"The request comes from a terminal in {cwd}.")
        message.append(AGENT_RULES if may_run else TYPE_RULES)

    command = [find_opencode(), "run", "--standalone", "--auto", "--format", "json", *model, *attachments,
               "\n\n".join(message)]
    try:
        result = subprocess.run(command, cwd=cwd, env=env, capture_output=True, text=True, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        fail("opencode took too long to answer")

    texts = []
    for line in result.stdout.splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if event.get("type") == "error":
            fail(event.get("error", {}).get("message", "opencode reported an error"))
        if event.get("type") == "text":
            texts.append(event.get("part", {}).get("text", ""))
    reply = "".join(texts).strip()
    if result.returncode != 0 or not reply:
        detail = result.stderr.strip().splitlines()[-1:] or ["opencode returned no answer"]
        fail(detail[0])
    print(reply)


if __name__ == "__main__":
    main()
