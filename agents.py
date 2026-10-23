#!/usr/bin/env python3
"""goop's agent bridge. The QML shell calls this script; it never talks to agents itself.

  agents.py config                 print the saved configuration as JSON
  agents.py save <json>            validate and store the configuration
  agents.py ask <agent-id> <json>  send {"prompt", "context_file"} to an agent (context_file is
                                   optional, written by editor.py), print
                                   {"ok", "reply", "proposal"} or {"ok": false, "error"}

Two agent types are supported:
  cli     runs "command" (a list of arguments) and writes {"prompt", "context"} as JSON to its
          stdin; the reply is whatever it prints on stdout.
  openai  calls an OpenAI-compatible chat completions endpoint at "base_url".

When the context is a file and the reply contains a fenced code block, that block is the
complete new file. It is stored as a proposal that nothing applies until the user accepts it.

The configuration lives in ~/.config/goop/agents.json, readable only by its owner,
because it can hold API keys.
"""

import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

import editor

CONFIG_PATH = os.path.expanduser("~/.config/goop/agents.json")
SYSTEM_PROMPT = (
    "You are goop, a small assistant attached to a window on the user's desktop. "
    "Answer briefly. If the user wants a file changed, first say in one or two sentences "
    "what you changed and why, then give the complete corrected file in one fenced code "
    "block, with nothing after it. Keep unchanged code exactly as it was."
)
DEFAULT_TIMEOUT = 300
FENCE = re.compile(r"```[^\n]*\n(.*?)\n?```", re.DOTALL)


def load_config():
    try:
        with open(CONFIG_PATH, encoding="utf-8") as handle:
            config = json.load(handle)
    except FileNotFoundError:
        return {"agents": []}
    config.setdefault("agents", [])
    return config


def validate(config):
    if not isinstance(config, dict) or not isinstance(config.get("agents"), list):
        raise ValueError("config needs an \"agents\" list")
    seen = set()
    for agent in config["agents"]:
        agent_id = str(agent.get("id", "")).strip()
        if not agent_id or agent_id in seen:
            raise ValueError(f"agent ids must be unique and non-empty (got {agent_id!r})")
        seen.add(agent_id)
        kind = agent.get("type")
        if kind == "cli" and not agent.get("command"):
            raise ValueError(f"{agent_id}: a CLI agent needs a command")
        if kind == "openai" and not (agent.get("base_url") and agent.get("model")):
            raise ValueError(f"{agent_id}: an OpenAI-compatible agent needs base_url and model")
        if kind not in ("cli", "openai"):
            raise ValueError(f"{agent_id}: unknown type {kind!r}")
    return config


def save_config(config):
    config = validate(config)
    directory = os.path.dirname(CONFIG_PATH)
    os.makedirs(directory, exist_ok=True)
    # Write beside the target and rename, so a crash never leaves a half-written file.
    fd, temp = tempfile.mkstemp(dir=directory, prefix=".agents-", suffix=".json")
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(config, handle, indent=2)
        handle.write("\n")
    os.chmod(temp, 0o600)
    os.replace(temp, CONFIG_PATH)


def ask_cli(agent, prompt, context):
    payload = json.dumps({"prompt": prompt, "context": context})
    result = subprocess.run(
        agent["command"],
        input=payload,
        capture_output=True,
        text=True,
        timeout=agent.get("timeout", DEFAULT_TIMEOUT),
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"exited with status {result.returncode}")
    return result.stdout.strip()


def render_context(context):
    parts = []
    if context.get("file"):
        parts.append(
            f"The user is looking at {context['relative']} "
            f"(project {context['project']}, editor {context.get('editor') or 'unknown'}):\n"
            f"```{context.get('language', '')}\n{context['content']}\n```"
        )
    diagnostics = context.get("diagnostics")
    if diagnostics:
        status = "passed" if diagnostics["ok"] else "reported errors"
        parts.append(f"`{diagnostics['tool']}` {status}:\n```\n{diagnostics['output'] or '(no output)'}\n```")
    if not context.get("file"):
        if context.get("cwd"):
            editor = context.get("editor") or "window"
            parts.append(f"The request comes from a {editor} window in {context['cwd']}.")
        elif context.get("window_title"):
            parts.append(f"The active window is titled: {context['window_title']}")
    return "\n\n".join(parts)


def load_context(path):
    if not path:
        return {}
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def ask_openai(agent, prompt, context):
    user = prompt
    rendered = render_context(context)
    if rendered:
        user += "\n\n" + rendered
    body = {
        "model": agent["model"],
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": user},
        ],
    }
    headers = {"Content-Type": "application/json"}
    if agent.get("api_key"):
        headers["Authorization"] = "Bearer " + agent["api_key"]
    url = agent["base_url"].rstrip("/") + "/chat/completions"
    request = urllib.request.Request(url, data=json.dumps(body).encode(), headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=agent.get("timeout", DEFAULT_TIMEOUT)) as response:
            data = json.load(response)
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")[:300]
        raise RuntimeError(f"HTTP {error.code}: {detail}") from error
    return data["choices"][0]["message"]["content"].strip()


def split_proposal(reply, context):
    """Pulls the complete new file out of the reply, if it has one, and stores it as a proposal."""
    matches = list(FENCE.finditer(reply))
    if not context.get("file") or not matches:
        return reply, ""
    last = matches[-1]
    content = last.group(1)
    if not content.endswith("\n"):
        content += "\n"
    explanation = (reply[:last.start()] + reply[last.end():]).strip()
    if content.rstrip("\n") == context["content"].rstrip("\n"):
        return explanation or "No change is needed.", ""
    path = editor.save_proposal(context["file"], context["base_sha256"], content, explanation)
    return explanation or "Here is a proposed change.", path


def ask(agent_id, request):
    agent = next((a for a in load_config()["agents"] if a["id"] == agent_id), None)
    if agent is None:
        raise RuntimeError(f"no agent called {agent_id!r}")
    prompt = request.get("prompt", "").strip()
    if not prompt:
        raise RuntimeError("empty prompt")
    context = load_context(request.get("context_file", ""))
    if agent["type"] == "cli":
        reply = ask_cli(agent, prompt, context)
    else:
        reply = ask_openai(agent, prompt, context)
    text, proposal = split_proposal(reply, context)
    return {"reply": text, "proposal": proposal}


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    command = argv[1]
    try:
        if command == "config":
            print(json.dumps(load_config(), indent=2))
        elif command == "save":
            save_config(json.loads(argv[2]))
            print(json.dumps({"ok": True}))
        elif command == "ask":
            print(json.dumps({"ok": True, **ask(argv[2], json.loads(argv[3]))}))
        else:
            print(f"unknown command {command!r}", file=sys.stderr)
            return 2
    except Exception as error:
        if command == "ask":
            print(json.dumps({"ok": False, "error": str(error)}))
            return 0
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
