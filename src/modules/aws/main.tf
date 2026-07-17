# AWS Cluster Composite Module
# Provisions EKS managed Kubernetes cluster

locals {
  provider_config = yamldecode(file(var.provider_config_path))
  vpc_cidr        = try(local.provider_config.vpc.cidr, "10.0.0.0/16")

  # Use up to 3 AZs from the region
  azs          = slice(data.aws_availability_zones.available.names, 0, min(3, length(data.aws_availability_zones.available.names)))
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

# --------------------------------------------------------------------------
# EKS Cluster
# --------------------------------------------------------------------------

resource "aws_eks_cluster" "this" {
  name     = var.cluster.name
  role_arn = aws_iam_role.cluster.arn
  version  = local.eks_version

  vpc_config {
    subnet_ids = [for s in aws_subnet.cluster : s.id]
  }

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}

# --------------------------------------------------------------------------
# EKS Node Groups
# --------------------------------------------------------------------------

resource "aws_eks_node_group" "this" {
  for_each = { for ng in var.node_groups : ng.name => ng }

  cluster_name    = aws_eks_cluster.this.name
  node_group_name = each.value.name
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = [for s in aws_subnet.cluster : s.id]
  instance_types  = each.value.instance_types

  scaling_config {
    desired_size = each.value.desired_size
    min_size     = each.value.min_size
    max_size     = each.value.max_size
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
