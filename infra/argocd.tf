resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }

  depends_on = [google_container_cluster.primary]
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "10.1.0"
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  # ClusterIP + kubectl port-forward for access, to avoid an always-on
  # LoadBalancer IP cost. Flip to LoadBalancer only when demoing.
}
