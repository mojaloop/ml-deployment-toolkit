# kind bootstrap — Gateway API CRDs, applied through the root kubectl
# provider whose configuration defers until the cluster module has written
# the real kubeconfig. Cilium's operator registers its Gateway API support
# on startup; the Flux takeover of the cilium release restarts it with the
# CRDs present.
#
# Split in pure HCL, not via the kubectl_file_documents data source: that
# data source reads through the kubectl provider, whose kubeconfig only
# exists at apply time on a fresh deploy — the read defers and for_each
# over an unknown map fails the plan.

locals {
  gateway_api_docs = [
    for doc in split("\n---\n", file(var.gateway_api_crds_path)) :
    doc if can(yamldecode(doc)) && yamldecode(doc) != null
  ]
}

# A rebuilt cluster starts empty while these manifests still sit in state —
# the generation ties them to the cluster they live on
resource "terraform_data" "cluster" {
  input = var.cluster_generation
}

resource "kubectl_manifest" "gateway_api" {
  for_each = {
    for doc in local.gateway_api_docs :
    "${yamldecode(doc).kind}/${yamldecode(doc).metadata.name}" => doc
  }

  yaml_body         = each.value
  server_side_apply = true
  wait              = true

  lifecycle {
    replace_triggered_by = [terraform_data.cluster]
  }
}
