#!/usr/bin/env python3
"""Render a Compose file's variable interpolation without a container engine.

`docker compose config` is the real renderer, but CI has no engine and the
Podman work turned several literals in the Compose files into interpolated
values -- exactly the kind of change that needs a test. This reimplements the
one Compose feature those values depend on: `${VAR}`, `${VAR:-default}`,
`${VAR-default}` and the `$$` escape, applied to values only, never to keys.

Environment comes from this process, so a caller that wants the environment a
production script exports simply runs this as that script's child.

    tests/lib/compose-render.py docker-compose.yml          # rendered JSON
    tests/lib/compose-render.py docker-compose.yml --env-file dump.env0

--env-file reads a NUL-separated `env -0` dump and uses it in place of the
inherited environment.
"""

import json
import os
import re
import sys

import yaml

NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def _resolve(body, env):
    """Resolve the inside of a ${...}, whose default may itself interpolate."""
    match = NAME.match(body)
    if not match:
        return "${" + body + "}"
    name = match.group(0)
    rest = body[match.end():]
    current = env.get(name)

    if rest == "":
        return current or ""
    for operator, unset_only in ((":-", False), ("-", True)):
        if rest.startswith(operator):
            missing = current is None if unset_only else not current
            return interpolate(rest[len(operator):], env) if missing else current
    for operator, unset_only in ((":+", False), ("+", True)):
        if rest.startswith(operator):
            present = current is not None if unset_only else bool(current)
            return interpolate(rest[len(operator):], env) if present else ""
    for operator in (":?", "?"):
        if rest.startswith(operator):
            return current or ""
    return "${" + body + "}"


def interpolate(value, env):
    """Compose's own value interpolation, including nested defaults."""
    out = []
    index = 0
    length = len(value)
    while index < length:
        char = value[index]
        if char != "$":
            out.append(char)
            index += 1
            continue
        following = value[index + 1:index + 2]
        if following == "$":
            out.append("$")
            index += 2
            continue
        if following == "{":
            cursor = index + 2
            depth = 1
            while cursor < length and depth:
                if value[cursor] == "{":
                    depth += 1
                elif value[cursor] == "}":
                    depth -= 1
                    if depth == 0:
                        break
                cursor += 1
            if depth:
                out.append(char)
                index += 1
                continue
            out.append(_resolve(value[index + 2:cursor], env))
            index = cursor + 1
            continue
        match = NAME.match(value, index + 1)
        if match:
            out.append(env.get(match.group(0), ""))
            index = match.end()
            continue
        out.append(char)
        index += 1
    return "".join(out)


def walk(node, env):
    if isinstance(node, dict):
        return {key: walk(child, env) for key, child in node.items()}
    if isinstance(node, list):
        return [walk(child, env) for child in node]
    if isinstance(node, str):
        return interpolate(node, env)
    return node


def read_env_dump(path):
    with open(path, "rb") as handle:
        raw = handle.read()
    env = {}
    for entry in raw.split(b"\0"):
        if not entry:
            continue
        name, _, value = entry.partition(b"=")
        env[name.decode("utf-8", "replace")] = value.decode("utf-8", "replace")
    return env


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    compose_file = argv[1]
    env = dict(os.environ)
    if len(argv) >= 4 and argv[2] == "--env-file":
        env = read_env_dump(argv[3])

    with open(compose_file, "r", encoding="utf-8") as handle:
        document = yaml.safe_load(handle)

    json.dump(walk(document, env), sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
