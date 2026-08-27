# AWS Cluster Bootstrap — what Flux needs that the cluster does not have.
#
# The Talos path gets these from machine-config extraManifests applied at
# node bootstrap. EKS has no such hook, so this module plays that role from
# the outside, AFTER the aws module has delivered a functioning cluster —
# Cilium itself is installed inside that module, between cluster and node
# groups, because EKS refuses to mark a node group ACTIVE until nodes are
# Ready and only a CNI makes them Ready. What remains here:
#
#   1. Gateway API CRDs — same vendored file the gitops/aws layer owns after
#      takeover; bootstrap parity with Talos extraManifests.
#   2. coredns + aws-ebs-csi-driver managed addons — their pods need the
#      CNI, and Flux (OCI pulls by hostname) needs coredns.

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
    for doc in split("\n---\n", file("${path.module}/../../../../gitops/aws/gateway-api/crds.yaml")) :
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
# Managed addons — their pods need the CNI, which the aws module installed
# before this module ran (module-level depends_on in src/infra). kube-proxy
# is deliberately absent (kubeProxyReplacement); vpc-cni is deliberately
# absent (Cilium ENI mode replaces it).
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
}
