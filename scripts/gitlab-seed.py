#!/usr/bin/env python3
# Seed GitLab depuis l'inventaire argocd/apps.yaml + argocd/apps/*.yaml :
# - root/ci-templates, tagué en version immuable pour les includes CI ;
# - root/<app>-iac et root/<app>, dépôts manifests/code par app -- pour ces
#   deux-là, sourceDir est un dépôt git réel (cf. AGENTS.md), poussé via un
#   remote "gitlab" dédié pour préserver son historique (pas de copie/réinit) ;
#   le code reçoit en plus un .gitlab-ci.yml généré depuis le template.
import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from datetime import date
from pathlib import Path

from platform_inventory import load_inventory

GITLAB_NAMESPACE = os.environ.get("GITLAB_NAMESPACE", "gitlab")
GITLAB_URL = os.environ.get("GITLAB_URL", "http://gitlab.192.168.33.100.nip.io")
GITLAB_ROOT_NAMESPACE = os.environ.get("GITLAB_ROOT_NAMESPACE", "root")
GITLAB_REMOTE_NAME = os.environ.get("GITLAB_REMOTE_NAME", "gitlab")
REPO_ROOT = Path(__file__).parent.parent.resolve()
APPS_FILE = Path(os.environ.get("APPS_FILE", REPO_ROOT / "argocd/apps.yaml"))
inventory = load_inventory(APPS_FILE)


def yaml_value(dotted_key):
    obj = inventory
    for key in dotted_key.split("."):
        obj = obj[key]
    return obj


CI_TEMPLATE_PROJECT_PATH = os.environ.get("CI_TEMPLATE_PROJECT_PATH") or yaml_value("ciTemplate.projectPath")
CI_TEMPLATE_PROJECT_NAME = os.environ.get("CI_TEMPLATE_PROJECT_NAME") or yaml_value("ciTemplate.projectName")
CI_TEMPLATE_SOURCE_DIR = Path(
    os.environ.get("CI_TEMPLATE_SOURCE_DIR") or REPO_ROOT / yaml_value("ciTemplate.sourceDir")
)
CI_TEMPLATE_REF = os.environ.get("CI_TEMPLATE_REF") or yaml_value("ciTemplate.ref")
CI_TEMPLATE_FILE = os.environ.get("CI_TEMPLATE_FILE") or yaml_value("ciTemplate.file")
REGISTRY_HOST = os.environ.get("REGISTRY_HOST", "registry.registry.svc.cluster.local:5000")
INTERNAL_GITLAB_HOST = os.environ.get("INTERNAL_GITLAB_HOST") or yaml_value("gitlab.internalHost")
DOMAIN = os.environ.get("DOMAIN") or yaml_value("platform.domain")
CI_SCRIPTS_SRC_DIR = Path(
    os.environ.get("CI_SCRIPTS_SRC_DIR") or REPO_ROOT / yaml_value("ciTemplate.sourceDir")
)


def kube_secret_field(namespace, name, jsonpath):
    raw = subprocess.run(
        ["kubectl", "-n", namespace, "get", "secret", name, "-o", f"jsonpath={jsonpath}"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    return base64.b64decode(raw).decode() if raw else ""


def http(url, method="GET", data=None, token=None):
    headers = {}
    body = None
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if data is not None:
        body = urllib.parse.urlencode(data).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, json.loads(resp.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, {}


def encode_path(value):
    return urllib.parse.quote(value, safe="")


def ensure_project(project_path, project_name):
    """Crée le projet s'il n'existe pas. Retourne (empty_repo, project_id)."""
    status, project = http(
        f"{GITLAB_URL}/api/v4/projects/{encode_path(project_path)}",
        token=bearer_token,
    )
    if status == 200 and project.get("id"):
        return project.get("empty_repo") is True, project["id"]

    print(f"Projet '{project_path}' absent, création...", file=sys.stderr)
    _, project = http(
        f"{GITLAB_URL}/api/v4/projects",
        method="POST",
        token=bearer_token,
        data={
            "name": project_name,
            "visibility": "private",
            "initialize_with_readme": "false",
        },
    )
    return True, project["id"]


def seed_project_from_dir(project_path, source_dir):
    """Pousse un snapshot (sans historique) d'un répertoire local vers GitLab."""
    print(f"Poussée du contenu initial de '{source_dir}' vers '{project_path}'...")
    gitlab_scheme, gitlab_host = GITLAB_URL.split("://", 1)
    encoded_password = urllib.parse.quote(root_password, safe="")
    remote_url = f"{gitlab_scheme}://root:{encoded_password}@{gitlab_host}/{project_path}.git"

    with tempfile.TemporaryDirectory() as workdir:
        shutil.copytree(source_dir, workdir, dirs_exist_ok=True)
        shutil.rmtree(os.path.join(workdir, ".venv"), ignore_errors=True)
        shutil.rmtree(os.path.join(workdir, ".git"), ignore_errors=True)
        subprocess.run(["git", "-C", workdir, "init", "-q", "-b", "main"], check=True)
        subprocess.run(["git", "-C", workdir, "config", "user.email", "bootstrap@gitlab.local"], check=True)
        subprocess.run(["git", "-C", workdir, "config", "user.name", "GitLab Bootstrap"], check=True)
        subprocess.run(["git", "-C", workdir, "add", "-A"], check=True)
        subprocess.run(["git", "-C", workdir, "commit", "-q", "-m", f"chore: seed initial du projet {project_path}"], check=True)
        subprocess.run(["git", "-C", workdir, "remote", "add", "origin", remote_url], check=True)
        subprocess.run(["git", "-C", workdir, "push", "-q", "origin", "main"], check=True)

    print(f"Contenu initial poussé sur 'main' de '{project_path}'.")


def seed_project_from_repo(project_path, repo_dir):
    """Pousse l'historique git réel d'un dépôt local vers GitLab via un remote nommé dédié.

    Préserve l'historique de développement. Le token passe par un header HTTP
    à la volée (-c http.extraheader) pour ne jamais persister le mot de passe
    root dans le remote du dépôt réel.
    """
    remote_url = f"{GITLAB_URL}/{project_path}.git"
    print(f"Poussée de l'historique de '{repo_dir}' vers '{project_path}' (remote '{GITLAB_REMOTE_NAME}')...")

    existing = subprocess.run(
        ["git", "-C", str(repo_dir), "remote", "get-url", GITLAB_REMOTE_NAME],
        capture_output=True,
    )
    if existing.returncode == 0:
        subprocess.run(["git", "-C", str(repo_dir), "remote", "set-url", GITLAB_REMOTE_NAME, remote_url], check=True)
    else:
        subprocess.run(["git", "-C", str(repo_dir), "remote", "add", GITLAB_REMOTE_NAME, remote_url], check=True)

    branches = subprocess.run(
        ["git", "-C", str(repo_dir), "for-each-ref", "--format=%(refname:short)", "refs/heads/"],
        capture_output=True, text=True, check=True,
    ).stdout.strip().splitlines()

    for branch in branches:
        subprocess.run(
            ["git", "-C", str(repo_dir), "-c", f"http.extraheader={git_auth_header}",
             "push", "-q", GITLAB_REMOTE_NAME, f"refs/heads/{branch}:refs/heads/{branch}"],
            check=True,
        )
    print(f"Historique de '{repo_dir}' poussé vers '{project_path}'.")


def seed_repo_branches_from_ref(project_path, repo_dir, source_ref, branches):
    """Pousse des branches d'environnement depuis une ref source."""
    print(f"Poussée des branches '{branches}' de '{repo_dir}' vers '{project_path}' depuis '{source_ref}'...")
    for branch in branches.split():
        subprocess.run(
            ["git", "-C", str(repo_dir), "-c", f"http.extraheader={git_auth_header}",
             "push", "-q", GITLAB_REMOTE_NAME, f"refs/heads/{source_ref}:refs/heads/{branch}"],
            check=True,
        )
    print(f"Branches '{branches}' disponibles dans '{project_path}'.")


def unprotect_main_branch(project_id):
    http(
        f"{GITLAB_URL}/api/v4/projects/{project_id}/protected_branches/main",
        method="DELETE",
        token=bearer_token,
    )


def configure_main_gate(project_id, push_access_level=0):
    print(f"Configuration du gate sur la branche 'main' (push_access_level={push_access_level}, merge réservé aux Maintainers)...")
    unprotect_main_branch(project_id)
    http(
        f"{GITLAB_URL}/api/v4/projects/{project_id}/protected_branches",
        method="POST",
        token=bearer_token,
        data={
            "name": "main",
            "push_access_level": push_access_level,
            "merge_access_level": 40,
            "allow_force_push": "false",
        },
    )
    http(
        f"{GITLAB_URL}/api/v4/projects/{project_id}",
        method="PUT",
        token=bearer_token,
        data={"only_allow_merge_if_all_discussions_are_resolved": "true"},
    )
    print("Gate configuré sur 'main'.")


def configure_protected_environment(project_id, environment_name, access_level=40):
    print(f"Configuration du protected environment '{environment_name}' (deploy réservé aux Maintainers)...")
    http(
        f"{GITLAB_URL}/api/v4/projects/{project_id}/protected_environments/{environment_name}",
        method="DELETE",
        token=bearer_token,
    )
    status, _ = http(
        f"{GITLAB_URL}/api/v4/projects/{project_id}/protected_environments",
        method="POST",
        token=bearer_token,
        data={
            "name": environment_name,
            "deploy_access_levels[][access_level]": access_level,
        },
    )
    if not (200 <= status < 300):
        print(f"Protected environment '{environment_name}' non configuré (HTTP {status})", file=sys.stderr)
        return
    print(f"Protected environment '{environment_name}' configuré.")


def ensure_repository_file(project_id, file_path, local_file, commit_message):
    encoded = encode_path(file_path)
    local_content = Path(local_file).read_bytes()
    raw_url = f"{GITLAB_URL}/api/v4/projects/{project_id}/repository/files/{encoded}/raw?ref=main"
    files_url = f"{GITLAB_URL}/api/v4/projects/{project_id}/repository/files/{encoded}"

    try:
        req = urllib.request.Request(raw_url, headers={"Authorization": f"Bearer {bearer_token}"})
        with urllib.request.urlopen(req) as resp:
            current_content = resp.read()
        if current_content == local_content:
            print(f"Fichier '{file_path}' déjà à jour dans le projet {project_id}.")
            return
        print(f"Mise à jour de '{file_path}' dans le projet {project_id}...")
        http(files_url, method="PUT", token=bearer_token, data={
            "branch": "main",
            "commit_message": commit_message,
            "content": local_content.decode(),
        })
    except urllib.error.HTTPError as e:
        if e.code != 404:
            raise
        print(f"Création de '{file_path}' dans le projet {project_id}...")
        http(files_url, method="POST", token=bearer_token, data={
            "branch": "main",
            "commit_message": commit_message,
            "content": local_content.decode(),
        })


def ensure_repository_file_on_main_with_gate(project_id, file_path, local_file, commit_message, push_access_level):
    unprotect_main_branch(project_id)
    try:
        ensure_repository_file(project_id, file_path, local_file, commit_message)
    finally:
        configure_main_gate(project_id, push_access_level)


def ensure_project_tag(project_id, tag_name, ref):
    status, _ = http(
        f"{GITLAB_URL}/api/v4/projects/{project_id}/repository/tags/{tag_name}",
        token=bearer_token,
    )
    if status == 200:
        print(f"Tag '{tag_name}' déjà présent.")
        return
    print(f"Création du tag '{tag_name}' sur '{ref}'...")
    http(
        f"{GITLAB_URL}/api/v4/projects/{project_id}/repository/tags",
        method="POST",
        token=bearer_token,
        data={"tag_name": tag_name, "ref": ref},
    )


def ensure_push_token_variable(project_id, label):
    status, _ = http(
        f"{GITLAB_URL}/api/v4/projects/{project_id}/variables/GITLAB_PUSH_TOKEN",
        token=bearer_token,
    )
    if status == 200:
        print("Variable CI/CD 'GITLAB_PUSH_TOKEN' déjà présente.")
        return

    print(f"Variable CI/CD 'GITLAB_PUSH_TOKEN' absente pour '{label}', génération d'un token root et création...")
    _, user = http(f"{GITLAB_URL}/api/v4/user", token=bearer_token)
    root_user_id = user["id"]

    today = date.today()
    try:
        expires_at = today.replace(year=today.year + 1).strftime("%Y-%m-%d")
    except ValueError:
        expires_at = today.replace(year=today.year + 1, day=28).strftime("%Y-%m-%d")

    _, token_data = http(
        f"{GITLAB_URL}/api/v4/users/{root_user_id}/personal_access_tokens",
        method="POST",
        token=bearer_token,
        data={
            "name": f"ci-push-{label}",
            "scopes[]": "api",
            "expires_at": expires_at,
        },
    )
    http(
        f"{GITLAB_URL}/api/v4/projects/{project_id}/variables",
        method="POST",
        token=bearer_token,
        data={
            "key": "GITLAB_PUSH_TOKEN",
            "value": token_data.get("token", ""),
            "masked": "true",
            "protected": "false",
        },
    )
    print("Variable CI/CD 'GITLAB_PUSH_TOKEN' créée.")


def render_app_ci(app_name, services, showcase_service, internal_gitlab_host,
                  manifests_project_path, manifests_path, has_preprod, domain, out_path):
    Path(out_path).write_text(
        f"include:\n"
        f"  - project: {CI_TEMPLATE_PROJECT_PATH}\n"
        f"    ref: {CI_TEMPLATE_REF}\n"
        f"    file: {CI_TEMPLATE_FILE}\n"
        f"\n"
        f"variables:\n"
        f"  APP_NAME: {app_name}\n"
        f"  # Monorepo multi-services : liste \"<service>=<image>\" espacée.\n"
        f"  # SERVICE_NAME est le service vitrine pour l'URL des environnements.\n"
        f'  SERVICES: "{services}"\n'
        f"  SERVICE_NAME: {showcase_service}\n"
        f"  DOMAIN: {domain}\n"
        f"  INTERNAL_GITLAB_HOST: {internal_gitlab_host}\n"
        f"  MANIFESTS_PROJECT_PATH: {manifests_project_path}\n"
        f"  MANIFESTS_PATH: {manifests_path}\n"
        f'  HAS_PREPROD: "{has_preprod}"\n'
    )


def render_app_ci_local(out_path: Path) -> None:
    """Génère .gitlab-ci-local.yml pour l'exécution locale des jobs CI."""
    ci_template_dir_name = CI_SCRIPTS_SRC_DIR.resolve().name
    domain = DOMAIN
    external_gitlab_host = f"gitlab.{domain}"
    out_path.write_text(
        f"# Surcharges pour gitlab-ci-local (https://github.com/firecow/gitlab-ci-local).\n"
        f"# Ce fichier est commitable — il utilise un chemin relatif conventionnel.\n"
        f"# Les secrets vont dans .gitlab-ci-local-secrets.yml (gitignore).\n"
        f"#\n"
        f"# Prérequis : {ci_template_dir_name} doit être un dossier voisin :\n"
        f"#   ../{ci_template_dir_name}/\n"
        f"\n"
        f"volumes:\n"
        f"  # Monte les scripts Python du template CI sans avoir à les cloner depuis GitLab.\n"
        f"  - ../{ci_template_dir_name}:/ci-scripts:ro\n"
        f"\n"
        f"variables:\n"
        f"  CI_SCRIPTS_DIR: /ci-scripts\n"
        f"  # En local, GitLab est accessible via l'adresse externe (pas l'URL in-cluster).\n"
        f"  INTERNAL_GITLAB_HOST: {external_gitlab_host}\n"
        f"  DOMAIN: {domain}\n"
        f"  # SHA court par défaut pour les jobs deploy-dev en local.\n"
        f"  CI_COMMIT_SHORT_SHA: local\n"
    )


# ── Authentification ────────────────────────────────────────────────────────

root_password = kube_secret_field(
    GITLAB_NAMESPACE, "gitlab-gitlab-initial-root-password", "{.data.password}"
)

_, auth = http(f"{GITLAB_URL}/oauth/token", method="POST", data={
    "grant_type": "password",
    "username": "root",
    "password": root_password,
})
bearer_token = auth.get("access_token", "")
if not bearer_token or bearer_token == "null":
    print("Échec d'authentification à l'API GitLab", file=sys.stderr)
    sys.exit(1)

credentials = base64.b64encode(f"oauth2:{bearer_token}".encode()).decode()
git_auth_header = f"Authorization: Basic {credentials}"

# ── Template CI ─────────────────────────────────────────────────────────────

ci_template_empty_repo, ci_template_project_id = ensure_project(CI_TEMPLATE_PROJECT_PATH, CI_TEMPLATE_PROJECT_NAME)
if ci_template_empty_repo:
    seed_project_from_dir(CI_TEMPLATE_PROJECT_PATH, CI_TEMPLATE_SOURCE_DIR)
else:
    ensure_repository_file(
        ci_template_project_id,
        "gitlab-ci.yml",
        CI_TEMPLATE_SOURCE_DIR / "gitlab-ci.yml",
        "chore: update CI template",
    )
ensure_project_tag(ci_template_project_id, CI_TEMPLATE_REF, "main")

# ── Dépôts manifests ────────────────────────────────────────────────────────

for app in inventory["apps"]:
    manifests = app["manifests"]
    app_name = app["name"]
    manifests_source_dir = REPO_ROOT / manifests["localPath"]

    if not (manifests_source_dir / ".git").is_dir():
        print(f"Dépôt git manifests introuvable : {manifests_source_dir}", file=sys.stderr)
        sys.exit(1)

    unique_branches = list(dict.fromkeys(env["branch"] for env in app["environments"]))

    _, manifests_project_id = ensure_project(manifests["projectPath"], manifests["projectName"])
    unprotect_main_branch(manifests_project_id)
    seed_project_from_repo(manifests["projectPath"], manifests_source_dir)
    seed_repo_branches_from_ref(manifests["projectPath"], manifests_source_dir, "main", " ".join(unique_branches))
    configure_main_gate(manifests_project_id, manifests["mainPushAccessLevel"])

# ── Dépôts code applicatif ──────────────────────────────────────────────────

for app in inventory["apps"]:
    code = app["code"]
    manifests = app["manifests"]
    app_name = app["name"]
    code_source_dir = REPO_ROOT / code["localPath"]

    if not (code_source_dir / ".git").is_dir():
        print(f"Dépôt git applicatif introuvable : {code_source_dir}", file=sys.stderr)
        sys.exit(1)

    services_str = " ".join(f"{s['name']}={s['image']}" for s in app["services"])
    has_preprod_str = str(app["hasPreprod"]).lower()

    _, code_project_id = ensure_project(code["projectPath"], code["projectName"])
    ensure_push_token_variable(code_project_id, app_name)
    unprotect_main_branch(code_project_id)

    ci_file = code_source_dir / ".gitlab-ci.yml"
    render_app_ci(
        app_name, services_str, app["showcaseService"], INTERNAL_GITLAB_HOST,
        manifests["projectPath"], manifests["path"], has_preprod_str, DOMAIN, ci_file,
    )

    ci_local_file = code_source_dir / ".gitlab-ci-local.yml"
    render_app_ci_local(ci_local_file)

    ci_files = [".gitlab-ci.yml", ".gitlab-ci-local.yml"]
    git_status = subprocess.run(
        ["git", "-C", str(code_source_dir), "status", "--porcelain", "--"] + ci_files,
        capture_output=True, text=True, check=True,
    ).stdout.strip()

    if git_status:
        print(f"Commit des fichiers CI GitLab dans le dépôt réel '{code_source_dir}'...")
        for f in ci_files:
            subprocess.run(["git", "-C", str(code_source_dir), "add", f], check=True)
        subprocess.run(["git", "-C", str(code_source_dir), "commit", "-q", "-m", "chore: configure CI GitLab"], check=True)

    seed_project_from_repo(code["projectPath"], code_source_dir)
    configure_main_gate(code_project_id, 0)
    configure_protected_environment(code_project_id, "prod", 40)
