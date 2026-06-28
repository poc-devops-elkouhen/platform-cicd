# platform-cicd

Bootstrap technique de la plateforme applicative du POC : ArgoCD, GitLab,
GitLab Runner, GitLab Agent, registry interne et routes HTTP Gateway API.

Ce repo se deploie sur le contexte Kubernetes courant. Il ne cree pas de
cluster. La configuration suivie en continu par ArgoCD vit dans le repo frere
`../platform-gitops`.

## Prerequis

- Un cluster Kubernetes deja provisionne par `cluster`.
- Gateway API, Traefik et MetalLB disponibles.
- Les repos freres clones a cote de celui-ci :
  - `../ci-templates`
  - `../helloworld`
  - `../helloworld-iac`
  - `../platform-gitops`

## Usage

```sh
make bootstrap
```

URLs par defaut :

- GitLab : `http://gitlab.192.168.33.100.nip.io`
- ArgoCD : `http://argocd.192.168.33.100.nip.io`
- Registry : `http://registry.192.168.33.100.nip.io`
