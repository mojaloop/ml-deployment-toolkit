# AWS Cluster Composite Module
# Provisions EKS managed Kubernetes cluster

locals {
  provider_config = yamldecode(file(var.provider_config_path)).infra
  vpc_cidr        = try(local.provider_config.vpc.cidr, "10.0.0.0/16")

  # AZs: the ones the environment's placement.yaml pins node groups to, else
  # the first three the region offers (the pre-placement behaviour). Subnets
  # key by AZ name, so a placement map naming the same AZs the slice picked
  # leaves existing subnets untouched.
  pinned_azs = distinct([for ng in var.node_groups : ng.az if ng.az != ""])
  # EKS refuses CreateCluster with subnets in fewer than two AZs, so a
  # placement map pinning a single AZ (a one-pool tooling template) is padded
  # from the region's remaining AZs up to that floor. Only the subnets pad —
  # node groups stay pinned exactly where placement.yaml put them.
  padded_azs = concat(local.pinned_azs, slice(
    [for az in data.aws_availability_zones.available.names : az if !contains(local.pinned_azs, az)],
    0, max(0, 2 - length(local.pinned_azs))
  ))
  azs = length(local.pinned_azs) > 0 ? sort(local.padded_azs) : slice(
    data.aws_availability_zones.available.names, 0, min(3, length(data.aws_availability_zones.available.names))
  )
  subnet_cidrs = { for i, az in local.azs : az => cidrsubnet(local.vpc_cidr, 8, i) }

  # EKS version is major.minor only (e.g. "1.34")
  eks_version = join(".", slice(split(".", var.kubernetes_version), 0, 2))
}

data "aws_availability_zones" "available" {
  state = "available"
}

# --------------------------------------------------------------------------
# VPC
# --------------------------------------------------------------------------

resource "aws_vpc" "cluster" {
  cidr_block           = local.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${var.cluster.name}-vpc" }
}

resource "aws_subnet" "cluster" {
  for_each = local.subnet_cidrs

  vpc_id                  = aws_vpc.cluster.id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = true

  lifecycle {
    # Catches a typo'd AZ in placement.yaml at plan time instead of a
    # partially-built VPC.
    precondition {
      condition     = contains(data.aws_availability_zones.available.names, each.key)
      error_message = "availability zone '${each.key}' does not exist in this region — check the environment's placement.yaml pg -> AZ map."
    }
  }

  tags = {
    Name                                        = "${var.cluster.name}-${each.key}"
    "kubernetes.io/cluster/${var.cluster.name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  }
}

resource "aws_internet_gateway" "cluster" {
  vpc_id = aws_vpc.cluster.id
  tags   = { Name = "${var.cluster.name}-igw" }
}

resource "aws_route_table" "cluster" {
  vpc_id = aws_vpc.cluster.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.cluster.id
  }

  tags = { Name = "${var.cluster.name}-rt" }
}

resource "aws_route_table_association" "cluster" {
  for_each       = aws_subnet.cluster
  subnet_id      = each.value.id
  route_table_id = aws_route_table.cluster.id
}

# --------------------------------------------------------------------------
# IAM — EKS Cluster Role
# --------------------------------------------------------------------------

resource "aws_iam_role" "cluster" {
  name = "${var.cluster.name}-eks-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# --------------------------------------------------------------------------
# IAM — EKS Node Group Role
# --------------------------------------------------------------------------

resource "aws_iam_role" "node" {
  name = "${var.cluster.name}-eks-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# EBS CSI driver credentials ride the node instance role — no OIDC/IRSA in
# this module by decision (single raw-credential mechanism everywhere). The
# CNI policy above serves double duty: it grants the ENI create/attach/tag
# operations Cilium's operator performs in ENI IPAM mode.
resource "aws_iam_role_policy_attachment" "node_ebs_csi" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# --------------------------------------------------------------------------
# EKS Cluster
# --------------------------------------------------------------------------

resource "aws_eks_cluster" "this" {
  name     = var.cluster.name
  role_arn = aws_iam_role.cluster.arn
  version  = local.eks_version

  # No self-managed addons: EKS installs neither vpc-cni, kube-proxy nor
  # coredns. Cilium (ENI mode, kube-proxy replacement) is installed by the
  # aws-bootstrap module before Flux; coredns and the EBS CSI driver follow
  # as managed addons there, after the CNI exists to network their pods.
  bootstrap_self_managed_addons = false

  vpc_config {
    subnet_ids             = [for s in aws_subnet.cluster : s.id]
    endpoint_public_access = true
    # Private access must be on when the public endpoint is CIDR-restricted:
    # nodes egress from their own public IPs (public subnets, no NAT), which
    # are never in api_allowed_cidrs — without the private endpoint, kubelet
    # and the CNI would be locked out of their own API server.
    endpoint_private_access = true
    public_access_cidrs     = var.api_allowed_cidrs
  }

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}

# --------------------------------------------------------------------------
# EKS Node Groups
# --------------------------------------------------------------------------

locals {
  # placement.yaml taints use Kubernetes effect names; the EKS API wants its
  # own enum.
  eks_taint_effects = {
    NoSchedule       = "NO_SCHEDULE"
    PreferNoSchedule = "PREFER_NO_SCHEDULE"
    NoExecute        = "NO_EXECUTE"
  }
}

resource "aws_eks_node_group" "this" {
  for_each = { for ng in var.node_groups : ng.name => ng }

  cluster_name    = aws_eks_cluster.this.name
  node_group_name = each.value.name
  node_role_arn   = aws_iam_role.node.arn
  # AZ-pinned groups get exactly their zone's subnet — the only placement
  # control EKS offers; per-instance placement does not exist. Unpinned
  # groups keep all subnets and the ASG spreads best-effort.
  subnet_ids     = each.value.az != "" ? [aws_subnet.cluster[each.value.az].id] : [for s in aws_subnet.cluster : s.id]
  instance_types = each.value.instance_types

  scaling_config {
    desired_size = each.value.desired_size
    min_size     = each.value.min_size
    max_size     = each.value.max_size
  }

  # node-role labels the whole gitops layer schedules on — the EKS
  # counterpart of the Talos per-pool machine-config label patches.
  labels = each.value.labels

  dynamic "taint" {
    for_each = each.value.taints
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = local.eks_taint_effects[taint.value.effect]
    }
  }

  tags = { for tag in try(each.value.tags, []) : tag => "true" }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]
}

# --------------------------------------------------------------------------
# Kubeconfig (uses aws CLI exec for token refresh)
# --------------------------------------------------------------------------

resource "local_sensitive_file" "kubeconfig" {
  filename             = "${var.artifacts_path}/kubernetes/kubeconfig"
  file_permission      = "0600"
  directory_permission = "0700"

  content = yamlencode({
    apiVersion      = "v1"
    kind            = "Config"
    current-context = var.cluster.name
    clusters = [{
      name = var.cluster.name
      cluster = {
        server                     = aws_eks_cluster.this.endpoint
        certificate-authority-data = aws_eks_cluster.this.certificate_authority[0].data
      }
    }]
    contexts = [{
      name = var.cluster.name
      context = {
        cluster = var.cluster.name
        user    = var.cluster.name
      }
    }]
    users = [{
      name = var.cluster.name
      user = {
        exec = {
          apiVersion = "client.authentication.k8s.io/v1beta1"
          command    = "aws"
          args       = ["eks", "get-token", "--cluster-name", var.cluster.name, "--region", var.region]
        }
      }
    }]
  })
}
