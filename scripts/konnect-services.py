#!/usr/bin/env python3
"""Build isolated API configurations and deploy a validated batch sequentially."""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

import yaml

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / "build" / "deploy"
SERVICE_NAME = re.compile(r"[a-z][a-z0-9]*(?:-[a-z0-9]+)*")
ENVIRONMENTS = ("development", "staging", "production")


def valid_service(name):
    return isinstance(name, str) and name != "all" and bool(SERVICE_NAME.fullmatch(name))


def discover(selector):
    names = sorted(p.parent.name for p in (ROOT / "apis").glob("*/openapi.yaml"))
    if not names or any(not valid_service(name) for name in names):
        raise ValueError("Add apis/<service>/openapi.yaml; folder names must use lowercase letters, digits and hyphens.")
    if selector == "all":
        return names
    if selector not in names:
        raise ValueError(f"Unknown service {selector!r}. Choose all or one of: {', '.join(names)}")
    return [selector]


def run(*args, env=None):
    subprocess.run(args, cwd=ROOT, env=env, check=True)


def build(selector, environment):
    names = discover(selector)
    BUNDLE.mkdir(parents=True, exist_ok=True)
    # An unsuccessful local rebuild must not leave a deployable old manifest.
    (BUNDLE / "manifest.json").unlink(missing_ok=True)
    entries = []
    for name in names:
        print(f"Building {name}", flush=True)
        run("bash", "scripts/build-konnect-api.sh", name, environment)
        target = BUNDLE / name / "kong.yaml"
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / "build" / environment / name / "kong.yaml", target)
        entries.append({"service": name, "tag": f"api:{name}-api", "file": f"{name}/kong.yaml"})
    manifest = {"version": 2, "environment": environment, "services": entries}
    (BUNDLE / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Prepared {len(entries)} service(s): {', '.join(names)}", flush=True)


def load_entries(environment):
    manifest = json.loads((BUNDLE / "manifest.json").read_text())
    entries = manifest.get("services")
    if manifest.get("version") != 2 or not isinstance(entries, list) or not entries:
        raise ValueError("Invalid or empty deployment manifest; build the selected services again.")
    if manifest.get("environment") != environment:
        raise ValueError("The built configuration belongs to another environment; build the requested environment again.")
    seen = set()
    for entry in entries:
        name = entry.get("service")
        if not valid_service(name) or name in seen:
            raise ValueError("Invalid or duplicate service in deployment manifest.")
        if entry.get("tag") != f"api:{name}-api" or entry.get("file") != f"{name}/kong.yaml":
            raise ValueError(f"Unexpected file or ownership tag for {name}.")
        if not (BUNDLE / entry["file"]).is_file():
            raise ValueError(f"Missing configuration for {name}.")
        seen.add(name)
    return entries


def deployment_settings(entries):
    settings = []
    for entry in entries:
        name = entry["service"]
        state = BUNDLE / entry["file"]
        contents = state.read_text()
        if "${{" in contents:
            raise ValueError(f"Set literal values in the gateway configuration for {name}; runtime placeholders are not supported.")
        config = yaml.safe_load(contents)
        control_plane = config.get("_konnect", {}).get("control_plane_name")
        if (not isinstance(control_plane, str) or not control_plane.strip()
                or control_plane.startswith("replace-with-")):
            raise ValueError(f"Set the actual control_plane_name in the gateway configuration for {name}.")
        services = config.get("services")
        if not isinstance(services, list) or not services:
            raise ValueError(f"No Gateway Service configuration found for {name}.")
        for service in services:
            host = service.get("host")
            if (not isinstance(host, str) or not host or len(host) > 253
                    or any(not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label)
                           for label in host.split("."))
                    or host.lower() == "example.com" or host.lower().endswith(".example.com")):
                raise ValueError(f"Set the actual upstream host in the gateway configuration for {name}, without scheme, port, or path.")
        settings.append((entry, str(state), control_plane))
    return settings


def summary(message):
    print(message, flush=True)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as stream:
            stream.write(message + "\n")


def deploy(operation, environment):
    entries = load_entries(environment)
    if not os.environ.get("DECK_KONNECT_TOKEN", "").strip():
        raise ValueError("Set the KONNECT_TOKEN GitHub secret.")
    settings = deployment_settings(entries)  # Check all static settings before contacting Konnect.
    base_env = dict(os.environ, DECK_KONNECT_ADDR="https://us.api.konghq.com", DECK_ANALYTICS="false")
    prepared = []
    connected = set()
    # Validate and preview the whole batch before any service is synchronized.
    for entry, state, control_plane in settings:
        name = entry["service"]
        scope = ["--select-tag", entry["tag"], "--skip-consumers"]
        env = dict(base_env, DECK_KONNECT_CONTROL_PLANE_NAME=control_plane)
        if control_plane not in connected:
            run("deck", "gateway", "ping", env=env)
            connected.add(control_plane)
        print(f"Validating and previewing {name}", flush=True)
        run("deck", "file", "validate", state, "--konnect-compatibility", env=env)
        run("deck", "gateway", "validate", state, "--konnect-compatibility", env=env)
        run("deck", "gateway", "diff", state, *scope, env=env)
        prepared.append((name, state, scope, env))
    if operation == "plan":
        summary(f"Plan complete for {len(entries)} service(s). No configuration was changed.")
        return
    for name, state, scope, env in prepared:
        print(f"Deploying {name}", flush=True)
        run("deck", "gateway", "sync", state, *scope, "--yes", env=env)
        run("deck", "gateway", "diff", state, *scope, "--non-zero-exit-code", env=env)
        summary(f"Deployed {name}; no remaining configuration drift.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    builder = commands.add_parser("build")
    builder.add_argument("--service", default="all", help="Service folder name or all")
    builder.add_argument("--environment", choices=ENVIRONMENTS, default="development")
    deployer = commands.add_parser("deploy")
    deployer.add_argument("--operation", choices=["plan", "deploy"], default="plan")
    deployer.add_argument("--environment", choices=ENVIRONMENTS, default="development")
    args = parser.parse_args()
    try:
        if args.command == "build":
            build(args.service, args.environment)
        else:
            deploy(args.operation, args.environment)
    except (ValueError, OSError, yaml.YAMLError, subprocess.CalledProcessError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
