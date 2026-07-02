SHELL := /bin/bash -e -o pipefail
.SHELLFLAGS := -e -o pipefail -c

ARGOCD_NAMESPACE  ?= argocd
ARGOCD_VERSION    ?= v3.4.4
ARGOCD_WAIT_TIMEOUT ?= 600s
GITLAB_READY_TIMEOUT ?= 600
GITLAB_NAMESPACE  ?= gitlab
GITLAB_DOMAIN     ?= 192.168.33.100.nip.io
CORPORATE_CA_LABEL ?= Zscaler
GITOPS_REPO_ROOT   ?= ../platform-gitops
GITOPS_APPS_FILE   = $(GITOPS_REPO_ROOT)/argocd/apps.yaml
FLUX_NAMESPACE    ?= flux-system
SOPS_AGE_KEY_FILE ?= $(HOME)/.config/sops/age/keys.txt
START_AT ?=
STOP_AFTER ?=
BOOTSTRAP_STEPS = argocd-install argocd-trust-corporate-ca argocd-trust-local-gateway-ca argocd-bootstrap flux-sops-age argocd-ingress gitlab-tf-credentials gitlab-dex-oauth-app gitlab-runner-token

# Le rôle Ansible platform_bootstrap vit dans cluster/ansible (dépôt voisin,
# checkout sibling requis) ; platform-cicd ne porte plus que ses scripts et
# manifests (scripts/, argocd/), consommés via platform_cicd_root.
ANSIBLE_DIR = ../cluster/ansible

# Variables transmises telles quelles au rôle platform_bootstrap (mêmes
# defaults des deux côtés). Chaque cible ci-dessous ne fait que sélectionner
# les tags à exécuter ; le séquencement lui-même est porté par Ansible.
ANSIBLE_VARS = \
  -e argocd_namespace=$(ARGOCD_NAMESPACE) \
  -e argocd_version=$(ARGOCD_VERSION) \
  -e argocd_wait_timeout=$(ARGOCD_WAIT_TIMEOUT) \
  -e corporate_ca_label=$(CORPORATE_CA_LABEL) \
  -e flux_namespace=$(FLUX_NAMESPACE) \
  -e sops_age_key_file=$(SOPS_AGE_KEY_FILE) \
  -e gitlab_domain=$(GITLAB_DOMAIN) \
  -e gitlab_namespace=$(GITLAB_NAMESPACE) \
  -e gitlab_ready_timeout=$(GITLAB_READY_TIMEOUT) \
  -e platform_cicd_root=$(CURDIR)

.PHONY: help bootstrap bootstrap-from-% argocd-install argocd-bootstrap argocd-trust-corporate-ca argocd-trust-local-gateway-ca argocd-ingress argocd-url argocd-password gitlab-password gitlab-url gitlab-status gitlab-tf-credentials gitlab-dex-oauth-app gitlab-runner-token argocd-apps-render check-generated init-project status flux-sops-age

help: ## Affiche cette aide
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-22s\033[0m %s\n", $$1, $$2}'

bootstrap: ## Deploie la plateforme sur le contexte Kubernetes courant (un seul ansible-playbook), relancable avec START_AT=<etape>
	@tags=$$(python3 ./scripts/bootstrap-tags.py --start-at "$(START_AT)" --stop-after "$(STOP_AFTER)" $(BOOTSTRAP_STEPS)); \
	echo "==> platform-cicd: bootstrap (ansible) --tags $$tags"; \
	cd $(ANSIBLE_DIR) && ansible-playbook playbook-platform.yml --tags "$$tags" $(ANSIBLE_VARS)
	@echo ""
	@echo "Plateforme prete."
	@echo "GitLab : https://gitlab.$(GITLAB_DOMAIN)  (root / make gitlab-password)"
	@echo "ArgoCD : https://argocd.$(GITLAB_DOMAIN)  (admin / make argocd-password)"
	@echo "Registry: ghcr.io (GitHub Container Registry)"

bootstrap-from-%: ## Reprend le bootstrap depuis une etape donnee
	$(MAKE) bootstrap START_AT=$*

argocd-install: ## Installe ArgoCD dans le cluster courant
	@echo "==> platform-cicd: argocd-install (ansible)"
	cd $(ANSIBLE_DIR) && ansible-playbook playbook-platform.yml --tags argocd-install $(ANSIBLE_VARS)

argocd-bootstrap: ## Applique le root Application ArgoCD
	@echo "==> platform-cicd: argocd-bootstrap (ansible)"
	cd $(ANSIBLE_DIR) && ansible-playbook playbook-platform.yml --tags argocd-bootstrap $(ANSIBLE_VARS)

argocd-trust-corporate-ca: ## Cree le ConfigMap CA corporate pour argocd-repo-server (macOS)
	@echo "==> platform-cicd: argocd-trust-corporate-ca (ansible)"
	cd $(ANSIBLE_DIR) && ansible-playbook playbook-platform.yml --tags argocd-trust-corporate-ca $(ANSIBLE_VARS)

argocd-trust-local-gateway-ca: ## Cree le ConfigMap CA local pour Dex/GitLab OAuth
	@echo "==> platform-cicd: argocd-trust-local-gateway-ca (ansible)"
	cd $(ANSIBLE_DIR) && ansible-playbook playbook-platform.yml --tags argocd-trust-local-gateway-ca $(ANSIBLE_VARS)

argocd-ingress: ## Configure ArgoCD en HTTP (bootstrap uniquement ; server.insecure est ensuite maintenu par l'Application argocd-config)
	@echo "==> platform-cicd: argocd-ingress (ansible)"
	cd $(ANSIBLE_DIR) && ansible-playbook playbook-platform.yml --tags argocd-ingress $(ANSIBLE_VARS)

argocd-password: ## Affiche le mot de passe admin initial d'ArgoCD
	@kubectl -n $(ARGOCD_NAMESPACE) get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

argocd-url: ## Affiche l'URL ArgoCD
	@echo "http://argocd.$(GITLAB_DOMAIN)"

gitlab-password: ## Affiche le mot de passe root initial de GitLab
	@kubectl -n $(GITLAB_NAMESPACE) get secret gitlab-gitlab-initial-root-password -o jsonpath='{.data.password}' | base64 -d; echo

gitlab-url: ## Affiche l'URL GitLab
	@echo "https://gitlab.$(GITLAB_DOMAIN)"

gitlab-status: ## Affiche l'etat GitLab
	@kubectl -n $(ARGOCD_NAMESPACE) get application gitlab gitlab-routes
	@kubectl -n $(GITLAB_NAMESPACE) get pods

gitlab-tf-credentials: ## Cree le PAT GitLab et le Secret K8s consomme par Terraform
	@echo "==> platform-cicd: gitlab-tf-credentials (ansible)"
	cd $(ANSIBLE_DIR) && ansible-playbook playbook-platform.yml --tags gitlab-tf-credentials $(ANSIBLE_VARS)

gitlab-dex-oauth-app: ## Cree l'application OAuth GitLab pour Dex et renseigne argocd-secret
	@echo "==> platform-cicd: gitlab-dex-oauth-app (ansible)"
	cd $(ANSIBLE_DIR) && ansible-playbook playbook-platform.yml --tags gitlab-dex-oauth-app $(ANSIBLE_VARS)

gitlab-runner-token: ## Cree le Secret K8s du token runner
	@echo "==> platform-cicd: gitlab-runner-token (ansible)"
	cd $(ANSIBLE_DIR) && ansible-playbook playbook-platform.yml --tags gitlab-runner-token $(ANSIBLE_VARS)

argocd-apps-render: ## Genere les manifests ArgoCD depuis argocd/apps/<app>/app.yaml
	APPS_FILE="$(GITOPS_APPS_FILE)" python3 ./scripts/render-argocd-apps.py

check-generated: ## Verifie que les manifests apps generes sont a jour
	APPS_FILE="$(GITOPS_APPS_FILE)" python3 ./scripts/render-argocd-apps.py --check

init-project: ## Deprecated: creer argocd/apps/<app>/ directement
	@echo "Creer argocd/apps/<app>/app.yaml puis lancer make argocd-apps-render." >&2
	@exit 1

flux-sops-age: ## Injecte la cle age privee dans flux-system pour le dechiffrement SOPS (bootstrap uniquement)
	@echo "==> platform-cicd: flux-sops-age (ansible)"
	cd $(ANSIBLE_DIR) && ansible-playbook playbook-platform.yml --tags flux-sops-age $(ANSIBLE_VARS)

status: ## Affiche l'etat des Applications ArgoCD
	@kubectl -n $(ARGOCD_NAMESPACE) get applications
