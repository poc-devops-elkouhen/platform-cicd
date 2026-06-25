ARGOCD_NAMESPACE  ?= argocd
ARGOCD_VERSION    ?= stable
ARGOCD_INSTALL_URL = https://raw.githubusercontent.com/argoproj/argo-cd/$(ARGOCD_VERSION)/manifests/install.yaml
GITLAB_NAMESPACE  ?= gitlab
GITLAB_DOMAIN     ?= 192.168.33.100.nip.io
REGISTRY_NAMESPACE ?= registry
REGISTRY_HOSTNAME  = registry.registry.svc.cluster.local
REGISTRY_HOST      = $(REGISTRY_HOSTNAME):5000
CORPORATE_CA_LABEL ?= Zscaler

.PHONY: help bootstrap argocd-install argocd-wait argocd-bootstrap argocd-trust-corporate-ca argocd-ingress argocd-url argocd-password gitlab-wait gitlab-password gitlab-url gitlab-status gitlab-runner-token gitlab-seed gitlab-agent-token gitlab-agent-status registry-wait registry-url argocd-repo-creds argocd-apps-render helloworld-status status

help: ## Affiche cette aide
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-22s\033[0m %s\n", $$1, $$2}'

bootstrap: argocd-install argocd-wait argocd-trust-corporate-ca argocd-bootstrap argocd-ingress gitlab-wait gitlab-runner-token gitlab-seed gitlab-agent-token registry-wait argocd-repo-creds ## Deploie la plateforme sur le contexte Kubernetes courant, sans creer de cluster
	@echo ""
	@echo "Plateforme prete."
	@echo "GitLab  : http://gitlab.$(GITLAB_DOMAIN)  (root / make gitlab-password)"
	@echo "ArgoCD  : http://argocd.$(GITLAB_DOMAIN)  (admin / make argocd-password)"
	@echo "Registry: http://registry.$(GITLAB_DOMAIN)"

argocd-install: ## Installe ArgoCD dans le cluster courant
	kubectl create namespace $(ARGOCD_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply --server-side --force-conflicts -n $(ARGOCD_NAMESPACE) -f $(ARGOCD_INSTALL_URL)

argocd-wait: ## Attend que les pods ArgoCD soient prets
	kubectl -n $(ARGOCD_NAMESPACE) wait --for=condition=Available deployment --all --timeout=180s

argocd-bootstrap: ## Applique le root Application ArgoCD
	kubectl apply -n $(ARGOCD_NAMESPACE) -f argocd/root-app.yaml

argocd-trust-corporate-ca: ## Fait confiance au CA corporate dans argocd-repo-server (macOS)
	@tmpdir=$$(mktemp -d); \
	security find-certificate -a -c "$(CORPORATE_CA_LABEL)" -p /Library/Keychains/System.keychain > $$tmpdir/corporate-ca.pem; \
	repo_pod=$$(kubectl -n $(ARGOCD_NAMESPACE) get pods -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].metadata.name}'); \
	kubectl -n $(ARGOCD_NAMESPACE) exec $$repo_pod -- cat /etc/ssl/certs/ca-certificates.crt > $$tmpdir/system-ca-bundle.crt; \
	cat $$tmpdir/system-ca-bundle.crt $$tmpdir/corporate-ca.pem > $$tmpdir/merged-ca-bundle.crt; \
	kubectl -n $(ARGOCD_NAMESPACE) create configmap argocd-repo-server-ca-bundle --from-file=ca-certificates.crt=$$tmpdir/merged-ca-bundle.crt --dry-run=client -o yaml | kubectl apply -f -; \
	rm -rf $$tmpdir
	kubectl -n $(ARGOCD_NAMESPACE) patch deployment argocd-repo-server --type strategic --patch-file argocd/repo-server-ca-patch.yaml
	kubectl -n $(ARGOCD_NAMESPACE) rollout status deployment argocd-repo-server --timeout=120s

argocd-ingress: ## Configure ArgoCD en HTTP pour la HTTPRoute argocd-ui
	kubectl -n $(ARGOCD_NAMESPACE) patch configmap argocd-cmd-params-cm --type merge -p '{"data":{"server.insecure":"true"}}'
	kubectl -n $(ARGOCD_NAMESPACE) rollout restart deployment argocd-server
	kubectl -n $(ARGOCD_NAMESPACE) rollout status deployment argocd-server --timeout=120s

argocd-password: ## Affiche le mot de passe admin initial d'ArgoCD
	@kubectl -n $(ARGOCD_NAMESPACE) get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

argocd-url: ## Affiche l'URL ArgoCD
	@echo "http://argocd.$(GITLAB_DOMAIN)"

gitlab-wait: ## Attend que les pods GitLab soient prets
	kubectl -n $(GITLAB_NAMESPACE) wait --for=condition=Ready pod --all --field-selector=status.phase!=Succeeded --timeout=600s

gitlab-password: ## Affiche le mot de passe root initial de GitLab
	@kubectl -n $(GITLAB_NAMESPACE) get secret gitlab-gitlab-initial-root-password -o jsonpath='{.data.password}' | base64 -d; echo

gitlab-url: ## Affiche l'URL GitLab
	@echo "http://gitlab.$(GITLAB_DOMAIN)"

gitlab-status: ## Affiche l'etat GitLab
	@kubectl -n $(ARGOCD_NAMESPACE) get application gitlab gitlab-routes
	@kubectl -n $(GITLAB_NAMESPACE) get pods

gitlab-runner-token: ## Cree le Secret K8s du token runner
	GITLAB_NAMESPACE=$(GITLAB_NAMESPACE) GITLAB_URL=http://gitlab.$(GITLAB_DOMAIN) ./scripts/gitlab-runner-token.sh

gitlab-seed: ## Cree/seed les projets GitLab declares dans argocd/apps.yaml
	GITLAB_NAMESPACE=$(GITLAB_NAMESPACE) GITLAB_URL=http://gitlab.$(GITLAB_DOMAIN) ./scripts/gitlab-seed.sh

gitlab-agent-token: ## Enregistre l'agent Kubernetes GitLab et cree son Secret K8s
	GITLAB_NAMESPACE=$(GITLAB_NAMESPACE) GITLAB_URL=http://gitlab.$(GITLAB_DOMAIN) ./scripts/gitlab-agent-token.sh

gitlab-agent-status: ## Affiche l'etat de l'agent GitLab
	@kubectl -n $(ARGOCD_NAMESPACE) get application gitlab-agent
	@kubectl -n gitlab-agent get pods

registry-wait: ## Attend que le registry soit pret
	kubectl -n $(REGISTRY_NAMESPACE) wait --for=condition=Available deployment/registry --timeout=120s

registry-url: ## Affiche l'URL du registry
	@echo "Hote   : http://registry.$(GITLAB_DOMAIN)"
	@echo "Cluster: $(REGISTRY_HOST)"

argocd-repo-creds: ## Cree les credentials ArgoCD pour les repos manifests prives
	GITLAB_NAMESPACE=$(GITLAB_NAMESPACE) GITLAB_URL=http://gitlab.$(GITLAB_DOMAIN) ARGOCD_NAMESPACE=$(ARGOCD_NAMESPACE) ./scripts/argocd-repo-creds.sh

argocd-apps-render: ## Regenere l'ApplicationSet depuis argocd/apps.yaml
	./scripts/render-argocd-apps.rb > argocd/managed/apps-appset.yaml

helloworld-status: ## Affiche l'etat des Applications helloworld
	@kubectl -n $(ARGOCD_NAMESPACE) get application helloworld-dev helloworld-rec helloworld-preprod helloworld-prod

status: ## Affiche l'etat des Applications ArgoCD
	@kubectl -n $(ARGOCD_NAMESPACE) get applications
