#!/usr/bin/env bash
# Crée un token d'authentification de runner d'instance via l'API GitLab et le
# stocke dans le Secret K8s effectivement monté par le chart GitLab Runner
# (`gitlab-gitlab-runner-secret`). Idempotent : ne fait rien si le Secret
# existe déjà avec un runner-token non vide.
set -euo pipefail

GITLAB_NAMESPACE="${GITLAB_NAMESPACE:-gitlab}"
GITLAB_URL="${GITLAB_URL:-http://gitlab.192.168.33.100.nip.io}"
SECRET_NAME="${SECRET_NAME:-gitlab-gitlab-runner-secret}"

if kubectl -n "$GITLAB_NAMESPACE" get secret "$SECRET_NAME" >/dev/null 2>&1; then
  EXISTING_RUNNER_TOKEN=$(kubectl -n "$GITLAB_NAMESPACE" get secret "$SECRET_NAME" -o jsonpath='{.data.runner-token}' | base64 -d)
  if [ -n "$EXISTING_RUNNER_TOKEN" ]; then
    echo "Secret '$SECRET_NAME' déjà présent dans '$GITLAB_NAMESPACE' avec un runner-token, rien à faire."
    exit 0
  fi
fi

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

RUNNER_TOKEN=$(curl -sf --request POST "${GITLAB_URL}/api/v4/user/runners" \
  --header "Authorization: Bearer ${BEARER_TOKEN}" \
  --data-urlencode "runner_type=instance_type" \
  --data-urlencode "description=k3d-poc-devops" \
  | jq -r '.token')

if [ -z "$RUNNER_TOKEN" ] || [ "$RUNNER_TOKEN" = "null" ]; then
  echo "Échec de création du runner d'instance" >&2
  exit 1
fi

kubectl -n "$GITLAB_NAMESPACE" create secret generic "$SECRET_NAME" \
  --from-literal=runner-registration-token= \
  --from-literal=runner-token="${RUNNER_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Secret '$SECRET_NAME' créé avec un nouveau token d'instance runner."
