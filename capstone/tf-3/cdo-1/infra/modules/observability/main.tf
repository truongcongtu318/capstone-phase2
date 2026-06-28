# =============================================================================
# MODULE: observability — Kube-Prometheus-Stack + Kinesis Firehose Audit Stream
# NAT-less: tất cả images phải trỏ về ECR Private 474013238625.dkr.ecr.us-east-1.amazonaws.com
# Alert routing: Alertmanager → patch-receiver.self-heal-system.svc.cluster.local:8443/alerts
# =============================================================================

locals {
  namespace       = "observability"
  grafana_service = "kube-prometheus-stack-grafana"
  ecr_registry    = "474013238625.dkr.ecr.us-east-1.amazonaws.com"

  # Alertmanager → Webhook Receiver (ClusterDNS — không cần NAT)
  alert_receiver_url = "http://patch-receiver.self-heal-system.svc.cluster.local:8443/alerts"
}

# =============================================================================
# CLOUDWATCH LOG GROUP — EKS Control Plane
# Tạo trước để tránh ResourceAlreadyExists khi EKS tự tạo cùng tên
# =============================================================================

resource "aws_cloudwatch_log_group" "eks_control_plane" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 30
  kms_key_id        = var.kms_observability_arn

  tags = local.module_tags
}

# =============================================================================
# KUBERNETES NAMESPACE — observability
# Label protected=true: ngăn self-heal-executor tác động vào namespace này
# =============================================================================

resource "kubernetes_namespace" "observability" {
  metadata {
    name = local.namespace
    labels = {
      "app.kubernetes.io/name"       = local.namespace
      "platform.tf3-cdo1/protected"  = "true"
      "self-heal.tf3-cdo1/mutate-ok" = "false"
    }
  }
}

# =============================================================================
# HELM RELEASE — Kube-Prometheus-Stack
# NAT-less: override toàn bộ image repository về ECR Private
# Alertmanager config: route alert về self-heal webhook receiver
# =============================================================================

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = kubernetes_namespace.observability.metadata[0].name
  version    = "61.7.2"

  values = [
    yamlencode({
      fullnameOverride = "kube-prometheus-stack"

      # -----------------------------------------------------------------------
      # Prometheus Operator — NAT-less ECR override
      # -----------------------------------------------------------------------
      prometheusOperator = {
        enabled = true
        image = {
          repository = "${local.ecr_registry}/prometheus-operator/prometheus-operator"
          tag        = "v0.74.0"
        }
        prometheusConfigReloader = {
          image = {
            repository = "${local.ecr_registry}/prometheus-operator/prometheus-config-reloader"
            tag        = "v0.74.0"
          }
        }
      }

      # -----------------------------------------------------------------------
      # Prometheus Server — NAT-less ECR override
      # -----------------------------------------------------------------------
      prometheus = {
        enabled = true
        service = {
          type = "ClusterIP"
        }
        prometheusSpec = {
          retention = "7d"
          replicas  = 1
          image = {
            repository = "${local.ecr_registry}/prometheus/prometheus"
            tag        = "v2.52.0"
          }
          serviceMonitorSelectorNilUsesHelmValues = false
          podMonitorSelectorNilUsesHelmValues     = false
          ruleSelectorNilUsesHelmValues           = false
        }
      }

      # -----------------------------------------------------------------------
      # Alertmanager — NAT-less ECR override + route về self-heal webhook
      # -----------------------------------------------------------------------
      alertmanager = {
        enabled = true
        service = {
          type = "ClusterIP"
        }
        alertmanagerSpec = {
          replicas = 1
          image = {
            repository = "${local.ecr_registry}/prometheus/alertmanager"
            tag        = "v0.27.0"
          }
        }
        config = {
          global = {
            resolve_timeout = "5m"
          }
          route = {
            group_by        = ["alertname", "namespace", "service"]
            group_wait      = "10s"
            group_interval  = "1m"
            repeat_interval = "30m"
            receiver        = "self-heal-receiver"
          }
          receivers = [
            {
              name = "self-heal-receiver"
              webhook_configs = [
                {
                  url           = local.alert_receiver_url
                  send_resolved = true
                }
              ]
            }
          ]
        }
      }

      # -----------------------------------------------------------------------
      # Grafana — NAT-less ECR override
      # -----------------------------------------------------------------------
      grafana = {
        enabled = true
        service = {
          type = "ClusterIP"
        }
        image = {
          repository = "${local.ecr_registry}/grafana/grafana"
          tag        = "10.4.3"
        }
        sidecar = {
          image = {
            repository = "${local.ecr_registry}/kiwigrid/k8s-sidecar"
            tag        = "1.27.4"
          }
          dashboards = {
            enabled = true
          }
          datasources = {
            enabled = true
          }
        }
      }

      # -----------------------------------------------------------------------
      # Kube State Metrics — NAT-less ECR override
      # -----------------------------------------------------------------------
      "kube-state-metrics" = {
        enabled = true
        image = {
          repository = "${local.ecr_registry}/kube-state-metrics/kube-state-metrics"
          tag        = "v2.12.0"
        }
      }

      # -----------------------------------------------------------------------
      # Node Exporter — NAT-less ECR override
      # -----------------------------------------------------------------------
      "prometheus-node-exporter" = {
        enabled = true
        image = {
          repository = "${local.ecr_registry}/prometheus/node-exporter"
          tag        = "v1.8.1"
        }
      }
    })
  ]

  depends_on = [
    aws_cloudwatch_log_group.eks_control_plane,
    kubernetes_namespace.observability,
  ]
}

# =============================================================================
# CLOUDWATCH LOG GROUP & STREAM — Kinesis Firehose error logging
# =============================================================================

resource "aws_cloudwatch_log_group" "firehose" {
  name              = "/aws/kinesisfirehose/tf3-cdo1-sandbox-audit-stream"
  retention_in_days = 30
  kms_key_id        = var.kms_observability_arn

  tags = local.module_tags
}

resource "aws_cloudwatch_log_stream" "firehose" {
  name           = "S3Delivery"
  log_group_name = aws_cloudwatch_log_group.firehose.name
}

# =============================================================================
# IAM ROLE — Kinesis Firehose delivery role
# =============================================================================

resource "aws_iam_role" "firehose" {
  name = "${var.name_prefix}-${var.environment}-firehose-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "firehose.amazonaws.com"
        }
      }
    ]
  })

  tags = local.module_tags
}

resource "aws_iam_role_policy" "firehose" {
  name = "firehose-s3-kms-cw"
  role = aws_iam_role.firehose.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3Access"
        Effect = "Allow"
        Action = [
          "s3:AbortMultipartUpload",
          "s3:GetBucketLocation",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:ListBucketMultipartUploads",
          "s3:PutObject",
        ]
        Resource = [
          var.s3_audit_bucket_arn,
          "${var.s3_audit_bucket_arn}/*",
        ]
      },
      {
        Sid    = "KMSAccess"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
        ]
        Resource = [var.kms_audit_arn]
      },
      {
        Sid    = "CloudWatchAccess"
        Effect = "Allow"
        Action = [
          "logs:PutLogEvents",
          "logs:CreateLogStream",
        ]
        Resource = [
          aws_cloudwatch_log_group.firehose.arn,
          "${aws_cloudwatch_log_group.firehose.arn}:*",
        ]
      },
    ]
  })
}

# =============================================================================
# KINESIS FIREHOSE DELIVERY STREAM — tf3-cdo1-sandbox-audit-stream
# Đích: S3 Audit Bucket (Object Lock COMPLIANCE 90 days)
# =============================================================================

resource "aws_kinesis_firehose_delivery_stream" "audit_stream" {
  name        = "tf3-cdo1-sandbox-audit-stream"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn    = aws_iam_role.firehose.arn
    bucket_arn  = var.s3_audit_bucket_arn
    kms_key_arn = var.kms_audit_arn

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose.name
      log_stream_name = aws_cloudwatch_log_stream.firehose.name
    }
  }

  tags = local.module_tags

  depends_on = [aws_iam_role_policy.firehose]
}

# =============================================================================
# IAM ROLE — IRSA cho SQS Worker (self-heal-executor ServiceAccount)
# Quyền: Firehose PutRecord, SQS receive/delete, SNS publish, DynamoDB lock
# =============================================================================

resource "aws_iam_role" "worker_irsa" {
  name = "${var.name_prefix}-${var.environment}-irsa-audit-writer"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = var.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(var.oidc_provider_arn, "/^arn:aws:iam::[0-9]+:oidc-provider\\//", "")}:sub" : "system:serviceaccount:self-heal-system:self-heal-executor",
            "${replace(var.oidc_provider_arn, "/^arn:aws:iam::[0-9]+:oidc-provider\\//", "")}:aud" : "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = local.module_tags
}

resource "aws_iam_role_policy" "worker_irsa" {
  name = "worker-irsa-policy"
  role = aws_iam_role.worker_irsa.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "FirehoseAccess"
        Effect = "Allow"
        Action = [
          "firehose:PutRecord",
          "firehose:PutRecordBatch",
        ]
        Resource = [aws_kinesis_firehose_delivery_stream.audit_stream.arn]
      },
      {
        Sid    = "KMSAccess"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
        ]
        Resource = [var.kms_audit_arn]
      },
      {
        Sid    = "SQSAccess"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:ChangeMessageVisibility",
        ]
        Resource = "arn:aws:sqs:*:*:*"
      },
      {
        Sid      = "SNSAccess"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = "arn:aws:sns:*:*:*"
      },
      {
        Sid    = "DynamoDBAccess"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
        ]
        Resource = "arn:aws:dynamodb:*:*:table/tf-3-aiops-idempotency-lock"
      },
    ]
  })
}
