# kind Cluster Module
# Provisions a Kubernetes-in-Docker cluster on the operator's host: docker
# containers as nodes, the default CNI and kube-proxy disabled so Cilium owns
# the datapath, gateway LB IPs served over L2 on the kind docker bridge.

locals {
  provider_config = yamldecode(file(var.provider_config_path)).infra
  node_image      = try(local.provider_config.node_image, "kindest/node:v${var.kubernetes_version}")

  # One node entry per member of every pool, control-plane pools first (kind
  # requires the first node to be a control plane). Each node carries the
  # pool's mechanically derived labels, the same <label-key>=<pool> every
  # gitops selector keys on.
  nodes = flatten([
    for pool in concat(
      [for p in var.node_pools : p if p.role == "control-plane"],
      [for p in var.node_pools : p if p.role != "control-plane"],
    ) : [
      for i in range(pool.count) : {
        key    = "${pool.name}-${i}"
        role   = pool.role
        labels = pool.labels
      }
    ]
  ])
}

resource "kind_cluster" "this" {
  name           = var.cluster.name
  node_image     = local.node_image
  wait_for_ready = false

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    networking {
      # Cilium replaces both; nodes go Ready only once the bootstrap install
      # below brings the datapath up
      disable_default_cni = true
      kube_proxy_mode     = "none"
    }

    # A list, not a map: kind requires the first node to be a control plane,
    # and only list iteration preserves the ordering local.nodes established
    dynamic "node" {
      for_each = local.nodes
      content {
        role   = node.value.role
        labels = node.value.labels

        # The full hub on few nodes crosses the kubelet's 110-pod default
        # while cpu and memory sit largely idle
        kubeadm_config_patches = [
          <<-EOT
          kind: KubeletConfiguration
          maxPods: 250
          EOT
        ]
      }
    }
  }
}

# The node image's containerd unit sets LimitNOFILE=infinity, which under a
# docker parent resolves to 2^31 and reaches every pod — and a workload that
# walks its fd table on fork (HAProxy external health checks) then burns
# minutes of CPU per fork. Capped to the standard host default before any
# workload starts; containerd keeps running containers across the restart.
resource "terraform_data" "node_fd_limit" {
  input = kind_cluster.this.id

  provisioner "local-exec" {
    command = <<-EOT
      for node in $(docker ps --filter "label=io.x-k8s.kind.cluster=${kind_cluster.this.name}" --format '{{.Names}}'); do
        docker exec "$node" bash -c '
          mkdir -p /etc/systemd/system/containerd.service.d &&
          printf "[Service]\nLimitNOFILE=1048576\n" > /etc/systemd/system/containerd.service.d/nofile.conf &&
          systemctl daemon-reload && systemctl restart containerd
        '
      done
    EOT
  }

  lifecycle {
    replace_triggered_by = [kind_cluster.this]
  }
}

# Write kubeconfig to artifacts
resource "local_sensitive_file" "kubeconfig" {
  filename             = "${var.artifacts_path}/kubernetes/kubeconfig"
  content              = kind_cluster.this.kubeconfig
  file_permission      = "0600"
  directory_permission = "0700"
}

# --------------------------------------------------------------------------
# Cilium bootstrap install — kube-proxy is absent, so nodes only go Ready
# once this lands; wait=false because with zero Ready nodes the operator
# Deployment can never come up first. Gateway API CRDs arrive in the
# bootstrap module after this one; the Flux takeover of this release
# restarts the operator with them present.
#
# Flux's HelmRelease in gitops/kind/cilium adopts this exact release:
# name/namespace stay in lockstep with its releaseName/storageNamespace, and
# every value here must agree with gitops/kind/values/cilium/cilium.yaml or
# the takeover rolls the datapath.
# --------------------------------------------------------------------------

resource "helm_release" "cilium" {
  name             = "cilium"
  namespace        = "cilium"
  create_namespace = true

  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = var.cilium_version

  values = [
    templatefile("${path.module}/values/cilium-bootstrap.yaml.tpl", {
      # With kube-proxy absent the in-cluster Service VIP is not routable
      # until Cilium's own datapath is up — agent and operator dial the
      # control-plane container by its docker DNS name.
      k8s_service_host = "${var.cluster.name}-control-plane"
    })
  ]

  wait = false

  depends_on = [local_sensitive_file.kubeconfig, terraform_data.node_fd_limit]

  # A rebuilt cluster starts empty while this release still sits in state —
  # the install has to follow the cluster it lives on
  lifecycle {
    replace_triggered_by = [kind_cluster.this]
  }
}
