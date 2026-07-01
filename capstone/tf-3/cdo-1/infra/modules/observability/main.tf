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
# CLOUDWATCH LOG GROUP — EKS Control Plane (AWS resource — skip in mock mode)
# Tạo trước để tránh ResourceAlreadyExists khi EKS tự tạo cùng tên
# =============================================================================

resource "aws_cloudwatch_log_group" "eks_control_plane" {
  count             = var.enabled ? 1 : 0
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 90
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

  lifecycle {
    ignore_changes = [metadata[0].annotations]
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
  timeout    = 600

  values = [
    yamlencode({
      fullnameOverride = "kube-prometheus-stack"
      global = {
        imageRegistry = local.ecr_registry
      }

      prometheusOperator = {
        enabled = true
        image = {
          repository = "prometheus-operator/prometheus-operator"
          tag        = "v0.74.0"
        }
        prometheusConfigReloader = {
          image = {
            repository = "prometheus-operator/prometheus-config-reloader"
            tag        = "v0.74.0"
          }
        }
        # NAT-less: admission webhook certgen image ph?i tr? v? ECR Private
        admissionWebhooks = {
          patch = {
            image = {
              registry   = local.ecr_registry
              repository = "ingress-nginx/kube-webhook-certgen"
              tag        = "v20221220-controller-v1.5.1-58-g787ea74b6"
            }
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
            repository = "prometheus/prometheus"
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
            repository = "prometheus/alertmanager"
            tag        = "v0.27.0"
          }
          # Mặc định của prometheus-operator là "OnNamespace": route của một
          # AlertmanagerConfig chỉ áp dụng cho alert có namespace label bằng
          # đúng namespace của chính CR đó. CR routing đa-tenant của CDO nằm ở
          # namespace "observability" nhưng phải xử lý alert có namespace
          # "tenant-payment"/"tenant-checkout" -> bắt buộc "None" để route áp
          # dụng cho mọi alert bất kể namespace nào phát sinh.
          alertmanagerConfigMatcherStrategy = {
            type = "None"
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
                name = "null"
              },
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
          repository = "grafana/grafana"
          tag        = "10.4.3"
        }
        sidecar = {
          image = {
            repository = "kiwigrid/k8s-sidecar"
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
          repository = "kube-state-metrics/kube-state-metrics"
          tag        = "v2.12.0"
        }
      }

      "prometheus-node-exporter" = {
        enabled = true
        image = {
          repository = "prometheus/node-exporter"
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
# CLOUDWATCH LOG GROUP & STREAM — Kinesis Firehose error logging (AWS — skip in mock mode)
# =============================================================================

resource "aws_cloudwatch_log_group" "firehose" {
  count             = var.enabled ? 1 : 0
  name              = "/aws/kinesisfirehose/tf3-cdo1-sandbox-audit-stream"
  retention_in_days = 90
  kms_key_id        = var.kms_observability_arn

  tags = local.module_tags
}

resource "aws_cloudwatch_log_stream" "firehose" {
  count          = var.enabled ? 1 : 0
  name           = "S3Delivery"
  log_group_name = aws_cloudwatch_log_group.firehose[0].name
}

# =============================================================================
# IAM ROLE — Kinesis Firehose delivery role (AWS — skip in mock mode)
# =============================================================================

resource "aws_iam_role" "firehose" {
  count = var.enabled ? 1 : 0
  name  = "${var.name_prefix}-${var.environment}-firehose-role"

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
  count = var.enabled ? 1 : 0
  name  = "firehose-s3-kms-cw"
  role  = aws_iam_role.firehose[0].id

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
          aws_cloudwatch_log_group.firehose[0].arn,
          "${aws_cloudwatch_log_group.firehose[0].arn}:*",
        ]
      },
    ]
  })
}

# =============================================================================
# KINESIS FIREHOSE DELIVERY STREAM — tf3-cdo1-sandbox-audit-stream (AWS — skip in mock mode)
# =============================================================================

resource "aws_kinesis_firehose_delivery_stream" "audit_stream" {
  count       = var.enabled ? 1 : 0
  name        = "tf3-cdo1-sandbox-audit-stream"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn    = aws_iam_role.firehose[0].arn
    bucket_arn  = var.s3_audit_bucket_arn
    kms_key_arn = var.kms_audit_arn

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose[0].name
      log_stream_name = aws_cloudwatch_log_stream.firehose[0].name
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
  message_retention_seconds = 1209600                   # 14 days
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
        Resource = "arn:aws:dynamodb:*:*:table/tf-3-aiops-app-idempotency-lock"
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
        Resource = var.enabled ? [aws_kinesis_firehose_delivery_stream.audit_stream[0].arn] : ["*"]
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
        Resource = "arn:aws:dynamodb:*:*:table/tf-3-aiops-app-idempotency-lock"
      },
      {
        Sid    = "CodeCommitAccess"
        Effect = "Allow"
        Action = [
          "codecommit:GitPull",
          "codecommit:GitPush",
          "codecommit:GetRepository",
          "codecommit:GetBranch",
          "codecommit:GetCommit"
        ]
        Resource = "*"
      }
    ]
  })
}








# =============================================================================
# SECRETS MANAGER � ArgoCD Auth Token (cho SQS Worker)
# # Team 3 s? update gi� tr? th?t sau khi deploy ArgoCD
# =============================================================================

resource "aws_secretsmanager_secret" "argocd_auth" {
  name                    = "tf3-cdo1-sandbox/argocd-auth-token"
  description             = "ArgoCD ServiceAccount bearer token cho SQS Worker t? d?ng suspend/resume auto-sync"
  recovery_window_in_days = 0

  tags = local.module_tags
}

# =============================================================================
# IAM ROLE � IRSA cho AI Engine Bedrock (ai-engine)
# ServiceAccount: ai-engine trong namespace self-heal-system
# =============================================================================

resource "aws_iam_role" "ai_engine_irsa" {
  name = "${var.name_prefix}-${var.environment}-irsa-ai-engine-bedrock"

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
            "${replace(var.oidc_provider_arn, "/^arn:aws:iam::[0-9]+:oidc-provider\\//", "")}:sub" : "system:serviceaccount:self-heal-system:ai-engine",
            "${replace(var.oidc_provider_arn, "/^arn:aws:iam::[0-9]+:oidc-provider\\//", "")}:aud" : "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = local.module_tags
}

resource "aws_iam_role_policy" "ai_engine_irsa" {
  name = "ai-engine-irsa-policy"
  role = aws_iam_role.ai_engine_irsa.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BedrockFoundationModelAccess"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
        ]
        # foundation-model: direct model access (Claude, Titan, etc.)
        # inference-profile: cross-region inference profiles (us.meta.llama4-*, us.anthropic.*)
        Resource = [
          "arn:aws:bedrock:us-east-1::foundation-model/*",
          "arn:aws:bedrock:us-east-1::inference-profile/*",
        ]
      }
    ]
  })
}

# =============================================================================
# IAM ROLE — IRSA cho External Secrets Operator
# ServiceAccount: external-secrets trong namespace external-secrets-system
# Cho phép ESO đọc tf3-cdo1-sandbox/* từ AWS Secrets Manager để cấp
# ARGOCD_AUTH_TOKEN cho sqs-worker qua ExternalSecret → ClusterSecretStore
# =============================================================================

resource "aws_iam_role" "eso_irsa" {
  name = "${var.name_prefix}-${var.environment}-irsa-eso-secrets-reader"

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
            "${replace(var.oidc_provider_arn, "/^arn:aws:iam::[0-9]+:oidc-provider\\//", "")}:sub" : "system:serviceaccount:external-secrets-system:external-secrets",
            "${replace(var.oidc_provider_arn, "/^arn:aws:iam::[0-9]+:oidc-provider\\//", "")}:aud" : "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = local.module_tags
}

resource "aws_iam_role_policy" "eso_irsa" {
  name = "eso-irsa-policy"
  role = aws_iam_role.eso_irsa.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SecretsManagerRead"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
        ]
        Resource = "arn:aws:secretsmanager:us-east-1:474013238625:secret:tf3-cdo1-sandbox/*"
      }
    ]
  })
}


