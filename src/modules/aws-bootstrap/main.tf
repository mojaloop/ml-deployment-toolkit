# AWS Cluster Bootstrap — the pieces that must exist before Flux can run.
#
# The Talos path gets these from machine-config extraManifests (Cilium static
# manifest + Gateway API CRDs) applied at node bootstrap. EKS has no such
# hook and the cluster is created with bootstrap_self_managed_addons=false,
# so this module plays that role from the outside, in dependency order:
#
#   1. Cilium (helm) — nodes are NotReady until a CNI exists; nothing with a
#      pod network can run before this.
#   2. Gateway API CRDs — same vendored file the gitops/aws layer owns after
#      takeover; bootstrap parity with Talos extraManifests.
#   3. coredns + aws-ebs-csi-driver managed addons — their pods need the CNI,
#      and Flux (OCI pulls by hostname) needs coredns.
#
# Flux's HelmRelease in gitops/aws/cilium adopts the helm release installed
# here: release name and namespace must stay in lockstep with that file's
# explicit releaseName/storageNamespace.

locals {
  # k8sServiceHost wants a bare hostname; the EKS attribute is a https:// URL.
  k8s_service_host = trimprefix(var.cluster_endpoint, "https://")
}

resource "helm_release" "cilium" {
  name             = "cilium"
  namespace        = "cilium"
  create_namespace = true

  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = var.cilium_version

  values = [
    templatefile("${path.module}/values/cilium-bootstrap.yaml.tpl", {
      k8s_service_host = local.k8s_service_host
    })
  ]

  # Nodes join NotReady (no CNI) — the chart applies fine regardless, but the
  # agent pods are what flips them Ready. Wait so the addons below start on a
  # functioning cluster instead of racing the datapath.
  wait    = true
  timeout = 900
}

# Gateway API CRDs — the platform-config Gateways reference them, and the
# Cilium operator watches for them. Applied from the same vendored file the
# gitops/aws vendor layer reconciles afterwards, so bootstrap and GitOps can
# never disagree on the version.
#
# Split in pure HCL, not via the kubectl_file_documents data source: that
# data source reads through the kubectl provider, whose kubeconfig only
# exists at apply time on a fresh deploy — the read defers and for_each
# over an unknown map fails the plan.
locals {
  gateway_api_docs = [
    for doc in split("\n---\n", file("${path.module}/../../../gitops/aws/gateway-api/crds.yaml")) :
    doc if can(yamldecode(doc)) && yamldecode(doc) != null
  ]
}

resource "kubectl_manifest" "gateway_api" {
  for_each = {
    for doc in local.gateway_api_docs :
    "${yamldecode(doc).kind}/${yamldecode(doc).metadata.name}" => doc
  }

  yaml_body         = each.value
  server_side_apply = true
  wait              = true
}

# --------------------------------------------------------------------------
# Managed addons — after the CNI, because their pods need a network.
# kube-proxy is deliberately absent (kubeProxyReplacement above); vpc-cni is
# deliberately absent (Cilium ENI mode replaces it).
# --------------------------------------------------------------------------

data "aws_eks_addon_version" "coredns" {
  addon_name         = "coredns"
  kubernetes_version = var.kubernetes_version
  most_recent        = true
}

resource "aws_eks_addon" "coredns" {
  cluster_name  = var.cluster_name
  addon_name    = "coredns"
  addon_version = data.aws_eks_addon_version.coredns.version

  depends_on = [helm_release.cilium]
}

data "aws_eks_addon_version" "ebs_csi" {
  addon_name         = "aws-ebs-csi-driver"
  kubernetes_version = var.kubernetes_version
  most_recent        = true
}

# Credentials via the node instance role (AmazonEBSCSIDriverPolicy attached
# in the aws module) — no service_account_role_arn, no IRSA, by decision.
resource "aws_eks_addon" "ebs_csi" {
  cluster_name  = var.cluster_name
  addon_name    = "aws-ebs-csi-driver"
  addon_version = data.aws_eks_addon_version.ebs_csi.version

  depends_on = [helm_release.cilium]
}
