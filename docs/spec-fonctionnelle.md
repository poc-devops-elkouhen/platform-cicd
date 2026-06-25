# Spec fonctionnelle

> Les règles de fonctionnement du système : flow Git, principes CI/CD,
> règles du monorepo multi-services. Pour la vision/le périmètre produit
> (intention, objectif du scaling, non-objectifs assumés), voir
> [`prd.md`](./prd.md). Pour le détail d'implémentation (jobs, scripts,
> Makefile, contraintes infra), voir [`spec-technique.md`](./spec-technique.md).

## Flow Git : trunk-based

Chaque dépôt de code (`<app>`) a **une seule branche permanente :
`main`**, sans aucune branche `release/*` : pas de branche `develop`/`dev`
permanente (différence avec git-flow), pas de branche release intermédiaire
ni de branches d'environnement downstream dans le dépôt de code (différence
avec la variante "environment branches" du GitLab Flow) : les environnements
sont représentés par des tags côté code et par des branches dans le dépôt
manifests côté GitOps.

- **Features** : branches courtes, fusionnées dans `main` via Merge Request.
  La revue de cette MR est le gate de validation (remplace l'étape "merge
  dev→main" d'un éventuel modèle à deux branches).
- **Chaque merge dans `main`** déclenche un build mutable et un déploiement
  automatique vers l'environnement `dev` (premier environnement, continu).
- **Démarrage d'une release** : un job CI (`semantic-release`), déclenché
  manuellement (ex. "Run pipeline" sur `main`), analyse les Conventional
  Commits (`feat:`/`fix:`/`refactor:`/...) accumulés depuis le dernier tag et
  en déduit automatiquement le numéro de version — plus de variable
  `VERSION` choisie à la main. Le job pousse directement le tag `vX.Y.Z` sur
  `main` (plus de branche `release/vX.Y.Z` intermédiaire) et crée la Release
  GitLab correspondante (notes générées depuis les commits). Codifié en CI
  (pas de commande git manuelle), mais toujours déclenché par une décision
  humaine délibérée : seul le *numéro* de version est automatique, pas le
  *moment* de la release. À partir de là, `main` continue d'avancer
  librement avec de nouvelles features — **aucun gel, aucun blocage des
  devs**. Un commit qui ne porte aucun type Conventional Commits reconnu
  (ex. `wip`) ne déclenche aucun bump de version : le job se termine sans
  rien publier.
- **Bug détecté pendant la validation** (rec, préprod) ou **en prod** (après
  que `deploy-prod` a tourné) : un seul chemin, sans distinction — pas de
  hotfix séparé, délibérément, pour ne pas introduire une deuxième voie de
  promotion avec ses propres règles. On annule le pipeline de promotion en
  cours, le correctif part comme un commit `fix:` (ou `feat:`) normal mergé
  sur `main` via MR classique, ce qui déclenche un **nouveau cycle complet**
  : nouvelle version calculée par `semantic-release`, nouveau tag, pipeline
  entier rejoué depuis `rec`, cycle de gates remis à zéro. Pas de suffixe de
  pré-release (`-alpha.N`/`-beta.N`) : chaque tentative complète porte son
  propre numéro de version. La rapidité d'un correctif urgent vient du fait
  que les gates manuels sont de simples clics, pas d'un mécanisme dédié.
  Conséquence acceptée : sans branche `release/*`, plus de garde-fou
  technique "une seule release à la fois" — rien n'empêche techniquement un
  nouveau tag d'être coupé pendant qu'une release précédente est encore en
  cours de validation.

## CI/CD : principe de la chaîne d'environnements

Principe directeur : **build once, promote everywhere**, au sens littéral —
**un seul tag `vX.Y.Z`** du début à la fin de la chaîne, **une seule image**
construite (au stade rec), simplement référencée (même tag) dans les
manifestes des stades suivants. Aucune opération registry de re-tag, pas de
`skopeo` : promouvoir un service inchangé d'un stade à l'autre, c'est juste
recopier la même référence d'image dans le manifeste suivant.

Chaque app déclare un drapeau `HAS_PREPROD` (true/false) qui active ou non
le stade intermédiaire `preprod` — les deux variantes partagent le même
pipeline générique (cf. "Scaling").

**1. Dev** — déclencheur séparé, continu : chaque merge dans `main` build
une image mutable (`<sha-court>` et `dev`) et déploie automatiquement vers
`<app>-dev` (commit auto sur la branche manifests `dev`).

**2-4. Pipeline unique de promotion** — un seul tag `vX.Y.Z`, créé directement
sur `main` par le job `semantic-release`, déclenche **un seul pipeline**
contenant toute la chaîne (rec → préprod → prod), avec des gates GitLab CI
natifs (`when: manual`) entre les stades. Le détail des jobs, branches et
namespaces par stade est dans la spec technique.

## Monorepo multi-services

Une app peut être un monorepo contenant plusieurs services (ex. un
frontend + un backend, ou N microservices), chacun dans son propre
sous-dossier avec son propre `Dockerfile`.

- **Versioning au niveau app** : un seul tag `vX.Y.Z` déclenche le build/la
  promotion de la chaîne pour tous les services de l'app ensemble (pas de
  tags indépendants par service).
- **Pas de build sélectif : tous les modules du repo sont buildés à la
  création de la release**, que leur contenu ait changé ou non. Chaque
  service obtient directement une image taguée `<service>:vX.Y.Z` — le tag
  de release est donc aussi, littéralement, le tag d'image de chaque
  service (pas de hash de contenu, pas de label séparé : inutile puisque
  tous les services sont rebuildés ensemble, donc toujours cohérents entre
  eux sous le même tag).
  - **Pourquoi pas de build sélectif** : ça évite les deux problèmes
    identifiés avec une approche "ne builder que ce qui a changé" — A)
    incohérence de version entre services (certains restent sur un ancien
    tag), B) fiabilité de la détection de changement sur un pipeline
    déclenché par tag (`rules: changes:` compare par défaut au commit
    précédent, peu pertinent sur une branche release où les tags sont
    espacés). Coût accepté : du temps de build gaspillé pour les modules
    inchangés — optimisable plus tard (cache, hash de contenu) si ça devient
    un vrai problème à l'échelle, pas nécessaire pour l'instant.
- **À chaque étape de la chaîne** (rec → préprod → prod), le job CI/CD met à
  jour les fichiers manifestes via Kustomize — un déploiement par service,
  chacun mis à jour pour référencer `<service>:vX.Y.Z`. Cohérent avec
  "build once, promote everywhere" : un seul build (à rec, pour tous les
  services), puis simple recopie de la même référence d'image dans le
  manifeste de chaque stade suivant — aucune opération registry, comme pour
  le cas single-service.

**Statut : implémenté.** Détail de l'implémentation (`helloworld-svc`/
`helloworld-gui`, schéma `argocd/apps.yaml`, `gitlab-seed.sh`,
`ci-templates/gitlab-ci.yml`) dans la spec technique.

## Scaling : pattern réplicable pour plusieurs apps

Cf. "Objectif du scaling" dans le [PRD](./prd.md) pour le pourquoi. Le
mécanisme (repo `ci-templates`, inventaire `argocd/apps.yaml`,
`ApplicationSet` ArgoCD, `gitlab-seed.sh` généralisé) est détaillé dans la
spec technique.

### Parcours fonctionnel : ajouter une application

Le parcours cible pour une app standard est volontairement court :

1. Ajouter le dépôt de code local de l'app, avec un sous-dossier par service
   et un `Dockerfile` par service.
2. Ajouter le dépôt local de manifests GitOps de l'app, avec les manifests
   Kubernetes et un `kustomization.yaml` sous le chemin déclaré.
3. Ajouter une entrée dans `argocd/apps.yaml` : nom de l'app, dépôt de code,
   dépôt manifests, services, images, environnements et option `hasPreprod`.
4. Régénérer les Applications ArgoCD depuis l'inventaire.
5. Seeder GitLab pour créer ou mettre à jour les projets, branches, variables
   CI/CD et protections nécessaires.
6. Pousser le changement GitOps sur le dépôt source lu par ArgoCD.

À la fin de ce parcours, l'utilisateur doit obtenir sans action manuelle :

- un projet GitLab de code avec un `.gitlab-ci.yml` généré depuis le template
  partagé ;
- un projet GitLab de manifests avec les branches d'environnement ;
- des Applications ArgoCD par environnement ;
- un déploiement automatique vers `dev` au prochain merge sur `main` ;
- une chaîne de promotion release prête à être jouée depuis GitLab CI.

Les champs redondants de l'inventaire (`repoURL`, namespaces, URLs,
destinations ArgoCD, secrets) sont acceptés dans le POC pour garder la sécurité
lisible explicitement. La cible produit reste de pouvoir dériver ces valeurs
par convention pour réduire la saisie côté utilisateur, tout en conservant des
overrides explicites pour les cas avancés.
