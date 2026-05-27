#!/bin/bash
##############################################################
# scripts/deploy.sh
# Full GitOps stack setup — ArgoCD + all environments
# Usage: ./scripts/deploy.sh [CLUSTER_NAME] [AWS_REGION]
##############################################################

set -euo pipefail

CLUSTER=${1:-"raghav-prod-eks-prod"}
REGION=${2:-"ap-south-1"}
ARGOCD_NS="argocd"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── 0. Preflight ──────────────────────────────────────────────
info "Checking prerequisites..."
for cmd in kubectl helm argocd terraform aws; do
  command -v $cmd &>/dev/null || error "$cmd not installed"
done

# ── 1. Connect to EKS ─────────────────────────────────────────
info "Connecting to EKS: $CLUSTER"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"
kubectl get nodes || error "Cannot reach cluster"

# ── 2. Install ArgoCD via Terraform ───────────────────────────
info "Installing ArgoCD..."
cd terraform
terraform init -input=false

# Generate bcrypt hash for admin password
ARGOCD_PASSWORD=${ARGOCD_PASSWORD:-"Raghav@ArgoCD2024!"}
BCRYPT_HASH=$(htpasswd -nbBC 10 "" "$ARGOCD_PASSWORD" | tr -d ':\n' | sed 's/$2y/$2a/')

terraform apply -auto-approve \
  -var="cluster_name=$CLUSTER" \
  -var="aws_region=$REGION" \
  -var="github_token=${GITHUB_TOKEN:-}" \
  -var="argocd_password=$BCRYPT_HASH"

ARGOCD_URL=$(terraform output -raw argocd_server_url)
cd ..

# ── 3. Wait for ArgoCD to be ready ────────────────────────────
info "Waiting for ArgoCD server..."
kubectl rollout status deployment/argocd-server \
  -n $ARGOCD_NS --timeout=120s

# ── 4. Login to ArgoCD ────────────────────────────────────────
info "Logging into ArgoCD..."
sleep 10  # Give LB time to stabilise
argocd login "$ARGOCD_URL" \
  --username admin \
  --password "$ARGOCD_PASSWORD" \
  --insecure

# ── 5. Apply RBAC and notifications ───────────────────────────
info "Applying RBAC config..."
kubectl apply -f argocd/rbac/ -n $ARGOCD_NS

# ── 6. Create ArgoCD Projects ─────────────────────────────────
info "Creating ArgoCD projects..."
kubectl apply -f argocd/projects/ -n $ARGOCD_NS

# ── 7. Apply App-of-Apps (triggers everything) ────────────────
info "Deploying App-of-Apps..."
kubectl apply -f argocd/app-of-apps.yaml -n $ARGOCD_NS

# ── 8. Wait for child apps to appear ──────────────────────────
info "Waiting for child apps to be created (ArgoCD syncing)..."
sleep 30
argocd app list

# ── 9. Sync dev and staging (prod is manual) ──────────────────
info "Syncing dev environment..."
argocd app sync cicd-demo-dev --timeout 300
argocd app wait cicd-demo-dev --health --timeout 300

info "Syncing staging environment..."
argocd app sync cicd-demo-staging --timeout 300
argocd app wait cicd-demo-staging --health --timeout 300

# ── 10. Print summary ─────────────────────────────────────────
echo ""
echo "=============================================="
echo "  GitOps Stack Deployed Successfully!"
echo "=============================================="
echo ""
echo "  ArgoCD UI   : $ARGOCD_URL"
echo "  Username    : admin"
echo "  Password    : $ARGOCD_PASSWORD"
echo ""
echo "  Apps deployed:"
argocd app list
echo ""
echo "  To deploy to PRODUCTION:"
echo "  argocd app sync cicd-demo-prod"
echo ""
echo "  To test self-healing (GitOps demo):"
echo "  kubectl delete deployment cicd-demo -n staging"
echo "  # ArgoCD restores it within 3 minutes!"
echo "=============================================="
