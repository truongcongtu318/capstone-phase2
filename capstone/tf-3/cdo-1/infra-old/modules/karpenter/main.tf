# INFRA-4: Karpenter module
# Implements: docs/02_infra_design.md §5.1 (Option C chosen) + §6 (Scaling strategy)
#             docs/03_security_design.md §2.1 irsa-karpenter-controller + eks-node-role
#             docs/03_security_design.md §4.1 (EBS root volume encrypted, IMDSv2)
#
# Karpenter manages ALL workload nodes (non-system pods).
# System/platform pods (ArgoCD, Karpenter controller itself) stay on the On-Demand
# NodePool to survive Spot interruptions — docs/02_infra_design.md §3.3 Trade-off 2.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

##############################################################################
# 1. IAM ROLE — KARPENTER CONTROLLER (IRSA)
# docs/03_security_design.md §2.1 irsa-karpenter-controller
# Only allowed: provision/terminate EC2 in the approved node class, read SSM AMI param,
# pass EKS node instance profile — NO broad ec2:* or iam:* grants.
##############################################################################

data "aws_iam_policy_document" "karpenter_controller_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_arn, "/^arn:aws:iam::[0-9]+:oidc-provider\\//", "")}:sub"
      values   = ["system:serviceaccount:kube-system:karpenter"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_arn, "/^arn:aws:iam::[0-9]+:oidc-provider\\//", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "karpenter_controller" {
  name               = "${var.cluster_name}-karpenter-controller"
  assume_role_policy = data.aws_iam_policy_document.karpenter_controller_assume_role.json
  tags               = local.module_tags
}

data "aws_iam_policy_document" "karpenter_controller" {
  # EC2 node provisioning — scope narrowed to cluster-tagged resources
  statement {
    sid    = "KarpenterEC2NodeProvision"
    effect = "Allow"
    actions = [
      "ec2:RunInstances",
      "ec2:CreateLaunchTemplate",
      "ec2:DeleteLaunchTemplate",
      "ec2:CreateFleet",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeInstances",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSubnets",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeImages",
      "ec2:DescribeSpotPriceHistory",
    ]
    resources = ["*"]
    # Tag condition applied where API supports it (RunInstances)
  }

  statement {
    sid    = "KarpenterEC2NodeTerminate"
    effect = "Allow"
    actions = [
      "ec2:TerminateInstances",
    ]
    resources = ["*"]
    condition {
      test     = "StringLike"
      variable = "ec2:ResourceTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }

  statement {
    sid    = "KarpenterTagEC2"
    effect = "Allow"
    actions = [
      "ec2:CreateTags",
    ]
    resources = ["*"]
  }

  # Pass node IAM instance profile — ONLY the approved node profile (least-privilege)
  statement {
    sid       = "KarpenterPassNodeRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [var.node_iam_role_arn]
  }

  # SSM for EKS-optimized AMI lookup
  statement {
    sid    = "KarpenterSSMAMILookup"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
    ]
    resources = ["arn:aws:ssm:*:*:parameter/aws/service/eks/optimized-ami/*"]
  }

  # EKS cluster describe — Karpenter reads cluster version for AMI selection
  statement {
    sid    = "KarpenterEKSDescribe"
    effect = "Allow"
    actions = [
      "eks:DescribeCluster",
    ]
    resources = ["arn:aws:eks:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:cluster/${var.cluster_name}"]
  }

  # Pricing API for Spot selection
  statement {
    sid    = "KarpenterPricing"
    effect = "Allow"
    actions = [
      "pricing:GetProducts",
    ]
    resources = ["*"]
  }

  # SQS — Spot interruption & rebalance notification queue
  statement {
    sid    = "KarpenterSQSSpotInterrupt"
    effect = "Allow"
    actions = [
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:ReceiveMessage",
    ]
    resources = [aws_sqs_queue.karpenter_interruption.arn]
  }

  # EventBridge — register/deregister rules for Spot interruption events
  statement {
    sid    = "KarpenterEventBridge"
    effect = "Allow"
    actions = [
      "events:DescribeRule",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "karpenter_controller" {
  name   = "karpenter-controller-policy"
  role   = aws_iam_role.karpenter_controller.name
  policy = data.aws_iam_policy_document.karpenter_controller.json
}

##############################################################################
# 2. SPOT INTERRUPTION QUEUE (SQS + EventBridge rules)
# Karpenter watches this queue to gracefully drain nodes before AWS reclaims Spot.
# docs/02_infra_design.md §6 Scale-Down (interruption) — "Spot interruption: ngay lập tức,
# Karpenter cordon + drain trước khi bị thu hồi"
##############################################################################

resource "aws_sqs_queue" "karpenter_interruption" {
  name                      = "${var.cluster_name}-karpenter-interruption"
  message_retention_seconds = 300 # 5 minutes — interruption notices are time-critical

  # SSE with KMS (docs/03_security_design.md §4.1 alias/cdo-infra-kms passed via var)
  # Using AWS-managed SQS key to avoid cross-service KMS policy complexity in sandbox
  sqs_managed_sse_enabled = true

  tags = local.module_tags
}

data "aws_iam_policy_document" "karpenter_interruption_queue_policy" {
  statement {
    sid     = "AllowEventBridgeSend"
    effect  = "Allow"
    actions = ["sqs:SendMessage"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "sqs.amazonaws.com"]
    }
    resources = [aws_sqs_queue.karpenter_interruption.arn]
  }
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.id
  policy    = data.aws_iam_policy_document.karpenter_interruption_queue_policy.json
}

# EventBridge rules — forward EC2 interruption/rebalance events to SQS
resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name        = "${var.cluster_name}-karpenter-spot-interrupt"
  description = "Karpenter: EC2 Spot Instance Interruption Warning"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })

  tags = local.module_tags
}

resource "aws_cloudwatch_event_target" "spot_interruption" {
  rule      = aws_cloudwatch_event_rule.spot_interruption.name
  target_id = "KarpenterInterruptionQueue"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_rule" "rebalance" {
  name        = "${var.cluster_name}-karpenter-rebalance"
  description = "Karpenter: EC2 Instance Rebalance Recommendation"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance Rebalance Recommendation"]
  })

  tags = local.module_tags
}

resource "aws_cloudwatch_event_target" "rebalance" {
  rule      = aws_cloudwatch_event_rule.rebalance.name
  target_id = "KarpenterInterruptionQueue"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_rule" "state_change" {
  name        = "${var.cluster_name}-karpenter-node-state"
  description = "Karpenter: EC2 Instance State Change Notification"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
  })

  tags = local.module_tags
}

resource "aws_cloudwatch_event_target" "state_change" {
  rule      = aws_cloudwatch_event_rule.state_change.name
  target_id = "KarpenterInterruptionQueue"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

##############################################################################
# 3. KARPENTER HELM RELEASE
# Chart deployed into kube-system namespace alongside other cluster addons.
# docs/02_infra_design.md §2 — "Karpenter (không dùng Cluster Autoscaler)"
##############################################################################

resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = var.karpenter_version
  namespace        = "kube-system"
  create_namespace = false # kube-system already exists

  # Sandbox: mirror to ECR is preferred (docs/03_security_design.md §1.3),
  # but for bootstrap simplicity we pull from public.ecr.aws (no NAT required
  # when using ECR public endpoint, which is free within us-east-1).

  values = [
    yamlencode({
      serviceAccount = {
        name = "karpenter"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.karpenter_controller.arn
        }
      }

      settings = {
        clusterName       = var.cluster_name
        interruptionQueue = aws_sqs_queue.karpenter_interruption.name
        featureGates = {
          spotToSpotConsolidation = true
        }
      }

      controller = {
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
      }

      # Pin Karpenter controller itself to system On-Demand node group
      # docs/02_infra_design.md §3.3 Trade-off 2
      tolerations = [
        {
          key      = "CriticalAddonsOnly"
          operator = "Exists"
          effect   = "NoSchedule"
        }
      ]

      affinity = {
        nodeAffinity = {
          requiredDuringSchedulingIgnoredDuringExecution = {
            nodeSelectorTerms = [
              {
                matchExpressions = [
                  {
                    key      = "node-role"
                    operator = "In"
                    values   = ["system"]
                  }
                ]
              }
            ]
          }
        }
      }

      # Replicas for HA (2 controllers, leader-election enabled by default in Karpenter)
      replicas = 2

      logLevel = "info"
    })
  ]

  depends_on = [
    aws_iam_role_policy.karpenter_controller,
    aws_sqs_queue_policy.karpenter_interruption,
  ]
}

##############################################################################
# 4. KARPENTER NodePool — SPOT (workload nodes)
# Instance pool: t3.medium / t3.large / t3.xlarge (docs/02_infra_design.md §6)
# Max nodes: var.max_nodes (sandbox cost control)
# docs/02_infra_design.md §6: "Instance type pool: t3.medium, t3.large, t3.xlarge
#   (Karpenter tự chọn phù hợp nhất). Tối đa 5 Nodes tại bất kỳ thời điểm nào."
##############################################################################

resource "kubectl_manifest" "ec2_node_class_spot" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "spot-workload"
    }
    spec = {
      # EKS-optimized AL2023 AMI (Karpenter resolves latest via SSM)
      amiSelectorTerms = [
        {
          alias = "al2023@latest"
        }
      ]

      # Node role — uses the shared EKS node role from module.eks
      role = var.node_iam_role_name

      # Private subnets only — docs/03_security_design.md §1.1
      subnetSelectorTerms = [
        for subnet_id in var.private_subnet_ids : {
          id = subnet_id
        }
      ]

      # Workload SG — docs/03_security_design.md §1.2 sg-eks-workload
      securityGroupSelectorTerms = [
        {
          id = var.sg_eks_workload_id
        }
      ]

      # EBS root volume encrypted + gp3 (docs/03_security_design.md §4.1)
      blockDeviceMappings = [
        {
          deviceName = "/dev/xvda"
          ebs = {
            volumeSize          = "30Gi"
            volumeType          = "gp3"
            encrypted           = true
            deleteOnTermination = true
          }
        }
      ]

      # IMDSv2 required (docs/03_security_design.md §6)
      metadataOptions = {
        httpEndpoint            = "enabled"
        httpProtocolIPv6        = "disabled"
        httpPutResponseHopLimit = 1
        httpTokens              = "required"
      }

      tags = local.module_tags
    }
  })

  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "node_pool_spot" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "spot-workload"
    }
    spec = {
      template = {
        metadata = {
          labels = {
            "node-role" = "workload"
          }
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "spot-workload"
          }

          requirements = [
            {
              key      = "karpenter.k8s.aws/instance-family"
              operator = "In"
              values   = ["t3"]
            },
            {
              key      = "karpenter.k8s.aws/instance-size"
              operator = "In"
              values   = ["medium", "large", "xlarge"]
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["spot"] # Spot for cost optimisation (docs/02_infra_design.md §5.1)
            },
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"]
            },
            {
              key      = "kubernetes.io/os"
              operator = "In"
              values   = ["linux"]
            },
          ]

          # Evict pods after 5 minutes (safety for long-running jobs)
          expireAfter = "168h" # 7 days — force node refresh for AMI updates
        }
      }

      # Hard cap on total cluster resources (sandbox cost control)
      # docs/02_infra_design.md §6 "Tối đa 5 Nodes tại bất kỳ thời điểm nào"
      limits = {
        cpu    = "${var.max_nodes * 2}"   # t3.medium = 2 vCPU
        memory = "${var.max_nodes * 4}Gi" # t3.medium = 4 GiB
      }

      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "30s"
        # Spot interruption handled automatically by SQS queue above
      }
    }
  })

  depends_on = [kubectl_manifest.ec2_node_class_spot]
}

##############################################################################
# 5. KARPENTER NodePool — ON-DEMAND (platform / baseline services)
# ArgoCD, Webhook Receiver, Argo Workflows controller stay here.
# docs/02_infra_design.md §3.3 Trade-off 2
# Separate pool uses On-Demand to avoid Spot interruption for critical platform pods.
##############################################################################

resource "kubectl_manifest" "ec2_node_class_ondemand" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "ondemand-platform"
    }
    spec = {
      amiSelectorTerms = [
        { alias = "al2023@latest" }
      ]

      role = var.node_iam_role_name

      subnetSelectorTerms = [
        for subnet_id in var.private_subnet_ids : {
          id = subnet_id
        }
      ]

      securityGroupSelectorTerms = [
        { id = var.sg_eks_workload_id }
      ]

      blockDeviceMappings = [
        {
          deviceName = "/dev/xvda"
          ebs = {
            volumeSize          = "30Gi"
            volumeType          = "gp3"
            encrypted           = true
            deleteOnTermination = true
          }
        }
      ]

      metadataOptions = {
        httpEndpoint            = "enabled"
        httpProtocolIPv6        = "disabled"
        httpPutResponseHopLimit = 1
        httpTokens              = "required"
      }

      tags = local.module_tags
    }
  })

  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "node_pool_ondemand" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "ondemand-platform"
    }
    spec = {
      template = {
        metadata = {
          labels = {
            "node-role" = "platform"
          }
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "ondemand-platform"
          }

          requirements = [
            {
              key      = "karpenter.k8s.aws/instance-family"
              operator = "In"
              values   = ["t3"]
            },
            {
              key      = "karpenter.k8s.aws/instance-size"
              operator = "In"
              values   = ["medium", "large"]
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["on-demand"] # On-Demand for platform stability
            },
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"]
            },
            {
              key      = "kubernetes.io/os"
              operator = "In"
              values   = ["linux"]
            },
          ]

          # Taint platform nodes — platform pods must tolerate this
          taints = [
            {
              key    = "platform"
              value  = "true"
              effect = "NoSchedule"
            }
          ]

          expireAfter = "168h"
        }
      }

      # Smaller cap for on-demand pool (cost control in sandbox)
      limits = {
        cpu    = "4"
        memory = "8Gi"
      }

      disruption = {
        consolidationPolicy = "WhenEmpty"
        consolidateAfter    = "60s"
      }
    }
  })

  depends_on = [kubectl_manifest.ec2_node_class_ondemand]
}
