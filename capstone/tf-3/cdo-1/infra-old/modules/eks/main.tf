# INFRA-4: EKS Cluster module
# Implements: docs/02_infra_design.md §2 (Component table) + §5.1 (Option C: EKS + Karpenter)
#             docs/03_security_design.md §2.1 (IRSA) + §2.2 (K8s RBAC)
#
# Apply order: terraform apply -target=module.eks BEFORE the rest (chicken-and-egg:
# cluster is both resource and kubernetes/helm provider target — see providers.tf comment)

##############################################################################
# 1. EKS CLUSTER
##############################################################################

resource "aws_eks_cluster" "this" {
  name     = "${var.name_prefix}-cluster"
  role_arn = aws_iam_role.cluster.arn
  version  = var.cluster_version

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    security_group_ids      = [var.sg_eks_control_plane_id]
    endpoint_private_access = true
    endpoint_public_access  = false # No public endpoint — all traffic via VPC (docs/03_security_design.md §1.1)
  }

  # EKS Secrets envelope encryption (docs/03_security_design.md §4.1 alias/cdo-secrets-kms)
  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = var.kms_infra_arn
    }
  }

  # Enable EKS API server audit logging → CloudWatch (docs/03_security_design.md §5.2)
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  tags = local.module_tags

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy,
    aws_iam_role_policy_attachment.cluster_vpc_resource_controller,
  ]
}

##############################################################################
# 2. IAM ROLE — EKS CONTROL PLANE
##############################################################################

data "aws_iam_policy_document" "cluster_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.name_prefix}-eks-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume_role.json
  tags               = local.module_tags
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "cluster_vpc_resource_controller" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
}

##############################################################################
# 3. OIDC PROVIDER — IRSA (docs/03_security_design.md §2.1)
# Output oidc_provider_arn is consumed by: karpenter, ingress, observability
##############################################################################

data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer

  client_id_list = ["sts.amazonaws.com"]

  thumbprint_list = [
    data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint
  ]

  tags = local.module_tags
}

##############################################################################
# 4. IAM ROLE — EKS NODE (shared: managed node group + Karpenter nodes)
# docs/03_security_design.md §2.1 eks-node-role
##############################################################################

data "aws_iam_policy_document" "node_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.name_prefix}-eks-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json
  tags               = local.module_tags
}

# Minimum required policies for EKS worker node
resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_ecr_readonly" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# SSM for operational access without SSH keypair
resource "aws_iam_role_policy_attachment" "node_ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# CloudWatch agent — required for ADOT/Node Exporter metrics (docs/02_infra_design.md §2)
resource "aws_iam_role_policy_attachment" "node_cloudwatch" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.name_prefix}-eks-node-profile"
  role = aws_iam_role.node.name
  tags = local.module_tags
}

##############################################################################
# 5. MANAGED NODE GROUP — SYSTEM / PLATFORM PODS ONLY
# Runs: CoreDNS, kube-proxy, ADOT, Karpenter controller
# docs/02_infra_design.md §3.3 Trade-off 2 — On-Demand to avoid Spot interruption
#   for baseline platform services
##############################################################################

resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name_prefix}-system-ng"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids

  # On-Demand only for platform stability (docs/02_infra_design.md §3.3 Trade-off 2)
  capacity_type  = "ON_DEMAND"
  instance_types = ["t3.medium"]

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 3 # Small ceiling — Karpenter handles workload nodes
  }

  update_config {
    max_unavailable = 1
  }

  # Pin system pods with taint so only tolerating pods (Karpenter, CoreDNS, etc.) land here
  taint {
    key    = "CriticalAddonsOnly"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  labels = {
    "node-role" = "system"
  }

  # IMDSv2 required (docs/03_security_design.md §6)
  launch_template {
    id      = aws_launch_template.system_node.id
    version = aws_launch_template.system_node.latest_version
  }

  tags = local.module_tags

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_ecr_readonly,
    aws_iam_role_policy_attachment.node_cni,
  ]
}

resource "aws_launch_template" "system_node" {
  name_prefix = "${var.name_prefix}-system-node-lt-"

  # IMDSv2 only — docs/03_security_design.md §6
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2
    http_put_response_hop_limit = 1
  }

  # EBS root volume encrypted with KMS (docs/03_security_design.md §4.1)
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = var.kms_infra_arn
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = local.module_tags
  }

  tag_specifications {
    resource_type = "volume"
    tags          = local.module_tags
  }

  tags = local.module_tags
}

##############################################################################
# 6. EKS ADD-ONS (managed, so AWS handles patching)
##############################################################################

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "coredns"
  tags         = local.module_tags
  depends_on   = [aws_eks_node_group.system]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "kube-proxy"
  tags         = local.module_tags
  depends_on   = [aws_eks_node_group.system]
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "vpc-cni"
  # enableNetworkPolicy required for INFRA-8 Kubernetes NetworkPolicy enforcement
  configuration_values = jsonencode({
    env = {
      ENABLE_NETWORK_POLICY = "true"
    }
  })
  tags       = local.module_tags
  depends_on = [aws_eks_node_group.system]
}

resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "eks-pod-identity-agent"
  tags         = local.module_tags
  depends_on   = [aws_eks_node_group.system]
}

##############################################################################
# 7. K8s NAMESPACES
# Decision: create here (Terraform layer) so they exist before GitOps/Helm apply.
# ADR reference: docs/08_adrs.md — "Create platform namespaces in Terraform, not GitOps"
##############################################################################

resource "kubernetes_namespace" "self_heal_system" {
  metadata {
    name = "self-heal-system"
    labels = {
      "name"                                       = "self-heal-system"
      "pod-security.kubernetes.io/enforce"         = "restricted"
      "pod-security.kubernetes.io/enforce-version" = "latest"
    }
  }
  depends_on = [aws_eks_node_group.system]
}

resource "kubernetes_namespace" "tenant_payment" {
  metadata {
    name = "tenant-payment"
    labels = {
      "name"      = "tenant-payment"
      "tenant_id" = "d3b07384-d113-495f-9f58-20d18d357d75"
    }
  }
  depends_on = [aws_eks_node_group.system]
}

resource "kubernetes_namespace" "tenant_checkout" {
  metadata {
    name = "tenant-checkout"
    labels = {
      "name"      = "tenant-checkout"
      "tenant_id" = "6c8b4b2b-4d45-4209-a1b4-4b532d56a31c"
    }
  }
  depends_on = [aws_eks_node_group.system]
}

resource "kubernetes_namespace" "observability" {
  metadata {
    name = "observability"
    labels = {
      "name"                               = "observability"
      "pod-security.kubernetes.io/enforce" = "privileged" # Prometheus node-exporter needs host access
    }
  }
  depends_on = [aws_eks_node_group.system]
}
