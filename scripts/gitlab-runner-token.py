#!/usr/bin/env python3
# Crée un token d'authentification de runner d'instance via l'API GitLab et le
# stocke dans le Secret K8s effectivement monté par le chart GitLab Runner
# (`gitlab-gitlab-runner-secret`). Idempotent : ne fait rien si le Secret
# existe déjà avec un runner-token non vide.
import base64
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

GITLAB_NAMESPACE = os.environ.get("GITLAB_NAMESPACE", "gitlab")
GITLAB_URL = os.environ.get("GITLAB_URL", "https://gitlab.192.168.33.100.nip.io")
SECRET_NAME = os.environ.get("SECRET_NAME", "gitlab-gitlab-runner-secret")


def kube_secret_field(namespace, name, jsonpath):
    raw = subprocess.run(
        ["kubectl", "-n", namespace, "get", "secret", name, "-o", f"jsonpath={jsonpath}"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    return base64.b64decode(raw).decode() if raw else ""


def gitlab_post(path, data, token=None):
    headers = {"Content-Type": "application/x-www-form-urlencoded"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(
        f"{GITLAB_URL}{path}",
        data=urllib.parse.urlencode(data).encode(),
        headers=headers,
        method="POST",
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())


def kube_apply(cmd):
    proc = subprocess.run(cmd, capture_output=True, check=True)
    subprocess.run(["kubectl", "apply", "-f", "-"], input=proc.stdout, check=True)


# Idempotence : vérifier si le secret existe déjà avec un token non vide
exists = subprocess.run(
    ["kubectl", "-n", GITLAB_NAMESPACE, "get", "secret", SECRET_NAME],
    capture_output=True,
).returncode == 0

if exists:
    existing_token = kube_secret_field(GITLAB_NAMESPACE, SECRET_NAME, "{.data.runner-token}")
    if existing_token:
        print(f"Secret '{SECRET_NAME}' déjà présent dans '{GITLAB_NAMESPACE}' avec un runner-token, rien à faire.")
        sys.exit(0)

root_password = kube_secret_field(
    GITLAB_NAMESPACE, "gitlab-gitlab-initial-root-password", "{.data.password}"
)

auth = gitlab_post("/oauth/token", {
    "grant_type": "password",
    "username": "root",
    "password": root_password,
})
bearer_token = auth.get("access_token", "")
if not bearer_token or bearer_token == "null":
    print("Échec d'authentification à l'API GitLab", file=sys.stderr)
    sys.exit(1)

runner = gitlab_post("/api/v4/user/runners", {
    "runner_type": "instance_type",
    "description": "k3d-poc-devops",
}, token=bearer_token)
runner_token = runner.get("token", "")
if not runner_token or runner_token == "null":
    print("Échec de création du runner d'instance", file=sys.stderr)
    sys.exit(1)

kube_apply([
    "kubectl", "-n", GITLAB_NAMESPACE, "create", "secret", "generic", SECRET_NAME,
    "--from-literal=runner-registration-token=",
    f"--from-literal=runner-token={runner_token}",
    "--dry-run=client", "-o", "yaml",
])
print(f"Secret '{SECRET_NAME}' créé avec un nouveau token d'instance runner.")
