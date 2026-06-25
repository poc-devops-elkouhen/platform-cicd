# Spec technique

> Le "comment" du projet : jobs CI/CD détaillés, scripts, schémas
> d'inventaire, dette IaC connue, contraintes d'infra. Pour la vision/le
> périmètre produit, voir [`prd.md`](./prd.md). Pour les règles de
> fonctionnement, voir [`spec-fonctionnelle.md`](./spec-fonctionnelle.md).

## CI/CD : chaîne d'environnements (détail des jobs)

Les jobs de déploiement déclarent un `resource_group` par branche manifests
(`manifests-dev`, `manifests-rec`, `manifests-preprod`, `manifests-prod`) pour
sérialiser les commits GitOps concurrents. Les jobs continus dev sont
`interruptible` afin qu'un nouveau merge dans `main` puisse annuler un build ou
déploiement dev obsolète ; les jobs de release restent non interruptibles.

Chaque environnement GitLab référence l'agent Kubernetes via la valeur
exacte attendue par `GITLAB_K8S_AGENT` (`root/helloworld:poc-devops` —
seul endroit où le préfixe `root/` reste écrit en toutes lettres dans cette
doc, car c'est la syntaxe `<project_path>:<agent_name>` littéralement
exigée par GitLab) et son namespace K8s (`helloworld-dev/rec/preprod/prod`)
afin d'activer le Kubernetes Dashboard GitLab en complément d'ArgoCD. Le
job `semantic-release` crée aussi une **Release GitLab** native pour `vX.Y.Z`
(notes générées depuis les Conventional Commits par
`@semantic-release/release-notes-generator`).

| Job | Activation | Build | Déploiement | Branche manifests / Namespace |
| :--- | :--- | :--- | :--- | :--- |
| `deploy-rec` | Auto, dès la création du tag `vX.Y.Z` | Build immuable (kaniko), une seule fois — le job vérifie d'abord via l'API du registry que `IMAGE:vX.Y.Z` n'existe pas déjà et échoue explicitement sinon (pas d'écrasement silencieux d'un retry) | Commit auto (`kustomize edit set image`), branche `rec` [skip ci] ➔ **Sync Auto ArgoCD** | `rec` / `<app>-rec` |
| `deploy-preprod` *(si `HAS_PREPROD`)* | Gate manuel (`when: manual`), même pipeline | **Aucun** — référence la même image `vX.Y.Z` | Commit auto (`kustomize edit set image`), branche `preprod` [skip ci] ➔ **Sync Auto ArgoCD** | `preprod` / `<app>-preprod` |
| `deploy-prod` | Gate manuel, restreint via **protected environment** GitLab au rôle `Maintainer` | **Aucun** — référence la même image `vX.Y.Z` | Commit **direct** (`kustomize edit set image`) sur la branche manifests `main` [skip ci] ➔ **Sync Auto ArgoCD** | `main` / `<app>-prod` |

Notes :
- Créer une "Release" dans l'UI GitLab ne déclenche pas de pipeline
  supplémentaire : c'est la création du tag git sous-jacent qui déclenche
  réellement la CI (`rules: if: $CI_COMMIT_TAG`).
- Le dépôt de code (`<app>`) et le dépôt de manifests (`<app>-iac`)
  restent deux projets GitLab distincts : le pipeline CI tourne dans `<app>`
  mais clone et pousse sur `<app>-iac` via `GITLAB_PUSH_TOKEN`.
- **Gate sur `main` du dépôt de code** (`<app>`) : configuré par
  `scripts/gitlab-seed.sh` (`configure_main_gate`) — branche protégée,
  `push_access_level: No one`, `merge_access_level: Maintainers`. Les
  features ne peuvent donc atteindre `main` que via une MR mergée par un
  Maintainer. L'« approbation obligatoire » (nombre d'approbateurs requis,
  API `approval_rules`) est une fonctionnalité **GitLab Premium** (`403` sur
  cette instance EE sans licence) : le contrôle d'accès par rôle est
  l'équivalent disponible en Free/Core.
- **Gate sur `main` du dépôt manifests : déplacé du git vers la CI.** Plus
  de MR pour la prod (contrairement à l'ancien modèle) : `deploy-prod` pousse
  **directement** sur `manifests/main`. Le gate n'est donc plus une
  protection de branche côté manifests, mais le **protected environment**
  GitLab côté dépôt de code, qui restreint qui a le droit de jouer le job
  `deploy-prod`. Conséquence à ne pas oublier à l'implémentation : la
  protection de branche `main` du dépôt manifests doit autoriser le push du
  token CI via `push_access_level=40` (Maintainers) — détail de cette
  valeur (pourquoi `40` et pas un niveau plus restrictif) dans "Limites
  acceptées" (PRD). `push_access_level: No one` bloquerait aussi ce push
  légitime, pas seulement les pushs humains ad hoc.
- Toutes les branches d'environnement du dépôt manifests (`dev`/`rec`/
  `preprod`?/`main`) sont désormais mises à jour de la même façon : commit
  direct de la CI, sans MR. Le seul gate humain restant est le clic sur le
  job `deploy-prod`, restreint par le protected environment.
- **Manifestes modifiés via Kustomize**, pas par édition de texte brute : un
  seul `kustomization.yaml` à la racine du dépôt manifests (pas de
  `base/`/overlay séparés — chaque branche d'environnement *est* déjà
  l'overlay, le modèle "une branche par environnement" remplit ce rôle), mis
  à jour par `kustomize edit set image <image>:<tag>` (déclaratif,
  idempotent) plutôt qu'un `sed` sur le YAML. Le tag par défaut commité au
  seed est une **version réelle déjà construite** (jamais un nom
  d'environnement type `:dev`/`:rec`/`:preprod` qui ne correspondrait à
  aucune image existante avant le premier déploiement réel sur cette
  branche) — élimine les `ErrImagePull` au bootstrap. Prêt pour le futur
  monorepo multi-services (`images:` peut lister plusieurs services en une
  seule commande).
- **`Application` ArgoCD avec `automated: { prune: true, selfHeal: true }`**
  sur tous les environnements (dev/rec/preprod/prod) : ArgoCD ne se contente
  pas de déployer depuis git, il **corrige activement** toute dérive du
  cluster par rapport à l'état déclaré (un `kubectl edit`/`kubectl patch`
  manuel sur `helloworld-prod` est automatiquement annulé). C'est ce qui
  fait du dépôt manifests la source de vérité *continue* du cluster, pas
  seulement son état initial — condition nécessaire à une philosophie
  GitOps poussée jusqu'au bout.
- **Rollback prod** : un `git revert` du commit visé sur `main` du dépôt
  manifests, poussé par un job CI générique (gate manuel) restreint par le
  même protected environment que `deploy-prod` — pas de job dédié
  paramétré par une version à reconstruire. Cohérent avec "le dépôt
  manifests définit l'état" : revenir à un état antérieur, c'est juste
  revenir à un commit antérieur. Ne dépend pas de la rétention des anciens
  pipelines GitLab CI (pas besoin de rejouer un ancien job).

## Monorepo multi-services : implémentation

**Statut : implémenté.** `helloworld` est ce monorepo multi-services : un
seul dépôt de code (`helloworld`), deux sous-dossiers/modules
`helloworld-svc` (API FastAPI) et `helloworld-gui` (frontend statique
nginx, qui appelle l'API via `helloworld-svc` en DNS interne du namespace,
`/api/` proxié — pas de configuration d'URL par stage). `argocd/apps.yaml`
porte `code:` au niveau app (pas par service) et `services: [...]` ne liste
plus que `name`/`image` par service ; `scripts/gitlab-seed.sh` crée et
seed un seul projet GitLab par app (`read_app_code_inventory`) ;
`ci-templates/gitlab-ci.yml` boucle sur `${SERVICES}` (liste
`<service>=<image>` espacée) pour le build (un `Dockerfile` par
sous-dossier) et le déploiement (plusieurs `kustomize edit set image`).

## Scaling : implémentation

- **Repo `ci-templates`** (GitLab) : héberge le pipeline générique décrit
  ci-dessus. Source locale : `ci-templates/`, seedée par `make gitlab-seed`
  dans `ci-templates` (namespace `root`) avec une ref versionnée
  (`v0.11.0` actuellement, déclarée dans `argocd/apps.yaml`).
  Le `.gitlab-ci.yml` de chaque app se réduit à un `include` de
  ce template, **`ref` épinglée à une version** (ex. `v1.3.0`, pas `main`)
  + ses variables propres (`IMAGE`, `MANIFESTS_PROJECT_PATH`, `SERVICES`,
  `HAS_PREPROD`). Corriger le pipeline = un commit dans `ci-templates` + un
  bump délibéré de la `ref` dans le `.gitlab-ci.yml` de chaque app qui veut
  l'adopter — **pas de propagation automatique** : un commit cassé dans
  `ci-templates` n'affecte aucune app tant qu'elle n'a pas explicitement
  bumpé sa `ref`. Choix délibéré au prix d'un bump manuel par app : isole le
  rayon d'impact d'une régression du template, plutôt que de la propager
  instantanément à toutes les apps.
- **Inventaire unique explicite `argocd/apps.yaml`** : source de vérité des
  projets GitLab (`code.projectPath`, `manifests.projectPath`,
  `ciTemplate.projectPath`), du repo GitOps autorisé (`manifests.repoURL`),
  des environnements (`environments[].branch`, `namespace`, `url`,
  `ingressHost`) et des restrictions ArgoCD (`argocd.sourceRepos`,
  `argocd.destinations`). Le choix est volontairement plus verbeux qu'un
  schéma "tout par convention" : la sécurité attendue est lisible directement
  dans l'inventaire, sans avoir à connaître le renderer. Consommé par deux
  mécanismes :
  - un **`ApplicationSet` ArgoCD** (generator liste) qui génère
    automatiquement, par app, les `Application` par couple app/environnement
    **et un `AppProject` dédié** — les `sourceRepos` et `destinations` sont
    recopiés depuis `argocd/apps.yaml`, pas reconstruits implicitement.
    Cloisonnement explicite : une app ne peut pas, même par erreur de
    génération ou compromission, affecter les ressources d'une autre app. Plus
    de fichier YAML à créer à la main par app. Implémentation locale :
    `scripts/render-argocd-apps.rb`, dont la sortie est committée dans
    `argocd/managed/apps-appset.yaml` (régénérée par `make
    argocd-apps-render`, à pousser sur `origin main`) et synchronisée en
    continu par le root Application "app of apps" (`argocd/root-app.yaml`,
    cf. "Point d'entrée" dans AGENTS.md).
  - **`gitlab-seed.sh` généralisé** : boucle sur l'inventaire pour créer et
    seeder les dépôts `<app>`/`<app>-iac`, configurer les gates, et
    initialiser les branches d'environnement du dépôt manifests selon
    `HAS_PREPROD`.
- **Add-ons plateforme sous ArgoCD** : le root Application synchronise aussi
  les `Application` déclarées dans `argocd/managed/` pour les composants de
  plateforme applicative : GitLab, agent Kubernetes GitLab, registry interne
  et exposition HTTP d'ArgoCD. Les add-ons cluster bas niveau (Gateway API,
  MetalLB, Traefik et Gateway partagée) sont provisionnés par Ansible.

Modifier `argocd/apps.yaml` nécessite ensuite `make argocd-apps-render` puis
`git commit`/`git push` sur `origin main` : ArgoCD (root Application) lit
GitHub, pas le disque local — sans le push, le changement n'est jamais pris
en compte.

## Routage HTTP : Gateway API, Traefik et MetalLB

La cible de routage applicatif est de migrer les expositions HTTP applicatives
du modèle `Ingress` vers **Gateway API**. Cette couche cluster est déclarée
dans Ansible, pas dans ArgoCD :

- **Gateway API CRDs** : le rôle Ansible `kubernetes-platform` applique les CRD
  standard Gateway API, versionnées par `gateway_api_version`.
- **Traefik** : le rôle Ansible `kubernetes-platform` installe le chart Helm
  Traefik avec les values rendues depuis
  `ansible/roles/kubernetes-platform/templates/traefik-values.yaml.j2`
  (`providers.kubernetesGateway.enabled=true`, `gateway.enabled=true`).
- **MetalLB** : le rôle Ansible `kubernetes-platform` installe MetalLB, puis
  applique l'`IPAddressPool` et la `L2Advertisement` rendus depuis
  `ansible/roles/kubernetes-platform/templates/metallb-config.yaml.j2`.
- **Gateway partagée** : le rôle Ansible `kubernetes-platform` applique la
  `Gateway` HTTP rendue depuis
  `ansible/roles/kubernetes-platform/templates/gateway.yaml.j2`, acceptant les
  `HTTPRoute` des namespaces applicatifs nécessaires.
- **HTTPRoute par service exposé** : les anciens `Ingress` applicatifs doivent
  être remplacés par des `HTTPRoute` qui pointent vers les `Service`
  Kubernetes de l'app.
- **Registry interne** : `argocd/managed/registry.yaml` déploie le registry
  Docker interne depuis `argocd/platform/registry/`; le `Makefile` ne fait plus
  de `kubectl apply` direct sur ce composant.
- **UI ArgoCD** : `argocd/managed/argocd-ui.yaml` déploie l'exposition HTTP
  ArgoCD depuis `argocd/platform/argocd-ui/`. La cible `make argocd-ingress`
  ne fait plus qu'activer le mode HTTP côté serveur ArgoCD.

Les applications doivent converger vers des `HTTPRoute` au lieu d'`Ingress`.
Une phase transitoire est acceptable, mais une app ne doit pas rester durablement
mixte sans décision explicite.

### Ajouter une application : séquence technique

Pour une app standard, l'intégration attendue côté plateforme est :

1. Créer les sources locales :
   - `<app>/` pour le code applicatif, avec un sous-dossier par service et un
     `Dockerfile` dans chaque sous-dossier ;
   - `<app>-iac/` pour les manifests, avec le chemin k8s déclaré dans
     `manifests.path` et un `kustomization.yaml`.
2. Ajouter l'app dans `argocd/apps.yaml`.
3. Régénérer l'ApplicationSet :
   `make argocd-apps-render`.
4. Commiter puis pousser `argocd/apps.yaml` et
   `argocd/managed/apps-appset.yaml` sur `origin main`, afin que le root
   Application ArgoCD voie le changement.
5. Lancer `make gitlab-seed` pour créer ou mettre à jour les projets GitLab,
   le `.gitlab-ci.yml` applicatif, les branches d'environnement du dépôt
   manifests, les variables CI/CD et les protections.
6. Lancer `make argocd-repo-creds` si un nouveau dépôt manifests privé a été
   ajouté, afin qu'ArgoCD puisse le lire.

Le POC demande aujourd'hui ces commandes séparées pour rendre les étapes
visibles. Une cible produit naturelle serait de regrouper les étapes 3, 5 et 6
dans une cible dédiée (`make app-register` ou équivalent) une fois le schéma
d'inventaire stabilisé.

## Dette IaC connue

La chaîne CI/CD principale (`make bootstrap`, GitLab, ArgoCD, registry,
`helloworld`, inventaire multi-apps) est
maintenant automatisée dans le dépôt.
Les anciennes interventions manuelles de bootstrap ont été absorbées par les
scripts versionnés :

- `scripts/gitlab-seed.sh` crée/seede les projets applicatifs et manifests,
  génère les `.gitlab-ci.yml`, initialise les branches d'environnement et
  configure les protections GitLab.
- `scripts/gitlab-runner-token.sh`, `scripts/gitlab-agent-token.sh` et
  `scripts/argocd-repo-creds.sh` créent les secrets nécessaires sans action
  UI.
- `scripts/render-argocd-apps.rb` génère les `AppProject` et l'`ApplicationSet`
  depuis `argocd/apps.yaml`.
- `argocd/managed/` déclare les add-ons plateforme applicative synchronisés par
  ArgoCD ; les add-ons cluster bas niveau vivent dans Ansible.
- `ansible/roles/kubernetes-platform` installe Gateway API, MetalLB, Traefik et
  la Gateway partagée pour le cluster Kubernetes Vagrant.
- Le pipeline générique couvre le tag unique `vX.Y.Z`, le build once/promote
  everywhere, les gates manuels, le rollback prod et le self-heal ArgoCD.

Dette active hors chaîne CI/CD applicative :

- **Sandbox Ansible/k8s** : le contenu `ansible/` et Vagrant reste un exercice
  d'apprentissage séparé du POC CI/CD k3d. Avant de le considérer
  reproductible, il faut supprimer les chemins propres à une machine dans
  l'inventaire Ansible.
- **Version du chart Traefik** : `traefik_chart_version` est encore vide dans
  Ansible, ce qui suit la dernière version disponible du chart. À remplacer par
  une version chart précise après validation.
- **Migration des manifests applicatifs vers `HTTPRoute`** : les apps doivent
  converger vers des `HTTPRoute` au lieu d'`Ingress`; la phase transitoire doit
  rester courte et explicite.

## Contraintes d'environnement déjà identifiées

- Cluster mono-nœud arm64 (Apple Silicon) : toute image dépendant de
  l'architecture (ex. `helper_image` du GitLab Runner) doit être épinglée en
  `arm64` explicitement.
- Pas de TLS/cert-manager sur ce cluster local : `global.hosts.https: false`
  est requis dans les values du chart GitLab, sinon les cookies de session
  sont marqués `Secure` et ne peuvent jamais être renvoyés en HTTP (boucle de
  402/422 CSRF au login).
- k3d publie déjà les ports 80/443 du load balancer vers l'hôte
  (`cluster-up` dans le `Makefile`) : tout accès UI doit passer par le
  contrôleur HTTP déclaré (Traefik via Gateway API)
  avec les hosts `*.192.168.33.100.nip.io`, pas par `kubectl port-forward` direct
  vers un service, sous peine de mismatch Host/Origin.
- Registry interne en HTTP non sécurisé : nécessite `node-trust-registry`
  (config containerd) côté nœud k3d pour que les pulls/pushs fonctionnent.
- Le pull d'image par kubelet/containerd s'exécute dans le namespace réseau du
  **nœud**, pas dans celui d'un pod : il n'a donc pas accès à CoreDNS pour
  résoudre `registry.registry.svc.cluster.local`. Nécessite `node-registry-dns`
  (entrée `/etc/hosts` statique sur le nœud vers le ClusterIP du Service) — à
  relancer si le ClusterIP du registry change (recréation du Service).

## Annexe : sandbox Ansible/k8s (hors périmètre CI/CD)

`ansible/` et `cluster/` (Vagrantfiles `master`/`node` + playbook
provisionnant `containerd`/`runc` à la main) sont un **exercice
d'apprentissage indépendant** — déployer Kubernetes "from scratch" via
Ansible sur des VMs — **sans rapport avec la chaîne CI/CD `helloworld`**
décrite dans la spec fonctionnelle, qui reste entièrement portée par k3d. Ne
pas chercher à les raccorder à `helloworld`/ArgoCD/GitLab : ce sont deux POCs
distincts qui partagent juste le même dépôt. Cf. "Dette IaC connue"
ci-dessus pour l'état d'intégration restant (committer, paramétrer le
chemin absolu, cibles `Makefile` dédiées).
