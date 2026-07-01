#!/usr/bin/env python3
"""Generate ArgoCD app resources from argocd/apps/<app>/app.yaml."""
from __future__ import annotations

import argparse
import shutil
import sys
import tempfile
from pathlib import Path

import yaml

from platform_inventory import default_apps_file, load_inventory, platform_constants

# Secret dockerconfigjson source, deploye une seule fois par `make ghcr-pull-secret`
# (control-plane). Les Jobs generes ci-dessous le recopient dans chaque namespace
# applicatif: ArgoCD ne sait pas dechiffrer SOPS nativement (contrairement a Flux),
# donc un seul secret chiffre sert de source et le reste passe par kubectl.
_GHCR_SOURCE_NAMESPACE = "argocd"
_GHCR_SOURCE_SECRET = "ghcr-pull-secret"
_GHCR_TARGET_SECRET = "ghcr-pull"


def app_project(app: dict) -> dict:
    return {
        "apiVersion": "argoproj.io/v1alpha1",
        "kind": "AppProject",
        "metadata": {"name": app["argocd"]["project"], "namespace": "argocd"},
        "spec": {
            "description": app.get("description", ""),
            "sourceRepos": app["argocd"]["sourceRepos"],
            "destinations": app["argocd"]["destinations"],
            "clusterResourceWhitelist": [{"group": "", "kind": "Namespace"}],
        },
    }


def applicationset(app: dict) -> dict:
    elements = [
        {
            "app": app["name"],
            "project": app["argocd"]["project"],
            "env": env["name"],
            "branch": env["branch"],
            "namespace": env["namespace"],
            "repoURL": app["manifests"]["argocdRepoURL"],
            "path": app["manifests"]["path"],
        }
        for env in app["environments"]
    ]
    return {
        "apiVersion": "argoproj.io/v1alpha1",
        "kind": "ApplicationSet",
        "metadata": {"name": app["name"], "namespace": "argocd"},
        "spec": {
            "goTemplate": True,
            "goTemplateOptions": ["missingkey=error"],
            "generators": [{"list": {"elements": elements}}],
            "template": {
                "metadata": {
                    "name": "{{ .app }}-{{ .env }}",
                    "namespace": "argocd",
                    "finalizers": ["resources-finalizer.argocd.argoproj.io"],
                },
                "spec": {
                    "project": "{{ .project }}",
                    "source": {
                        "repoURL": "{{ .repoURL }}",
                        "targetRevision": "{{ .branch }}",
                        "path": "{{ .path }}",
                    },
                    "destination": {
                        "server": "https://kubernetes.default.svc",
                        "namespace": "{{ .namespace }}",
                    },
                    "syncPolicy": {
                        "automated": {"prune": True, "selfHeal": True},
                        "syncOptions": ["CreateNamespace=true"],
                    },
                },
            },
        },
    }


def repo_creds(app: dict) -> list[dict]:
    name = app["name"]
    sa = f"gitlab-iac-repo-creds-{name}"
    read_role = f"{sa}-read"
    write_role = f"{sa}-write"
    secret_name = app["manifests"]["argocdSecretName"]
    repo_url = app["manifests"]["argocdRepoURL"]
    annotations = {"argocd.argoproj.io/sync-wave": "2"}
    return [
        {
            "apiVersion": "v1",
            "kind": "ServiceAccount",
            "metadata": {"name": sa, "namespace": "argocd", "annotations": annotations},
        },
        {
            "apiVersion": "rbac.authorization.k8s.io/v1",
            "kind": "Role",
            "metadata": {"name": read_role, "namespace": "gitlab", "annotations": annotations},
            "rules": [
                {
                    "apiGroups": [""],
                    "resources": ["secrets"],
                    "resourceNames": ["gitlab-gitlab-initial-root-password"],
                    "verbs": ["get"],
                }
            ],
        },
        {
            "apiVersion": "rbac.authorization.k8s.io/v1",
            "kind": "RoleBinding",
            "metadata": {"name": read_role, "namespace": "gitlab", "annotations": annotations},
            "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": read_role},
            "subjects": [{"kind": "ServiceAccount", "name": sa, "namespace": "argocd"}],
        },
        {
            "apiVersion": "rbac.authorization.k8s.io/v1",
            "kind": "Role",
            "metadata": {"name": write_role, "namespace": "argocd", "annotations": annotations},
            "rules": [
                {
                    "apiGroups": [""],
                    "resources": ["secrets"],
                    "resourceNames": [secret_name],
                    "verbs": ["get", "patch"],
                },
                {"apiGroups": [""], "resources": ["secrets"], "verbs": ["create"]},
            ],
        },
        {
            "apiVersion": "rbac.authorization.k8s.io/v1",
            "kind": "RoleBinding",
            "metadata": {"name": write_role, "namespace": "argocd", "annotations": annotations},
            "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": write_role},
            "subjects": [{"kind": "ServiceAccount", "name": sa, "namespace": "argocd"}],
        },
        {
            "apiVersion": "batch/v1",
            "kind": "Job",
            "metadata": {
                "name": sa,
                "namespace": "argocd",
                "annotations": {
                    "argocd.argoproj.io/hook": "Sync",
                    "argocd.argoproj.io/sync-wave": "2",
                    "argocd.argoproj.io/hook-delete-policy": "BeforeHookCreation,HookSucceeded",
                },
            },
            "spec": {
                "backoffLimit": 2,
                "template": {
                    "spec": {
                        "serviceAccountName": sa,
                        "restartPolicy": "Never",
                        "containers": [
                            {
                                "name": "create-secret",
                                "image": "registry.gitlab.com/gitlab-org/build/cng/kubectl:v18.11.5",
                                "imagePullPolicy": "IfNotPresent",
                                "command": [
                                    "/bin/sh",
                                    "-ec",
                                    repo_creds_script(secret_name, repo_url),
                                ],
                            }
                        ],
                    }
                },
            },
        },
    ]


def repo_creds_script(secret_name: str, repo_url: str) -> str:
    return f"""\
for i in $(seq 1 120); do
  if kubectl -n gitlab get secret gitlab-gitlab-initial-root-password >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

password=$(
  kubectl -n gitlab get secret gitlab-gitlab-initial-root-password \\
    -o jsonpath='{{.data.password}}' | base64 -d
)

kubectl -n argocd create secret generic {secret_name} \\
  --from-literal=type=git \\
  --from-literal=url={repo_url} \\
  --from-literal=username=root \\
  --from-literal=password="$password" \\
  --dry-run=client -o yaml \\
  | kubectl -n argocd label -f - argocd.argoproj.io/secret-type=repository --local -o yaml \\
  | kubectl apply -f -
"""


def ghcr_pull_secret(app: dict) -> list[dict]:
    name = app["name"]
    sa = f"ghcr-pull-{name}"
    read_role = f"{sa}-read"
    ns_annotations = {"argocd.argoproj.io/sync-wave": "0"}
    rbac_annotations = {"argocd.argoproj.io/sync-wave": "1"}
    resources = [
        {
            "apiVersion": "v1",
            "kind": "ServiceAccount",
            "metadata": {"name": sa, "namespace": _GHCR_SOURCE_NAMESPACE, "annotations": rbac_annotations},
        },
        {
            "apiVersion": "rbac.authorization.k8s.io/v1",
            "kind": "Role",
            "metadata": {"name": read_role, "namespace": _GHCR_SOURCE_NAMESPACE, "annotations": rbac_annotations},
            "rules": [
                {
                    "apiGroups": [""],
                    "resources": ["secrets"],
                    "resourceNames": [_GHCR_SOURCE_SECRET],
                    "verbs": ["get"],
                }
            ],
        },
        {
            "apiVersion": "rbac.authorization.k8s.io/v1",
            "kind": "RoleBinding",
            "metadata": {"name": read_role, "namespace": _GHCR_SOURCE_NAMESPACE, "annotations": rbac_annotations},
            "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": read_role},
            "subjects": [{"kind": "ServiceAccount", "name": sa, "namespace": _GHCR_SOURCE_NAMESPACE}],
        },
    ]

    for env in app["environments"]:
        namespace = env["namespace"]
        write_role = f"{sa}-{env['name']}-write"
        resources.extend(
            [
                {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": namespace, "annotations": ns_annotations}},
                {
                    "apiVersion": "rbac.authorization.k8s.io/v1",
                    "kind": "Role",
                    "metadata": {"name": write_role, "namespace": namespace, "annotations": rbac_annotations},
                    "rules": [
                        {
                            "apiGroups": [""],
                            "resources": ["secrets"],
                            "resourceNames": [_GHCR_TARGET_SECRET],
                            "verbs": ["get", "patch"],
                        },
                        {"apiGroups": [""], "resources": ["secrets"], "verbs": ["create"]},
                    ],
                },
                {
                    "apiVersion": "rbac.authorization.k8s.io/v1",
                    "kind": "RoleBinding",
                    "metadata": {"name": write_role, "namespace": namespace, "annotations": rbac_annotations},
                    "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": write_role},
                    "subjects": [{"kind": "ServiceAccount", "name": sa, "namespace": _GHCR_SOURCE_NAMESPACE}],
                },
                {
                    "apiVersion": "batch/v1",
                    "kind": "Job",
                    "metadata": {
                        "name": f"{sa}-{env['name']}",
                        "namespace": _GHCR_SOURCE_NAMESPACE,
                        "annotations": {
                            "argocd.argoproj.io/hook": "Sync",
                            "argocd.argoproj.io/sync-wave": "1",
                            "argocd.argoproj.io/hook-delete-policy": "BeforeHookCreation,HookSucceeded",
                        },
                    },
                    "spec": {
                        "backoffLimit": 2,
                        "template": {
                            "spec": {
                                "serviceAccountName": sa,
                                "restartPolicy": "Never",
                                "containers": [
                                    {
                                        "name": "copy-secret",
                                        "image": "registry.gitlab.com/gitlab-org/build/cng/kubectl:v18.11.5",
                                        "imagePullPolicy": "IfNotPresent",
                                        "command": ["/bin/sh", "-ec", ghcr_copy_script(namespace)],
                                    }
                                ],
                            }
                        },
                    },
                },
            ]
        )

    return resources


def ghcr_copy_script(namespace: str) -> str:
    return f"""\
for i in $(seq 1 60); do
  if kubectl -n {_GHCR_SOURCE_NAMESPACE} get secret {_GHCR_SOURCE_SECRET} >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

dockerconfig=$(
  kubectl -n {_GHCR_SOURCE_NAMESPACE} get secret {_GHCR_SOURCE_SECRET} \\
    -o jsonpath='{{.data.\\.dockerconfigjson}}' | base64 -d
)

kubectl -n {namespace} create secret generic {_GHCR_TARGET_SECRET} \\
  --type=kubernetes.io/dockerconfigjson \\
  --from-literal=.dockerconfigjson="$dockerconfig" \\
  --dry-run=client -o yaml \\
  | kubectl apply -f -
"""


def root_appset(pconst: dict) -> dict:
    return {
        "apiVersion": "argoproj.io/v1alpha1",
        "kind": "ApplicationSet",
        "metadata": {"name": "apps", "namespace": "argocd"},
        "spec": {
            "goTemplate": True,
            "goTemplateOptions": ["missingkey=error"],
            "generators": [
                {
                    "git": {
                        "repoURL": pconst["repoURL"],
                        "revision": pconst["targetRevision"],
                        "directories": [{"path": "argocd/generated/apps/*"}],
                    }
                }
            ],
            "template": {
                "metadata": {
                    "name": "app-config-{{ .path.basename }}",
                    "namespace": "argocd",
                    "finalizers": ["resources-finalizer.argocd.argoproj.io"],
                },
                "spec": {
                    "project": "default",
                    "source": {
                        "repoURL": pconst["repoURL"],
                        "targetRevision": pconst["targetRevision"],
                        "path": "{{ .path.path }}",
                    },
                    "destination": {
                        "server": "https://kubernetes.default.svc",
                        "namespace": "argocd",
                    },
                    "syncPolicy": {
                        "automated": {"prune": True, "selfHeal": True},
                        "syncOptions": ["CreateNamespace=true"],
                    },
                },
            },
        },
    }


def write_yaml(path: Path, docs: dict | list[dict]) -> None:
    documents = docs if isinstance(docs, list) else [docs]
    path.write_text(
        "\n---\n".join(
            yaml.dump(doc, allow_unicode=True, sort_keys=False, default_flow_style=False).strip()
            for doc in documents
        )
        + "\n"
    )


def render(apps_file: Path, output_dir: Path, managed_file: Path) -> None:
    inventory = load_inventory(apps_file)
    pconst = platform_constants(inventory)

    if output_dir.exists():
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True)
    (output_dir / ".gitkeep").touch()

    for app in inventory["apps"]:
        app_dir = output_dir / app["name"]
        app_dir.mkdir()
        write_yaml(app_dir / "app-project.yaml", app_project(app))
        write_yaml(app_dir / "applicationset.yaml", applicationset(app))
        write_yaml(app_dir / "ghcr-pull-secret.yaml", ghcr_pull_secret(app))
        write_yaml(app_dir / "repo-creds.yaml", repo_creds(app))
        write_yaml(
            app_dir / "kustomization.yaml",
            {
                "apiVersion": "kustomize.config.k8s.io/v1beta1",
                "kind": "Kustomization",
                "resources": [
                    "app-project.yaml",
                    "applicationset.yaml",
                    "ghcr-pull-secret.yaml",
                    "repo-creds.yaml",
                ],
            },
        )

    managed_file.parent.mkdir(parents=True, exist_ok=True)
    write_yaml(managed_file, root_appset(pconst))


def same_tree(left: Path, right: Path) -> bool:
    left_files = sorted(p.relative_to(left) for p in left.rglob("*") if p.is_file())
    right_files = sorted(p.relative_to(right) for p in right.rglob("*") if p.is_file())
    return left_files == right_files and all((left / p).read_bytes() == (right / p).read_bytes() for p in left_files)


def check(apps_file: Path, output_dir: Path, managed_file: Path) -> int:
    with tempfile.TemporaryDirectory() as tmp:
        tmp_root = Path(tmp)
        tmp_output = tmp_root / "generated/apps"
        tmp_managed = tmp_root / "managed/apps-appset.yaml"
        render(apps_file, tmp_output, tmp_managed)
        if not managed_file.exists() or managed_file.read_bytes() != tmp_managed.read_bytes():
            print(f"{managed_file} n'est pas à jour. Lancez: make argocd-apps-render", file=sys.stderr)
            return 1
        if not output_dir.exists() or not same_tree(output_dir, tmp_output):
            print(f"{output_dir} n'est pas à jour. Lancez: make argocd-apps-render", file=sys.stderr)
            return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--apps-file", type=Path, default=default_apps_file())
    args = parser.parse_args()

    apps_file = args.apps_file.resolve()
    gitops_root = apps_file.parents[1]
    output_dir = gitops_root / "argocd/generated/apps"
    managed_file = gitops_root / "argocd/managed/apps-appset.yaml"

    if args.check:
        return check(apps_file, output_dir, managed_file)
    render(apps_file, output_dir, managed_file)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
