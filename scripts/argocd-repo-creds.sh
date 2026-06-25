#!/usr/bin/env bash
# Crée les Secrets K8s de credentials ArgoCD pour les dépôts manifests privés
# déclarés dans argocd/apps.yaml. Chaque Secret est labellisé
# argocd.argoproj.io/secret-type=repository et donne un accès read_repository.
set -euo pipefail

GITLAB_NAMESPACE="${GITLAB_NAMESPACE:-gitlab}"
GITLAB_URL="${GITLAB_URL:-http://gitlab.192.168.33.100.nip.io}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
APPS_FILE="${APPS_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/argocd/apps.yaml}"

ROOT_PASSWORD=$(kubectl -n "$GITLAB_NAMESPACE" get secret gitlab-gitlab-initial-root-password -o jsonpath='{.data.password}' | base64 -d)

BEARER_TOKEN=$(curl -sf --request POST "${GITLAB_URL}/oauth/token" \
  --data-urlencode "grant_type=password" \
  --data-urlencode "username=root" \
  --data-urlencode "password=${ROOT_PASSWORD}" \
  | jq -r '.access_token')

if [ -z "$BEARER_TOKEN" ] || [ "$BEARER_TOKEN" = "null" ]; then
  echo "Échec d'authentification à l'API GitLab" >&2
  exit 1
fi

ROOT_USER_ID=$(curl -sf --header "Authorization: Bearer ${BEARER_TOKEN}" "${GITLAB_URL}/api/v4/user" | jq -r '.id')
EXPIRES_AT=$(date -v+1y +%Y-%m-%d)

read_apps() {
  ruby -ryaml -e '
    YAML.load_file(ARGV.fetch(0)).fetch("apps").each do |app|
      manifests = app.fetch("manifests")
      puts [app.fetch("name"), manifests.fetch("argocdSecretName"), manifests.fetch("repoURL")].join("\t")
    end
  ' "$APPS_FILE"
}

while IFS=$'\t' read -r app_name secret_name repo_url; do
  if kubectl -n "$ARGOCD_NAMESPACE" get secret "$secret_name" >/dev/null 2>&1; then
    echo "Secret '$secret_name' déjà présent dans '$ARGOCD_NAMESPACE', rien à faire."
    continue
  fi

  argocd_token=$(curl -sf --request POST "${GITLAB_URL}/api/v4/users/${ROOT_USER_ID}/personal_access_tokens" \
    --header "Authorization: Bearer ${BEARER_TOKEN}" \
    --data-urlencode "name=argocd-${app_name}-manifests" \
    --data-urlencode "scopes[]=read_repository" \
    --data-urlencode "expires_at=${EXPIRES_AT}" \
    | jq -r '.token')

  if [ -z "$argocd_token" ] || [ "$argocd_token" = "null" ]; then
    echo "Échec de création du token de lecture ArgoCD pour '${app_name}'" >&2
    exit 1
  fi

  kubectl -n "$ARGOCD_NAMESPACE" create secret generic "$secret_name" \
    --from-literal=type=git \
    --from-literal=url="$repo_url" \
    --from-literal=username=root \
    --from-literal=password="$argocd_token"
  kubectl -n "$ARGOCD_NAMESPACE" label secret "$secret_name" argocd.argoproj.io/secret-type=repository

  echo "Secret '$secret_name' créé pour '$repo_url'."
done < <(read_apps)
