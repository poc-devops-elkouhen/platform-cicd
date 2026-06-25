#!/usr/bin/env bash
# Enregistre l'agent Kubernetes GitLab "poc-devops" sur le projet
# root/helloworld-svc, génère un token agentk si le Secret K8s n'existe pas encore,
# puis stocke ce token dans le namespace consommé par l'Application ArgoCD
# gitlab-agent. Idempotent côté cluster : un Secret existant est conservé,
# car GitLab ne permet pas de relire la valeur d'un token agent déjà créé.
set -euo pipefail

GITLAB_NAMESPACE="${GITLAB_NAMESPACE:-gitlab}"
GITLAB_AGENT_NAMESPACE="${GITLAB_AGENT_NAMESPACE:-gitlab-agent}"
GITLAB_URL="${GITLAB_URL:-http://gitlab.192.168.33.100.nip.io}"
AGENT_PROJECT_PATH="${AGENT_PROJECT_PATH:-root/helloworld-svc}"
AGENT_NAME="${AGENT_NAME:-poc-devops}"
AGENT_SECRET_NAME="${AGENT_SECRET_NAME:-gitlab-agent-token}"

if kubectl -n "$GITLAB_AGENT_NAMESPACE" get secret "$AGENT_SECRET_NAME" >/dev/null 2>&1; then
  echo "Secret '$AGENT_SECRET_NAME' déjà présent dans '$GITLAB_AGENT_NAMESPACE', aucun token agent recréé."
  exit 0
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

ENCODED_PROJECT_PATH="${AGENT_PROJECT_PATH//\//%2F}"

AGENT_ID=$(curl -sf --header "Authorization: Bearer ${BEARER_TOKEN}" \
  "${GITLAB_URL}/api/v4/projects/${ENCODED_PROJECT_PATH}/cluster_agents" \
  | jq -r --arg name "$AGENT_NAME" '.[] | select(.name == $name) | .id' \
  | head -n1)

if [ -z "$AGENT_ID" ]; then
  echo "Agent Kubernetes GitLab '$AGENT_NAME' absent, enregistrement..."
  AGENT_ID=$(curl -sf --request POST "${GITLAB_URL}/api/v4/projects/${ENCODED_PROJECT_PATH}/cluster_agents" \
    --header "Authorization: Bearer ${BEARER_TOKEN}" \
    --header "Content-Type: application/json" \
    --data "{\"name\":\"${AGENT_NAME}\"}" \
    | jq -r '.id')
fi

TOKEN=$(curl -sf --request POST "${GITLAB_URL}/api/v4/projects/${ENCODED_PROJECT_PATH}/cluster_agents/${AGENT_ID}/tokens" \
  --header "Authorization: Bearer ${BEARER_TOKEN}" \
  --header "Content-Type: application/json" \
  --data "{\"name\":\"${AGENT_NAME}-bootstrap\"}" \
  | jq -r '.token')

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "Échec de création du token agent Kubernetes GitLab" >&2
  exit 1
fi

kubectl create namespace "$GITLAB_AGENT_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$GITLAB_AGENT_NAMESPACE" create secret generic "$AGENT_SECRET_NAME" \
  --from-literal=token="$TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Agent Kubernetes GitLab '$AGENT_NAME' enregistré et Secret '$AGENT_SECRET_NAME' créé."
