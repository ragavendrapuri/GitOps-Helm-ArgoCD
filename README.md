# gitops-helm-argocd

> GitOps deployments across dev / staging / prod using ArgoCD App-of-Apps pattern + Helm. Declarative, self-healing, multi-environment. One commit to Git = deployment to Kubernetes.

## Architecture

```
  Developer
     │
     │  git push
     ▼
  GitHub repo ──────────────────────────────────────────────┐
  (source of truth)                                         │
     │                                                      │
     │  ArgoCD watches for changes every 3 minutes          │
     ▼                                                      │
  ┌─────────────────────────────────────────────────────┐   │
  │              ArgoCD (monitoring namespace)           │   │
  │                                                     │   │
  │  root-app (App-of-Apps)                             │   │
  │     ├── cicd-demo-dev     → dev namespace           │   │
  │     ├── cicd-demo-staging → staging namespace       │   │
  │     └── cicd-demo-prod    → prod namespace          │   │
  │          (manual sync only — prod gate)             │   │
  └─────────────────────────────────────────────────────┘   │
                                                            │
  ArgoCD syncs Helm chart at path helm/app-chart ──────────┘
  with per-env values from helm/app-chart/envs/
```

## Folder Structure

```
gitops-helm-argocd/
├── argocd/
│   ├── app-of-apps.yaml          # ROOT — apply this once manually
│   ├── apps/
│   │   ├── dev.yaml              # Child app → dev namespace
│   │   ├── staging.yaml          # Child app → staging namespace
│   │   └── prod.yaml             # Child app → prod (manual sync)
│   ├── projects/
│   │   └── projects.yaml         # RBAC projects per environment
│   └── rbac/
│       ├── argocd-rbac-cm.yaml   # Cluster-wide RBAC
│       └── argocd-notifications-cm.yaml  # Slack notifications
├── helm/
│   └── app-chart/
│       ├── Chart.yaml
│       ├── values.yaml           # Base values
│       ├── envs/
│       │   ├── values-dev.yaml
│       │   ├── values-staging.yaml
│       │   └── values-prod.yaml
│       └── templates/
│           ├── deployment.yaml   # With sync waves
│           ├── service.yaml      # + HPA + PDB + SA + Ingress
│           ├── configmap.yaml
│           └── _helpers.tpl
├── terraform/
│   └── argocd.tf                 # Installs ArgoCD via Helm
├── scripts/
│   └── deploy.sh                 # One-command full setup
└── .github/
    └── workflows/
        └── gitops-sync.yml       # Updates image tag via Git commit
```

## Quick Deploy

```bash
# Prerequisites: kubectl, helm, argocd CLI, terraform, aws CLI

git clone https://github.com/ragavendrapuri/gitops-helm-argocd
cd gitops-helm-argocd

export GITHUB_TOKEN="your_github_pat"
export ARGOCD_PASSWORD="YourSecurePassword!"

chmod +x scripts/deploy.sh
./scripts/deploy.sh raghav-prod-eks-prod ap-south-1
```

## Manual Step-by-Step

```bash
# 1. Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 2. Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d

# 3. Access ArgoCD UI
kubectl port-forward svc/argocd-server 8080:443 -n argocd
# Open: https://localhost:8080

# 4. Login via CLI
argocd login localhost:8080 --username admin --insecure

# 5. Add your repo
argocd repo add https://github.com/ragavendrapuri/gitops-helm-argocd \
  --username ragavendrapuri --password YOUR_GITHUB_PAT

# 6. Apply projects and RBAC
kubectl apply -f argocd/projects/ -n argocd
kubectl apply -f argocd/rbac/ -n argocd

# 7. Apply App-of-Apps — this creates all child apps automatically
kubectl apply -f argocd/app-of-apps.yaml -n argocd

# 8. Sync environments
argocd app sync cicd-demo-dev
argocd app sync cicd-demo-staging
# Production is manual: argocd app sync cicd-demo-prod
```

## GitOps Workflow

```bash
# Update image tag → ArgoCD auto-syncs to staging
gh workflow run gitops-sync.yml \
  -f image_tag=main-abc1234-42 \
  -f environment=staging

# Promote to prod (requires GitHub environment approval)
gh workflow run gitops-sync.yml \
  -f image_tag=main-abc1234-42 \
  -f environment=prod
```

## Self-Healing Demo (Killer Interview Demo)

```bash
# Delete a deployment manually — ArgoCD restores it within 3 minutes
kubectl delete deployment cicd-demo -n staging

# Watch ArgoCD detect drift and restore
argocd app get cicd-demo-staging
# Status: OutOfSync → Syncing → Synced → Healthy
```

## Rollback

```bash
# View deployment history
argocd app history cicd-demo-prod

# Roll back to a specific revision
argocd app rollback cicd-demo-prod 5

# Or roll back to previous
argocd app rollback cicd-demo-prod
```

## Key Design Decisions

- **App-of-Apps pattern** — one root app manages all environments from a single `kubectl apply`
- **No automated sync for prod** — prod always requires human intent, prevents accidental deploys
- **Sync waves** — ConfigMap (wave -2) → Service (wave -1) → Deployment (wave 0) — correct ordering
- **ignoreDifferences for replicas** — HPA manages replica count, ArgoCD won't fight it
- **orphanedResources monitoring** — alerts if something exists in prod that isn't in Git

## Author

**Raghavendra Puri** — DevOps & Cloud Infrastructure Engineer
[GitHub](https://github.com/ragavendrapuri) · [LinkedIn](https://linkedin.com/in/raghavendra-puri) · puriraghavendra14@gmail.com
