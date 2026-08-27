# Flux Bootstrap Module
# Installs Flux Operator + FluxInstance CRD (official OCI-native lifecycle manager)

resource "helm_release" "flux_operator" {
  name             = "flux-operator"
  namespace        = var.flux_namespace
  create_namespace = true
  repository       = "oci://ghcr.io/controlplaneio-fluxcd/charts"
  chart            = "flux-operator"
  version          = var.operator_version

  # A bootstrap attempt that times out (e.g. nodes NotReady) leaves a failed
  # release that blocks plain re-install with "name still in use"; retry as
  # upgrade so re-running apply is always safe.
  upgrade_install = true

  wait = true
}

resource "kubectl_manifest" "flux_instance" {
  yaml_body = yamlencode({
    apiVersion = "fluxcd.controlplane.io/v1"
    kind       = "FluxInstance"
    metadata = {
      name      = "flux"
      namespace = var.flux_namespace
    }
    spec = {
      distribution = {
        version  = "v${var.flux_version}"
        registry = "ghcr.io/fluxcd"
      }
      components = [
        "source-controller",
        "kustomize-controller",
        "helm-controller",
        "notification-controller",
      ]
      cluster = {
        type = "kubernetes"
      }
    }
  })

  depends_on = [helm_release.flux_operator]
}
