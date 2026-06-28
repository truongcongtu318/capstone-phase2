# =============================================================================
# MODULE: observability — Kube-Prometheus-Stack + Kinesis Firehose Audit Stream
# NAT-less: tất cả images phải trỏ về ECR Private 474013238625.dkr.ecr.us-east-1.amazonaws.com
# Fix #2: Alert routing trỏ đúng tên service webhook-receiver (KHÔNG phải patch-receiver)
# =============================================================================

locals {
  namespace       = "observability"
  grafana_service = "kube-prometheus-stack-grafana"
  ecr_registry    = "474013238625.dkr.ecr.us-east-1.amazonaws.com"

  # Fix #2: Tên service chuẩn của dự án là webhook-receiver (theo MEMORY.md)
  alert_receiver_url = "http://webhook-receiver.self-heal-system.svc.cluster.local:8443/alerts"
}

# =============================================================================
# CLOUDWATCH LOG GROUP — EKS Control Plane (AWS resource — no count, always planned)
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
# count = var.enabled ? 1 : 0: bỏ qua khi mock mode (EKS chưa tồn tại)
# =============================================================================

resource "kubernetes_namespace" "observability" {
  count = var.enabled ? 1 : 0

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
# count = var.enabled ? 1 : 0: bỏ qua khi mock mode
# NAT-less: override toàn bộ image repository về ECR Private
# =============================================================================

resource "helm_release" "kube_prometheus_stack" {
  count = var.enabled ? 1 : 0

  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = kubernetes_namespace.observability[0].metadata[0].name
  version    = "61.7.2"

  values = [
    yamlencode({
      fullnameOverride = "kube-prometheus-stack"

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

      # Fix #2: alert_receiver_url dùng webhook-receiver (không phải patch-receiver)
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

      "kube-state-metrics" = {
        enabled = true
        image = {
          repository = "${local.ecr_registry}/kube-state-metrics/kube-state-metrics"
          tag        = "v2.12.0"
        }
      }

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
# CLOUDWATCH LOG GROUP & STREAM — Kinesis Firehose error logging (AWS — no count)
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
# IAM ROLE — Kinesis Firehose delivery role (AWS — no count)
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
# KINESIS FIREHOSE DELIVERY STREAM — tf3-cdo1-sandbox-audit-stream (AWS — no count)
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
# AWS SQS & SNS RESOURCES — Alerts Pipeline (AWS — no count)
# =============================================================================

resource "aws_sqs_queue" "self_heal_dlq" {
  name                      = "${var.name_prefix}-${var.environment}-self-heal-dlq"
  message_retention_seconds = 1209600 # 14 days
  kms_master_key_id         = var.kms_observability_arn # dùng chung key mã hóa monitoring

  tags = local.module_tags
}

resource "aws_sqs_queue" "self_heal_queue" {
  name                      = "${var.name_prefix}-${var.environment}-self-heal-queue"
  delay_seconds             = 0
  max_message_size          = 262144
  message_retention_seconds = 345600 # 4 days
  receive_wait_time_seconds = 20     # Long polling enabled
  kms_master_key_id         = var.kms_observability_arn

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.self_heal_dlq.arn
    maxReceiveCount     = 3
  })

  tags = local.module_tags
}

resource "aws_sns_topic" "alerts_escalation" {
  name              = "${var.name_prefix}-${var.environment}-alerts-escalation"
  kms_master_key_id = var.kms_observability_arn

  tags = local.module_tags
}

# =============================================================================
# IAM ROLE — IRSA cho FastAPI Webhook webhook-receiver (AWS — no count)
# =============================================================================

resource "aws_iam_role" "webhook_irsa" {
  name = "${var.name_prefix}-${var.environment}-irsa-webhook-receiver"

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
            "${replace(var.oidc_provider_arn, "/^arn:aws:iam::[0-9]+:oidc-provider\\//", "")}:sub" : "system:serviceaccount:self-heal-system:webhook-receiver",
            "${replace(var.oidc_provider_arn, "/^arn:aws:iam::[0-9]+:oidc-provider\\//", "")}:aud" : "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = local.module_tags
}

resource "aws_iam_role_policy" "webhook_irsa" {
  name = "webhook-irsa-policy"
  role = aws_iam_role.webhook_irsa.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SQSSendAccess"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:GetQueueAttributes",
        ]
        Resource = [aws_sqs_queue.self_heal_queue.arn]
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
      {
        Sid    = "KMSAccess"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
        ]
        Resource = [var.kms_observability_arn] # Webhook encrypt message trước khi gửi SQS
      }
    ]
  })
}

# =============================================================================
# IAM ROLE — IRSA cho SQS Worker self-heal-executor (AWS — no count)
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
        Resource = [
          var.kms_audit_arn,
          var.kms_observability_arn
        ]
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
        Resource = [
          aws_sqs_queue.self_heal_queue.arn,
          aws_sqs_queue.self_heal_dlq.arn
        ]
      },
      {
        Sid      = "SNSAccess"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = [aws_sns_topic.alerts_escalation.arn]
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
