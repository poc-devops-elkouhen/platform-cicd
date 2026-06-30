ARGOCD_NAMESPACE  ?= argocd
ARGOCD_VERSION    ?= v3.4.4
ARGOCD_WAIT_TIMEOUT ?= 600s
ARGOCD_INSTALL_URL = https://raw.githubusercontent.com/argoproj/argo-cd/$(ARGOCD_VERSION)/manifests/install.yaml
ARGOCD_INSTALL_FILTER = scripts/filter-argocd-install.py
GITLAB_NAMESPACE  ?= gitlab
GITLAB_DOMAIN     ?= 192.168.33.100.nip.io
CORPORATE_CA_LABEL ?= Zscaler
GITOPS_REPO_ROOT   ?= ../platform-gitops
GITOPS_APPS_FILE   = $(GITOPS_REPO_ROOT)/argocd/apps.yaml
GITOPS_APPSET_FILE = $(GITOPS_REPO_ROOT)/argocd/managed/apps-appset.yaml
FLUX_NAMESPACE    ?= flux-system
SOPS_AGE_KEY_FILE ?= $(HOME)/.config/sops/age/keys.txt

.PHONY: help bootstrap argocd-install argocd-wait argocd-bootstrap argocd-trust-corporate-ca argocd-trust-local-gateway-ca argocd-ingress argocd-url argocd-password gitlab-wait gitlab-password gitlab-url gitlab-status gitlab-dex-oauth-app gitlab-runner-token argocd-apps-render check-generated init-project helloworld-status status flux-sops-age

help: ## Affiche cette aide
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-22s\033[0m %s\n", $$1, $$2}'

bootstrap: argocd-install argocd-wait argocd-trust-corporate-ca argocd-trust-local-gateway-ca argocd-bootstrap flux-sops-age argocd-ingress gitlab-wait gitlab-dex-oauth-app gitlab-runner-token ## Deploie la plateforme sur le contexte Kubernetes courant, sans creer de cluster
	@echo ""
	@echo "Plateforme prete."
	@echo "GitLab : https://gitlab.$(GITLAB_DOMAIN)  (root / make gitlab-password)"
	@echo "ArgoCD : https://argocd.$(GITLAB_DOMAIN)  (admin / make argocd-password)"
	@echo "Registry: ghcr.io (GitHub Container Registry)"

argocd-install: ## Installe ArgoCD dans le cluster courant
	@echo "==> platform-cicd: argocd-install"
	kubectl create namespace $(ARGOCD_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	python3 $(ARGOCD_INSTALL_FILTER) "$(ARGOCD_INSTALL_URL)" | kubectl apply --server-side --force-conflicts -n $(ARGOCD_NAMESPACE) -f -

argocd-wait: ## Attend que les pods ArgoCD soient prets
	@echo "==> platform-cicd: argocd-wait"
	kubectl -n $(ARGOCD_NAMESPACE) wait --for=condition=Available deployment --all --timeout=$(ARGOCD_WAIT_TIMEOUT)

argocd-bootstrap: ## Applique le root Application ArgoCD
	@echo "==> platform-cicd: argocd-bootstrap"
	kubectl apply -n $(ARGOCD_NAMESPACE) -f argocd/root-app.yaml

argocd-trust-corporate-ca: ## Cree le ConfigMap CA corporate pour argocd-repo-server (macOS)
	@echo "==> platform-cicd: argocd-trust-corporate-ca"
	@tmpdir=$$(mktemp -d); \
	security find-certificate -a -c "$(CORPORATE_CA_LABEL)" -p /Library/Keychains/System.keychain > $$tmpdir/corporate-ca.pem; \
	repo_pod=$$(kubectl -n $(ARGOCD_NAMESPACE) get pods -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].metadata.name}'); \
	kubectl -n $(ARGOCD_NAMESPACE) exec $$repo_pod -- cat /etc/ssl/certs/ca-certificates.crt > $$tmpdir/system-ca-bundle.crt; \
	cat $$tmpdir/system-ca-bundle.crt $$tmpdir/corporate-ca.pem > $$tmpdir/merged-ca-bundle.crt; \
	kubectl -n $(ARGOCD_NAMESPACE) create configmap argocd-repo-server-ca-bundle --from-file=ca-certificates.crt=$$tmpdir/merged-ca-bundle.crt --dry-run=client -o yaml | kubectl apply -f -; \
	rm -rf $$tmpdir
	kubectl -n $(ARGOCD_NAMESPACE) patch deployment argocd-repo-server --type strategic --patch-file argocd/repo-server-ca-patch.yaml
	kubectl -n $(ARGOCD_NAMESPACE) rollout status deployment argocd-repo-server --timeout=$(ARGOCD_WAIT_TIMEOUT)

argocd-trust-local-gateway-ca: ## Cree le ConfigMap CA local pour Dex/GitLab OAuth
	@echo "==> platform-cicd: argocd-trust-local-gateway-ca"
	@tmpdir=$$(mktemp -d); \
	dex_pod=$$(kubectl -n $(ARGOCD_NAMESPACE) get pods -l app.kubernetes.io/name=argocd-dex-server -o jsonpath='{.items[0].metadata.name}'); \
	kubectl -n $(ARGOCD_NAMESPACE) exec $$dex_pod -c dex -- cat /etc/ssl/certs/ca-certificates.crt > $$tmpdir/system-ca-bundle.crt; \
	kubectl -n default get secret nip-io-wildcard-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > $$tmpdir/nip-io-wildcard.crt; \
	cat $$tmpdir/system-ca-bundle.crt $$tmpdir/nip-io-wildcard.crt > $$tmpdir/merged-ca-bundle.crt; \
	kubectl -n $(ARGOCD_NAMESPACE) create configmap argocd-dex-ca-bundle --from-file=ca-certificates.crt=$$tmpdir/merged-ca-bundle.crt --dry-run=client -o yaml | kubectl apply -f -; \
	rm -rf $$tmpdir
	kubectl -n $(ARGOCD_NAMESPACE) patch deployment argocd-dex-server --type strategic --patch-file argocd/dex-ca-patch.yaml
	kubectl -n $(ARGOCD_NAMESPACE) rollout status deployment argocd-dex-server --timeout=$(ARGOCD_WAIT_TIMEOUT)

argocd-ingress: ## Configure ArgoCD en HTTP (bootstrap uniquement ; server.insecure est ensuite maintenu par l'Application argocd-config)
	@echo "==> platform-cicd: argocd-ingress"
	kubectl -n $(ARGOCD_NAMESPACE) patch configmap argocd-cmd-params-cm --type merge -p '{"data":{"server.insecure":"true"}}'
	kubectl -n $(ARGOCD_NAMESPACE) rollout restart deployment argocd-server
	kubectl -n $(ARGOCD_NAMESPACE) rollout status deployment argocd-server --timeout=$(ARGOCD_WAIT_TIMEOUT)

argocd-password: ## Affiche le mot de passe admin initial d'ArgoCD
	@kubectl -n $(ARGOCD_NAMESPACE) get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

argocd-url: ## Affiche l'URL ArgoCD
	@echo "http://argocd.$(GITLAB_DOMAIN)"

gitlab-wait: ## Attend que les pods GitLab soient prets
	@echo "==> platform-cicd: gitlab-wait"
	kubectl -n $(GITLAB_NAMESPACE) wait --for=condition=Ready pod --all --field-selector=status.phase!=Succeeded --timeout=600s

gitlab-password: ## Affiche le mot de passe root initial de GitLab
	@kubectl -n $(GITLAB_NAMESPACE) get secret gitlab-gitlab-initial-root-password -o jsonpath='{.data.password}' | base64 -d; echo

gitlab-url: ## Affiche l'URL GitLab
	@echo "https://gitlab.$(GITLAB_DOMAIN)"

gitlab-status: ## Affiche l'etat GitLab
	@kubectl -n $(ARGOCD_NAMESPACE) get application gitlab gitlab-routes
	@kubectl -n $(GITLAB_NAMESPACE) get pods

gitlab-dex-oauth-app: ## Cree l'application OAuth GitLab pour Dex et renseigne argocd-secret
	@echo "==> platform-cicd: gitlab-dex-oauth-app"
	GITLAB_NAMESPACE=$(GITLAB_NAMESPACE) ARGOCD_NAMESPACE=$(ARGOCD_NAMESPACE) GITLAB_URL=https://gitlab.$(GITLAB_DOMAIN) ARGOCD_URL=https://argocd.$(GITLAB_DOMAIN) python3 ./scripts/gitlab-dex-oauth-app.py

gitlab-runner-token: ## Cree le Secret K8s du token runner
	@echo "==> platform-cicd: gitlab-runner-token"
	GITLAB_NAMESPACE=$(GITLAB_NAMESPACE) GITLAB_URL=https://gitlab.$(GITLAB_DOMAIN) python3 ./scripts/gitlab-runner-token.py


argocd-apps-render: ## Regenere l'ApplicationSet depuis l'inventaire apps
	APPS_FILE="$(GITOPS_APPS_FILE)" python3 ./scripts/render-argocd-apps.py > "$(GITOPS_APPSET_FILE)"

check-generated: ## Verifie que les manifests generes sont a jour
	@tmpfile=$$(mktemp); \
	APPS_FILE="$(GITOPS_APPS_FILE)" python3 ./scripts/render-argocd-apps.py > $$tmpfile; \
	if ! cmp -s $$tmpfile "$(GITOPS_APPSET_FILE)"; then \
	  echo "$(GITOPS_APPSET_FILE) n'est pas a jour. Lancez: make argocd-apps-render" >&2; \
	  rm -f $$tmpfile; \
	  exit 1; \
	fi; \
	rm -f $$tmpfile

init-project: ## Ajoute/met a jour une app: make init-project CODE_REPO=<url-ou-chemin> IAC_REPO=<url-ou-chemin>
	@test -n "$(CODE_REPO)" || (echo "CODE_REPO est requis" >&2; exit 1)
	@test -n "$(IAC_REPO)" || (echo "IAC_REPO est requis" >&2; exit 1)
	APPS_FILE="$(GITOPS_APPS_FILE)" ./scripts/init-project.py "$(CODE_REPO)" "$(IAC_REPO)"

flux-sops-age: ## Injecte la cle age privee dans flux-system pour le dechiffrement SOPS (bootstrap uniquement)
	@test -f "$(SOPS_AGE_KEY_FILE)" || (echo "SOPS_AGE_KEY_FILE=$(SOPS_AGE_KEY_FILE) introuvable" >&2; exit 1)
	@echo "==> platform-cicd: flux-sops-age"
	kubectl create namespace $(FLUX_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl create secret generic sops-age \
	  --namespace $(FLUX_NAMESPACE) \
	  --from-file=age.agekey="$(SOPS_AGE_KEY_FILE)" \
	  --dry-run=client -o yaml \
	  | kubectl apply -f -

helloworld-status: ## Affiche l'etat des Applications helloworld
	@kubectl -n $(ARGOCD_NAMESPACE) get application helloworld-dev helloworld-rec helloworld-preprod helloworld-prod

status: ## Affiche l'etat des Applications ArgoCD
	@kubectl -n $(ARGOCD_NAMESPACE) get applications
