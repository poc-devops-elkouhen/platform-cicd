#!/usr/bin/env python3
import os
import sys
import urllib.request
import yaml

disabled_resource_names = {
    "argocd-notifications-cm",
    "argocd-notifications-controller",
    "argocd-notifications-secret",
}

if len(sys.argv) < 2:
    print(f"Usage: {sys.argv[0]} <file-or-url>", file=sys.stderr)
    sys.exit(1)

source = sys.argv[1]

if os.path.exists(source):
    with open(source) as f:
        manifest = f.read()
else:
    with urllib.request.urlopen(source) as f:
        manifest = f.read().decode()

resources = [
    r for r in yaml.safe_load_all(manifest)
    if r is not None and not (
        isinstance(r, dict)
        and r.get("metadata", {}).get("name") in disabled_resource_names
    )
]

print(yaml.dump_all(resources, default_flow_style=False, allow_unicode=True), end="")
