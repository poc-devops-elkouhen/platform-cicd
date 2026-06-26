# PRD

> Vision et périmètre du produit : ce que ce POC vise à démontrer, et ce
> qu'il ne couvre délibérément pas. Pour les règles de fonctionnement
> détaillées (flow Git, principes CI/CD, monorepo), voir
> [`spec-fonctionnelle.md`](./spec-fonctionnelle.md). Pour le détail
> d'implémentation, voir [`spec-technique.md`](./spec-technique.md).

## Intention du projet

Ce dépôt est un POC d'une chaîne CI/CD relativement complète, autohébergée sur
un cluster Kubernetes local (k3d). Tous les projets GitLab sont créés sous le
namespace personnel `root` (seul utilisateur de cette instance) ; les noms de
dépôts ci-dessous omettent donc ce préfixe par souci de lisibilité.

- **k3d** : cluster Kubernetes local (1 nœud serveur, 0 agent).
- **ArgoCD** : GitOps, pilote le déploiement des composants plateforme et des
  applications via des `Application`.
- **GitLab** (chart Helm officiel, déployé en `Application` ArgoCD) : héberge
  le code et exécute les pipelines CI/CD via GitLab Runner (in-cluster).
- **Registry Docker interne** (`registry:2`, déployé par ArgoCD) : stocke les
  images construites par la CI, sans dépendance à un registre externe.
- **Add-ons réseau** (Traefik, Gateway API, MetalLB, Gateway partagée) :
  déclarés dans Ansible pour que la configuration cluster bas niveau soit
  reproductible avant le bootstrap ArgoCD.
- **helloworld** : application de référence implémentant le pattern CI/CD
  décrit dans la spec fonctionnelle : build (Kaniko) → push registry →
  déploiement (commit GitOps sur les manifests, synchronisé par ArgoCD). Le
  code applicatif et les manifests k8s sont scindés en **deux dépôts GitLab
  séparés** :
  - `helloworld` (code) : monorepo multi-services (`helloworld-svc`,
    `helloworld-gui`) + `.gitlab-ci.yml` généré depuis le template CI —
    source locale : `helloworld/`.
  - `helloworld-iac` (config GitOps) : manifests Kubernetes des services,
    sous `k8s/` — source locale : `helloworld-iac/`. Suivi par des
    Applications ArgoCD, une par branche d'environnement.

Le pattern CI/CD est conçu pour être répliqué à l'identique sur des dizaines
d'applications (cf. "Objectif du scaling" ci-dessous) — `helloworld` n'en est
que la première implémentation.

## Objectif du scaling

Ajouter une app au pattern doit se résumer à ajouter un fichier d'app dans un
inventaire déclaratif, pas à dupliquer de la logique CI/GitOps. Le mécanisme
qui réalise cet objectif (repo `ci-templates`, index `argocd/apps.yaml`,
fichiers `argocd/apps/*.yaml`, `ApplicationSet` ArgoCD, `gitlab-seed.py`
généralisé et toolbox `poc-devops-toolbox`) est détaillé dans la spec
technique.

## Expérience utilisateur cible

Le produit attendu n'est pas seulement une chaîne CI/CD fonctionnelle : c'est
une chaîne simple à consommer par une équipe applicative. Pour intégrer une
nouvelle app, l'utilisateur doit fournir le code, les manifests Kubernetes et
une entrée d'inventaire ; la plateforme crée ensuite les projets GitLab,
configure la CI, branche ArgoCD, initialise les environnements et rend l'app
déployable sans duplication de pipeline.

Critères d'acceptation du POC :

- **Peu d'étapes** : après ajout des sources locales et du fichier
  `argocd/apps/<app>.yaml`, une commande de seed/rendu doit suffire à préparer
  GitLab et ArgoCD.
- **Aucune création manuelle** dans GitLab, ArgoCD ou Kubernetes pour une app
  standard.
- **Aucune logique CI dupliquée** dans les dépôts applicatifs : le
  `.gitlab-ci.yml` d'une app inclut le template versionné et porte seulement
  ses variables propres.
- **Résultat visible** : l'app apparaît dans GitLab, dans ArgoCD, et dispose
  de ses environnements `dev`, `rec`, `preprod` optionnel et `prod`.
- **Chemin de promotion uniforme** : une release applicative suit toujours le
  même parcours `rec` → `preprod` optionnel → `prod`, avec les mêmes gates.

## Limites acceptées (non-objectifs explicites du POC)

Ces points ne sont **pas** prévus d'être corrigés dans le cadre de ce POC —
ils sont documentés explicitement pour ne pas être (re)découverts comme des
oublis, et pour identifier ce qui deviendrait nécessaire avec une vraie
équipe :

- **Branches d'environnement du dépôt manifests (`dev`/`rec`/`preprod`) non
  protégées contre un push humain direct** : seule `main` (manifests) est
  protégée. N'importe qui avec un accès push peut donc, en dehors de toute
  CI, committer un état arbitraire sur ces branches — le self-heal ArgoCD
  protège contre une dérive *cluster vs git*, pas contre une dérive humaine
  *directement dans git*. Pas de gate technique pour l'instant : dans ce POC
  mono-opérateur, l'identité qui détient le token CI (`root`) est la même
  que l'identité humaine avec accès git — une protection de branche par rôle
  GitLab ne distinguerait pas l'une de l'autre. Deviendrait nécessaire avec
  une vraie équipe : un compte de service dédié à la CI, distinct des
  comptes humains, permettant de protéger ces branches en n'autorisant que
  ce compte à y pousser.
- **`main` du dépôt manifests : protégée au rôle Maintainer
  (`push_access_level=40`), pas au seul token CI.** Limite identique à celle
  ci-dessus, pour une raison différente : c'est une limite de l'API GitLab
  elle-même, pas un choix. Il n'existe pas de niveau `Owner` pour les
  branches protégées (`push_access_level=50` → 400 "does not have a valid
  value"), et restreindre le push à un utilisateur précis
  (`allowed_to_push` `user_id`) est une fonctionnalité **GitLab Premium**
  (→ 422 "must be blank" sur cette instance sans licence, même schéma que
  `approval_rules` déjà documenté ailleurs). `Maintainer` est donc le niveau
  le moins permissif disponible en Free/Core qui laisse passer le token
  personnel `root` — tout Maintainer humain peut en théorie aussi pousser
  directement. Même mitigation qu'au-dessus (mono-opérateur, root = seul
  Maintainer) ; deviendrait nécessaire de revisiter avec une vraie équipe.
- **`GITLAB_PUSH_TOKEN` est un token personnel `root` avec le scope `api`
  complet** (accès admin à toute l'instance GitLab), pas un token scopé par
  projet. Le réutiliser pour toutes les apps lors du "Scaling" maximiserait
  le rayon d'explosion en cas de fuite (logs CI mal masqués, runner
  compromis). Cible long terme : un **token de projet** (`project access
  token`) par couple `<app>`/`<app>-manifests`, scopé au strict nécessaire.
  Acceptable de garder le token root partagé pour ce POC mono-app ; à
  traiter avant tout "Scaling" réel avec plusieurs apps/équipes.
