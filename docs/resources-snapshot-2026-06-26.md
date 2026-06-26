# Snapshot ressources cluster — 2026-06-26

> `kubectl top pods` + requests/limits — worker-01 (8 Go RAM, 4 vCPU)

| Namespace | Pod | CPU Req (m) | CPU Lim (m) | CPU Use (m) | RAM Req (Mi) | RAM Lim (Mi) | RAM Use (Mi) |
|---|---|---:|---:|---:|---:|---:|---:|
| **argocd** | argocd-application-controller | — | — | 4 | — | — | 386 |
| **argocd** | argocd-applicationset-controller | — | — | 1 | — | — | 34 |
| **argocd** | argocd-redis | — | — | 3 | — | — | 15 |
| **argocd** | argocd-repo-server | — | — | 2 | — | — | 68 |
| **argocd** | argocd-server | — | — | 1 | — | — | 101 |
| **gitlab** | gitlab-gitaly | 100 | — | 9 | 200 | — | 263 |
| **gitlab** | gitlab-gitlab-runner | — | — | 1 | — | — | 42 |
| **gitlab** | gitlab-gitlab-shell | — | — | 9 | 6 | — | 21 |
| **gitlab** | gitlab-postgresql | 250 | — | 8 | 256 | — | 261 |
| **gitlab** | gitlab-redis-master | — | — | 20 | — | — | 35 |
| **gitlab** | gitlab-sidekiq | 300 | — | 64 | 900 | — | 974 |
| **gitlab** | gitlab-webservice | 350 | — | 43 | 1464 | — | 1521 |
| **kube-flannel** | kube-flannel-ds (x2) | 100 | — | 4–6 | 50 | — | 35–59 |
| **kube-system** | coredns (x2) | 100 | — | 2 | 70 | 170 | 17–22 |
| **kube-system** | etcd | 100 | — | 18 | 100 | — | 89 |
| **kube-system** | kube-apiserver | 250 | — | 53 | — | — | 751 |
| **kube-system** | kube-controller-manager | 200 | — | 12 | — | — | 81 |
| **kube-system** | kube-proxy (x2) | — | — | 2–3 | — | — | 34–52 |
| **kube-system** | kube-scheduler | 100 | — | 5 | — | — | 35 |
| **kube-system** | metrics-server | 100 | — | 5 | 200 | — | 66 |
| **local-path-storage** | local-path-provisioner | — | — | 1 | — | — | 44 |
| **metallb-system** | metallb-controller | — | — | 3 | — | — | 70 |
| **metallb-system** | metallb-speaker (x2) | — | — | 8–9 | — | — | 66–115 |
| **registry** | registry | 50 | 500 | 1 | 64 | 256 | 21 |
| **traefik** | traefik | — | — | 2 | — | — | 117 |

## Observations

- **Aucune limite CPU** définie sur les composants GitLab → pas de throttling mais risque de contention
- **Aucune limite RAM** sur GitLab → sidekiq (974 Mi / 900 Mi req) et webservice (1521 Mi / 1464 Mi req) dépassent déjà leurs requests
- **kube-apiserver** : 751 Mi sans request ni limit définis
- **argocd-application-controller** : 386 Mi sans aucune contrainte
- Seuls `coredns` et `registry` ont des **limits CPU et RAM** complètes
