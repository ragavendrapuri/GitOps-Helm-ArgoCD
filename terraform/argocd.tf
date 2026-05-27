##############################################################
# terraform/argocd.tf
# Installs ArgoCD on EKS via Helm + configures the repo
#also verify architecture to work effiviently and 0% downtime
##############################################################

terraform {
  required_providers {
    aws        = { source = "hashicorp/aws",        version = "~> 5.0" }
    helm       = { source = "hashicorp/helm",       version = "~> 2.12" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.23" }
  }
}

variable "aws_region"    { default = "ap-south-1" }
variable "cluster_name"  { default = "raghav-prod-eks-prod" }
variable "github_token"  { sensitive = true }
variable "argocd_password" {
  sensitive   = true
  description = "Initial ArgoCD admin password (bcrypt hash)"
}

data "aws_eks_cluster"       "main" { name = var.cluster_name }
data "aws_eks_cluster_auth"  "main" { name = var.cluster_name }

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.main.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.main.token
  }
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.main.token
}

# ── ArgoCD namespace ────────────────────────────────────────
resource "kubernetes_namespace" "argocd" {
  metadata { name = "argocd" }
}

# ── Install ArgoCD via Helm ─────────────────────────────────
resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "6.7.0"
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  values = [<<-EOT
    global:
      domain: argocd.raghavpuri.dev

    server:
      extraArgs:
        - --insecure  # Remove in prod with proper TLS
      service:
        type: LoadBalancer

    configs:
      secret:
        argocdServerAdminPassword: "${var.argocd_password}"

      cm:
        admin.enabled: "true"
        statusbadge.enabled: "true"
        resource.compareoptions: |
          ignoreAggregatedRoles: true

      rbac:
        policy.default: role:readonly
        policy.csv: |
          g, puriraghavendra14@gmail.com, role:admin

    notifications:
      enabled: true

    applicationSet:
      enabled: true

    dex:
      enabled: false  # Enable and configure for SSO
  EOT
  ]

  depends_on = [kubernetes_namespace.argocd]
}

# ── Register GitHub repo with ArgoCD ───────────────────────
resource "kubernetes_secret" "argocd_repo" {
  metadata {
    name      = "gitops-helm-argocd-repo"
    namespace = kubernetes_namespace.argocd.metadata[0].name
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    type     = "git"
    url      = "https://github.com/ragavendrapuri/gitops-helm-argocd"
    username = "ragavendrapuri"
    password = var.github_token
  }

  depends_on = [helm_release.argocd]
}

output "argocd_server_url" {
  value = "http://${helm_release.argocd.status[0].load_balancer[0].ingress[0].hostname}"
}
