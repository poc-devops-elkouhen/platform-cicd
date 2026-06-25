#!/usr/bin/env bash
# Seed GitLab depuis l'inventaire argocd/apps.yaml :
# - root/ci-templates, tagué en version immuable pour les includes CI ;
# - root/<app>-iac, un seul dépôt manifests par app, branches dev/rec/preprod?/main ;
# - root/<app>, un dépôt de code par app, branche main unique,
#   .gitlab-ci.yml généré depuis le template.
set -euo pipefail

GITLAB_NAMESPACE="${GITLAB_NAMESPACE:-gitlab}"
GITLAB_URL="${GITLAB_URL:-http://gitlab.192.168.33.100.nip.io}"
GITLAB_ROOT_NAMESPACE="${GITLAB_ROOT_NAMESPACE:-root}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APPS_FILE="${APPS_FILE:-$REPO_ROOT/argocd/apps.yaml}"
yaml_value() {
  ruby -ryaml -e 'value = ARGV[1].split(".").reduce(YAML.load_file(ARGV[0])) { |memo, key| memo.fetch(key) }; puts value' "$APPS_FILE" "$1"
}

CI_TEMPLATE_PROJECT_PATH="${CI_TEMPLATE_PROJECT_PATH:-$(yaml_value ciTemplate.projectPath)}"
CI_TEMPLATE_PROJECT_NAME="${CI_TEMPLATE_PROJECT_NAME:-$(yaml_value ciTemplate.projectName)}"
CI_TEMPLATE_SOURCE_DIR="${CI_TEMPLATE_SOURCE_DIR:-$REPO_ROOT/$(yaml_value ciTemplate.sourceDir)}"
CI_TEMPLATE_REF="${CI_TEMPLATE_REF:-$(yaml_value ciTemplate.ref)}"
CI_TEMPLATE_FILE="${CI_TEMPLATE_FILE:-$(yaml_value ciTemplate.file)}"
AGENT_NAME="${AGENT_NAME:-$(yaml_value agent.name)}"
AGENT_PROJECT_PATH="${AGENT_PROJECT_PATH:-$(yaml_value agent.projectPath)}"
REGISTRY_HOST="${REGISTRY_HOST:-registry.registry.svc.cluster.local:5000}"
INTERNAL_GITLAB_HOST="${INTERNAL_GITLAB_HOST:-$(yaml_value gitlab.internalHost)}"

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

GITLAB_SCHEME="${GITLAB_URL%%://*}"
GITLAB_HOST="${GITLAB_URL#*://}"

encode_path() {
  local value="$1"
  echo "${value//\//%2F}"
}

ensure_project() {
  local project_path="$1" project_name="$2"
  local encoded_path project_json project_id empty_repo
  encoded_path=$(encode_path "$project_path")
  project_json=$(curl -s --header "Authorization: Bearer ${BEARER_TOKEN}" "${GITLAB_URL}/api/v4/projects/${encoded_path}")
  project_id=$(echo "$project_json" | jq -r '.id // empty')
  if [ -z "$project_id" ]; then
    echo "Projet '$project_path' absent, création..." >&2
    project_json=$(curl -sf --request POST "${GITLAB_URL}/api/v4/projects" \
      --header "Authorization: Bearer ${BEARER_TOKEN}" \
      --data-urlencode "name=${project_name}" \
      --data-urlencode "visibility=private" \
      --data-urlencode "initialize_with_readme=false")
    project_id=$(echo "$project_json" | jq -r '.id')
    empty_repo=true
  else
    empty_repo=$(echo "$project_json" | jq -r '.empty_repo')
  fi
  echo "${empty_repo} ${project_id}"
}

seed_project_from_dir() {
  local project_path="$1" source_dir="$2"
  shift 2
  local env_branches=("$@")
  local workdir branch

  echo "Poussée du contenu initial de '$source_dir' vers '$project_path'..."
  workdir=$(mktemp -d)
  cp -R "$source_dir"/. "$workdir"/
  rm -rf "$workdir/.venv" "$workdir/.git"

  git -C "$workdir" init -q -b main
  git -C "$workdir" config user.email "bootstrap@gitlab.local"
  git -C "$workdir" config user.name "GitLab Bootstrap"
  git -C "$workdir" add -A
  git -C "$workdir" commit -q -m "chore: seed initial du projet ${project_path}"
  git -C "$workdir" remote add origin "${GITLAB_SCHEME}://root:${ROOT_PASSWORD}@${GITLAB_HOST}/${project_path}.git"
  git -C "$workdir" push -q origin main

  if [ "$#" -gt 0 ]; then
    for branch in "$@"; do
      git -C "$workdir" checkout -q -b "$branch" main
      apply_manifests_env_overrides "$workdir" "$CURRENT_APP_NAME" "$branch" "$MANIFESTS_PATH"
      git -C "$workdir" add -A
      git -C "$workdir" commit -q -m "chore: overrides environnement ${branch} (${project_path})"
      git -C "$workdir" push -q origin "$branch"
    done
  fi

  rm -rf "$workdir"
  echo "Contenu initial poussé sur 'main' et $# branche(s) d'environnement de '$project_path'."
}

# Un repo manifests peut contenir plusieurs services (un par sous-ensemble de
# 3 fichiers <service>-{deployment,service,route}.yaml) -- une URL par
# (app, environnement, service), donc un sed par service plutôt qu'un seul
# fichier de routage unique comme avant.
apply_manifests_env_overrides() {
  local dir="$1" app_name="$2" branch="$3" manifests_path="${4:-}"
  local service_name route_host route_file ingress_file
  while IFS=$'\t' read -r service_name route_host; do
    route_file="$dir/${manifests_path:+$manifests_path/}${service_name}-route.yaml"
    ingress_file="$dir/${manifests_path:+$manifests_path/}${service_name}-ingress.yaml"
    if [ -f "$route_file" ]; then
      # $route_host est déjà le FQDN complet (ex. helloworld-svc-dev.192.168.33.100.nip.io).
      sed -i '' -E "s#^([[:space:]]*-[[:space:]]*)[A-Za-z0-9.-]+\\.nip\\.io#\\1${route_host}#" "$route_file"
    elif [ -f "$ingress_file" ]; then
      sed -i '' -E "s#^([[:space:]]*-?[[:space:]]*host:[[:space:]]*).*#\\1${route_host}#" "$ingress_file"
    fi
  done < <(service_hosts_for_branch "$app_name" "$branch")
}

service_hosts_for_branch() {
  local app_name="$1" branch="$2"
  ruby -ryaml -e '
    app = YAML.load_file(ARGV.fetch(0)).fetch("apps").find { |a| a.fetch("name") == ARGV.fetch(1) }
    env = app.fetch("environments").find { |e| e.fetch("branch") == ARGV.fetch(2) }
    env.fetch("services").each do |svc|
      puts [svc.fetch("name"), svc.fetch("ingressHost")].join("\t")
    end
  ' "$APPS_FILE" "$app_name" "$branch"
}

configure_main_gate() {
  local project_id="$1" push_access_level="${2:-0}"
  echo "Configuration du gate sur la branche 'main' (push_access_level=${push_access_level}, merge réservé aux Maintainers)..."
  curl -s --request DELETE --header "Authorization: Bearer ${BEARER_TOKEN}" \
    "${GITLAB_URL}/api/v4/projects/${project_id}/protected_branches/main" >/dev/null
  curl -sf --request POST --header "Authorization: Bearer ${BEARER_TOKEN}" \
    "${GITLAB_URL}/api/v4/projects/${project_id}/protected_branches" \
    --data-urlencode "name=main" \
    --data-urlencode "push_access_level=${push_access_level}" \
    --data-urlencode "merge_access_level=40" \
    --data-urlencode "allow_force_push=false" >/dev/null
  curl -sf --request PUT --header "Authorization: Bearer ${BEARER_TOKEN}" \
    "${GITLAB_URL}/api/v4/projects/${project_id}" \
    --data-urlencode "only_allow_merge_if_all_discussions_are_resolved=true" >/dev/null
  echo "Gate configuré sur 'main'."
}

configure_protected_environment() {
  local project_id="$1" environment_name="$2" access_level="${3:-40}"
  echo "Configuration du protected environment '${environment_name}' (deploy réservé aux Maintainers)..."
  curl -s --request DELETE --header "Authorization: Bearer ${BEARER_TOKEN}" \
    "${GITLAB_URL}/api/v4/projects/${project_id}/protected_environments/${environment_name}" >/dev/null
  curl -sf --request POST --header "Authorization: Bearer ${BEARER_TOKEN}" \
    "${GITLAB_URL}/api/v4/projects/${project_id}/protected_environments" \
    --data-urlencode "name=${environment_name}" \
    --data-urlencode "deploy_access_levels[][access_level]=${access_level}" >/dev/null
  echo "Protected environment '${environment_name}' configuré."
}

ensure_repository_file() {
  local project_id="$1" file_path="$2" local_file="$3" commit_message="$4"
  local encoded_file_path current_file
  encoded_file_path=$(encode_path "$file_path")
  current_file=$(mktemp)
  if curl -sf --header "Authorization: Bearer ${BEARER_TOKEN}" \
    "${GITLAB_URL}/api/v4/projects/${project_id}/repository/files/${encoded_file_path}/raw?ref=main" \
    -o "$current_file"; then
    if cmp -s "$local_file" "$current_file"; then
      rm -f "$current_file"
      echo "Fichier '$file_path' déjà à jour dans le projet ${project_id}."
      return
    fi
    rm -f "$current_file"
    echo "Mise à jour de '$file_path' dans le projet ${project_id}..."
    curl -sf --request PUT --header "Authorization: Bearer ${BEARER_TOKEN}" \
      "${GITLAB_URL}/api/v4/projects/${project_id}/repository/files/${encoded_file_path}" \
      --data-urlencode "branch=main" \
      --data-urlencode "commit_message=${commit_message}" \
      --data-urlencode "content@${local_file}" >/dev/null
  else
    rm -f "$current_file"
    echo "Création de '$file_path' dans le projet ${project_id}..."
    curl -sf --request POST --header "Authorization: Bearer ${BEARER_TOKEN}" \
      "${GITLAB_URL}/api/v4/projects/${project_id}/repository/files/${encoded_file_path}" \
      --data-urlencode "branch=main" \
      --data-urlencode "commit_message=${commit_message}" \
      --data-urlencode "content@${local_file}" >/dev/null
  fi
}

ensure_repository_file_on_main_with_gate() {
  local project_id="$1" file_path="$2" local_file="$3" commit_message="$4" push_access_level="$5"
  local status
  curl -s --request DELETE --header "Authorization: Bearer ${BEARER_TOKEN}" \
    "${GITLAB_URL}/api/v4/projects/${project_id}/protected_branches/main" >/dev/null
  set +e
  ensure_repository_file "$project_id" "$file_path" "$local_file" "$commit_message"
  status=$?
  set -e
  configure_main_gate "$project_id" "$push_access_level"
  return "$status"
}

ensure_project_tag() {
  local project_id="$1" tag_name="$2" ref="$3"
  if curl -sf --header "Authorization: Bearer ${BEARER_TOKEN}" \
    "${GITLAB_URL}/api/v4/projects/${project_id}/repository/tags/${tag_name}" >/dev/null; then
    echo "Tag '${tag_name}' déjà présent."
    return
  fi
  echo "Création du tag '${tag_name}' sur '${ref}'..."
  curl -sf --request POST --header "Authorization: Bearer ${BEARER_TOKEN}" \
    "${GITLAB_URL}/api/v4/projects/${project_id}/repository/tags" \
    --data-urlencode "tag_name=${tag_name}" \
    --data-urlencode "ref=${ref}" >/dev/null
}

ensure_push_token_variable() {
  local project_id="$1" label="$2"
  local var_status root_user_id expires_at push_token
  var_status=$(curl -s -o /dev/null -w '%{http_code}' --header "Authorization: Bearer ${BEARER_TOKEN}" \
    "${GITLAB_URL}/api/v4/projects/${project_id}/variables/GITLAB_PUSH_TOKEN")

  if [ "$var_status" = "200" ]; then
    echo "Variable CI/CD 'GITLAB_PUSH_TOKEN' déjà présente."
    return
  fi

  echo "Variable CI/CD 'GITLAB_PUSH_TOKEN' absente pour '${label}', génération d'un token root et création..."
  root_user_id=$(curl -sf --header "Authorization: Bearer ${BEARER_TOKEN}" "${GITLAB_URL}/api/v4/user" | jq -r '.id')
  expires_at=$(date -v+1y +%Y-%m-%d)
  push_token=$(curl -sf --request POST "${GITLAB_URL}/api/v4/users/${root_user_id}/personal_access_tokens" \
    --header "Authorization: Bearer ${BEARER_TOKEN}" \
    --data-urlencode "name=ci-push-${label}" \
    --data-urlencode "scopes[]=api" \
    --data-urlencode "expires_at=${expires_at}" \
    | jq -r '.token')
  curl -sf --request POST "${GITLAB_URL}/api/v4/projects/${project_id}/variables" \
    --header "Authorization: Bearer ${BEARER_TOKEN}" \
    --data-urlencode "key=GITLAB_PUSH_TOKEN" \
    --data-urlencode "value=${push_token}" \
    --data-urlencode "masked=true" \
    --data-urlencode "protected=false" >/dev/null
  echo "Variable CI/CD 'GITLAB_PUSH_TOKEN' créée."
}

render_app_ci() {
  local app_name="$1" services="$2" showcase_service="$3" internal_gitlab_host="$4" manifests_project_path="$5" manifests_path="$6" has_preprod="$7" gitlab_k8s_agent="$8" out="$9"
  cat >"$out" <<EOF
include:
  - project: ${CI_TEMPLATE_PROJECT_PATH}
    ref: ${CI_TEMPLATE_REF}
    file: ${CI_TEMPLATE_FILE}

variables:
  APP_NAME: ${app_name}
  # Monorepo multi-services (cf. AGENTS.md) : liste "<service>=<image>"
  # espacée, un sous-dossier + un Dockerfile par service. SERVICE_NAME reste
  # le service vitrine pour l'URL des environnements GitLab CI.
  SERVICES: "${services}"
  SERVICE_NAME: ${showcase_service}
  INTERNAL_GITLAB_HOST: ${internal_gitlab_host}
  MANIFESTS_PROJECT_PATH: ${manifests_project_path}
  MANIFESTS_PATH: ${manifests_path}
  HAS_PREPROD: "${has_preprod}"
  GITLAB_K8S_AGENT: ${gitlab_k8s_agent}
EOF
}

render_agent_config() {
  local code_project_path="$1" out="$2"
  cat >"$out" <<EOF
ci_access:
  projects:
    - id: ${code_project_path}

user_access:
  access_as:
    agent: {}
  projects:
    - id: ${code_project_path}
EOF
}

render_agent_config_all() {
  local out="$1"
  {
    echo "ci_access:"
    echo "  projects:"
    read_app_code_inventory | while IFS=$'\t' read -r _app_name code_project_path _rest; do
      echo "    - id: ${code_project_path}"
    done
    echo
    echo "user_access:"
    echo "  access_as:"
    echo "    agent: {}"
    echo "  projects:"
    read_app_code_inventory | while IFS=$'\t' read -r _app_name code_project_path _rest; do
      echo "    - id: ${code_project_path}"
    done
  } >"$out"
}

# Une ligne par app : pilote la création/seed du repo manifests partagé par
# tous les services de cette app, et ses branches d'environnement.
read_app_inventory() {
  ruby -ryaml -e '
    YAML.load_file(ARGV.fetch(0)).fetch("apps").each do |app|
      manifests = app.fetch("manifests")
      env_branches = app.fetch("environments")
        .reject { |env| env.fetch("branch") == "main" }
        .map { |env| env.fetch("branch") }
        .join(",")
      puts [
        app.fetch("name"),
        manifests.fetch("projectPath"),
        manifests.fetch("projectName"),
        manifests.fetch("sourceDir"),
        manifests.fetch("mainPushAccessLevel"),
        manifests.fetch("path"),
        env_branches
      ].join("\t")
    end
  ' "$APPS_FILE"
}

# Une ligne par app : pilote la création/seed du repo de code unique de
# l'app (monorepo multi-services, cf. AGENTS.md "Monorepo multi-services")
# -- un dépôt git par app, un sous-dossier par service à l'intérieur.
read_app_code_inventory() {
  ruby -ryaml -e '
    YAML.load_file(ARGV.fetch(0)).fetch("apps").each do |app|
      code = app.fetch("code")
      manifests = app.fetch("manifests")
      services = app.fetch("services").map { |s| "#{s.fetch("name")}=#{s.fetch("image")}" }.join(" ")
      puts [
        app.fetch("name"),
        code.fetch("projectPath"),
        code.fetch("projectName"),
        code.fetch("sourceDir"),
        code.fetch("mainPushAccessLevel"),
        services,
        app.fetch("showcaseService"),
        manifests.fetch("projectPath"),
        manifests.fetch("path"),
        app.fetch("hasPreprod"),
        "#{code.fetch("projectPath")}:#{ARGV.fetch(1)}"
      ].join("\t")
    end
  ' "$APPS_FILE" "$AGENT_NAME"
}

read -r CI_TEMPLATE_EMPTY_REPO CI_TEMPLATE_PROJECT_ID <<<"$(ensure_project "$CI_TEMPLATE_PROJECT_PATH" "$CI_TEMPLATE_PROJECT_NAME")"
if [ "$CI_TEMPLATE_EMPTY_REPO" = "true" ]; then
  seed_project_from_dir "$CI_TEMPLATE_PROJECT_PATH" "$CI_TEMPLATE_SOURCE_DIR"
else
  ensure_repository_file "$CI_TEMPLATE_PROJECT_ID" "gitlab-ci.yml" "$CI_TEMPLATE_SOURCE_DIR/gitlab-ci.yml" "chore: update CI template"
fi
ensure_project_tag "$CI_TEMPLATE_PROJECT_ID" "$CI_TEMPLATE_REF" main

while IFS=$'\t' read -r APP_NAME MANIFESTS_PROJECT_PATH MANIFESTS_PROJECT_NAME MANIFESTS_SOURCE_DIR_REL MANIFESTS_PUSH_ACCESS MANIFESTS_PATH ENV_BRANCHES; do
  CURRENT_APP_NAME="$APP_NAME"
  MANIFESTS_SOURCE_DIR="$REPO_ROOT/${MANIFESTS_SOURCE_DIR_REL}"

  if [ ! -d "$MANIFESTS_SOURCE_DIR" ]; then
    echo "Source manifests introuvable : ${MANIFESTS_SOURCE_DIR}" >&2
    exit 1
  fi

  read -r MANIFESTS_EMPTY_REPO MANIFESTS_PROJECT_ID <<<"$(ensure_project "$MANIFESTS_PROJECT_PATH" "$MANIFESTS_PROJECT_NAME")"
  if [ "$MANIFESTS_EMPTY_REPO" = "true" ]; then
    IFS=',' read -r -a env_branches <<<"$ENV_BRANCHES"
    seed_project_from_dir "$MANIFESTS_PROJECT_PATH" "$MANIFESTS_SOURCE_DIR" "${env_branches[@]}"
  else
    echo "Projet '$MANIFESTS_PROJECT_PATH' a déjà du contenu (empty_repo=false), aucun push effectué."
  fi
  configure_main_gate "$MANIFESTS_PROJECT_ID" "$MANIFESTS_PUSH_ACCESS"
done < <(read_app_inventory)

while IFS=$'\t' read -r APP_NAME CODE_PROJECT_PATH CODE_PROJECT_NAME CODE_SOURCE_DIR_REL CODE_PUSH_ACCESS SERVICES SHOWCASE_SERVICE CI_MANIFESTS_PROJECT_PATH MANIFESTS_PATH HAS_PREPROD GITLAB_K8S_AGENT; do
  CODE_SOURCE_DIR="$REPO_ROOT/${CODE_SOURCE_DIR_REL}"

  if [ ! -d "$CODE_SOURCE_DIR" ]; then
    echo "Source applicative introuvable : ${CODE_SOURCE_DIR}" >&2
    exit 1
  fi

  read -r CODE_EMPTY_REPO CODE_PROJECT_ID <<<"$(ensure_project "$CODE_PROJECT_PATH" "$CODE_PROJECT_NAME")"
  ensure_push_token_variable "$CODE_PROJECT_ID" "$APP_NAME"

  if [ "$CODE_EMPTY_REPO" = "true" ]; then
    tmp_code=$(mktemp -d)
    cp -R "$CODE_SOURCE_DIR"/. "$tmp_code"/
    rm -rf "$tmp_code/.venv" "$tmp_code/.git"
    render_app_ci "$APP_NAME" "$SERVICES" "$SHOWCASE_SERVICE" "$INTERNAL_GITLAB_HOST" "$CI_MANIFESTS_PROJECT_PATH" "$MANIFESTS_PATH" "$HAS_PREPROD" "$GITLAB_K8S_AGENT" "$tmp_code/.gitlab-ci.yml"
    mkdir -p "$tmp_code/.gitlab/agents/${AGENT_NAME}"
    render_agent_config "$CODE_PROJECT_PATH" "$tmp_code/.gitlab/agents/${AGENT_NAME}/config.yaml"
    seed_project_from_dir "$CODE_PROJECT_PATH" "$tmp_code"
    rm -rf "$tmp_code"
    configure_main_gate "$CODE_PROJECT_ID" 0
  else
    echo "Projet '$CODE_PROJECT_PATH' a déjà du contenu (empty_repo=false), mise à jour des fichiers CI/agent uniquement."
    tmp_ci=$(mktemp)
    tmp_agent=$(mktemp)
    render_app_ci "$APP_NAME" "$SERVICES" "$SHOWCASE_SERVICE" "$INTERNAL_GITLAB_HOST" "$CI_MANIFESTS_PROJECT_PATH" "$MANIFESTS_PATH" "$HAS_PREPROD" "$GITLAB_K8S_AGENT" "$tmp_ci"
    render_agent_config "$CODE_PROJECT_PATH" "$tmp_agent"
    ensure_repository_file_on_main_with_gate "$CODE_PROJECT_ID" ".gitlab-ci.yml" "$tmp_ci" "chore: include shared CI template" 0
    ensure_repository_file_on_main_with_gate "$CODE_PROJECT_ID" ".gitlab/agents/${AGENT_NAME}/config.yaml" "$tmp_agent" "chore: configure GitLab Kubernetes agent" 0
    rm -f "$tmp_ci" "$tmp_agent"
  fi
  # Gate deploy-prod/rollback-prod (cf. ci-templates/gitlab-ci.yml,
  # job environment: name: prod) au rôle Maintainer -- même limite que
  # configure_main_gate (pas de niveau "Owner" dédié côté API GitLab Free/Core).
  configure_protected_environment "$CODE_PROJECT_ID" "prod" 40
done < <(read_app_code_inventory)

read -r _AGENT_EMPTY_REPO AGENT_PROJECT_ID <<<"$(ensure_project "$AGENT_PROJECT_PATH" "${AGENT_PROJECT_PATH##*/}")"
tmp_agent_config=$(mktemp)
render_agent_config_all "$tmp_agent_config"
ensure_repository_file_on_main_with_gate "$AGENT_PROJECT_ID" ".gitlab/agents/${AGENT_NAME}/config.yaml" "$tmp_agent_config" "chore: share GitLab Kubernetes agent with apps" 0
rm -f "$tmp_agent_config"
