# Provider configurations (config stack)
# The config stack talks only to the Kubernetes API. The kubeconfig is produced
# by the infra stack at a well-known path; `make init` seeds a placeholder so
# plans work before the cluster exists (the placeholder is never dialed during
# a real apply — the infra stack rewrites the file first).

locals {
  kubeconfig = "${var.artifacts_dir}/${var.env_name}/kubernetes/kubeconfig"
}

provider "kubernetes" {
  config_path = local.kubeconfig
}

provider "kubectl" {
  config_path = local.kubeconfig
}
