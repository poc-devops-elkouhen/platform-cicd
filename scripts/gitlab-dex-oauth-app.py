#!/usr/bin/env python3
import json
import os
import ssl
import subprocess
import urllib.parse
import urllib.request


GITLAB_NAMESPACE = os.environ.get("GITLAB_NAMESPACE", "gitlab")
ARGOCD_NAMESPACE = os.environ.get("ARGOCD_NAMESPACE", "argocd")
GITLAB_URL = os.environ.get("GITLAB_URL", "https://gitlab.192.168.33.100.nip.io").rstrip("/")
ARGOCD_URL = os.environ.get("ARGOCD_URL", "https://argocd.192.168.33.100.nip.io").rstrip("/")
TLS_VERIFY = os.environ.get("GITLAB_TLS_VERIFY", "false").lower() not in ("0", "false", "no")


def kube_secret_field(namespace, name, jsonpath):
    return subprocess.check_output(
        ["kubectl", "-n", namespace, "get", "secret", name, "-o", f"jsonpath={jsonpath}"],
        text=True,
    )


def has_argocd_dex_secret():
    try:
        return bool(kube_secret_field(ARGOCD_NAMESPACE, "argocd-secret", "{.data.dex\\.gitlab\\.clientID}"))
    except subprocess.CalledProcessError:
        return False


def http_post(path, data, token=None):
    body = urllib.parse.urlencode(data).encode()
    headers = {"Content-Type": "application/x-www-form-urlencoded"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(f"{GITLAB_URL}{path}", data=body, headers=headers)
    context = None if TLS_VERIFY else ssl._create_unverified_context()
    with urllib.request.urlopen(request, context=context, timeout=30) as response:
        return json.load(response)


def patch_argocd_secret(client_id, client_secret):
    patch = {
        "stringData": {
            "dex.gitlab.clientID": client_id,
            "dex.gitlab.clientSecret": client_secret,
        }
    }
    subprocess.run(
        [
            "kubectl",
            "-n",
            ARGOCD_NAMESPACE,
            "patch",
            "secret",
            "argocd-secret",
            "--type",
            "merge",
            "-p",
            json.dumps(patch),
        ],
        check=True,
    )


def main():
    if has_argocd_dex_secret():
        print("argocd-secret contient deja dex.gitlab.clientID, skip.")
        return

    encoded_password = kube_secret_field(
        GITLAB_NAMESPACE,
        "gitlab-gitlab-initial-root-password",
        "{.data.password}",
    )
    password = subprocess.check_output(["base64", "-d"], input=encoded_password, text=True)

    auth = http_post("/oauth/token", {
        "grant_type": "password",
        "username": "root",
        "password": password,
    })

    app = http_post("/api/v4/applications", {
        "name": "ArgoCD Dex",
        "redirect_uri": f"{ARGOCD_URL}/api/dex/callback",
        "scopes": "openid profile email read_user",
        "confidential": "true",
        "trusted": "true",
    }, token=auth["access_token"])

    patch_argocd_secret(app["application_id"], app["secret"])
    print(f"Application OAuth GitLab creee pour Dex: id={app['id']}")


if __name__ == "__main__":
    main()
