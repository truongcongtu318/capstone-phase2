locals {
  namespace       = "observability"
  grafana_service = "kube-prometheus-stack-grafana"

  # Alertmanager → webhook receiver
  # Service name: patch-receiver (or we can use our unified self-heal-executor name/endpoint)
  # Wait, let's keep the alert receiver service name as defined in gitops/manifests or similar
  alert_receiver_url = "http://patch-receiver.self-heal-system.svc.cluster.local:8443/alerts"
}

# EKS Control Plane Log Group
# Terraform manages it (created before EKS cluster is provisioned if called in early state, or dynamically)
resource "aws_cloudwatch_log_group" "eks_control_plane" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 30
  kms_key_id        = var.kms_observability_arn

  tags = local.module_tags
}

# Observability namespace
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

# Prometheus Stack (Helm Chart)
resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = kubernetes_namespace.observability.metadata[0].name
  version    = "61.7.2"

  values = [
    yamlencode({
      fullnameOverride = "kube-prometheus-stack"

      alertmanager = {
        enabled = true
        service = {
          type = "ClusterIP"
        }
        alertmanagerSpec = {
          replicas = 1
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
        sidecar = {
          dashboards = {
            enabled = true
          }
          datasources = {
            enabled = true
          }
        }
      }

      prometheus = {
        enabled = true
        service = {
          type = "ClusterIP"
        }
        prometheusSpec = {
          retention                               = "7d"
          replicas                                = 1
          serviceMonitorSelectorNilUsesHelmValues = false
          podMonitorSelectorNilUsesHelmValues     = false
          ruleSelectorNilUsesHelmValues           = false
        }
      }

      prometheusOperator = {
        enabled = true
      }

      "kube-state-metrics" = {
        enabled = true
      }

      "prometheus-node-exporter" = {
        enabled = true
      }
    })
  ]

  depends_on = [
    aws_cloudwatch_log_group.eks_control_plane,
    kubernetes_namespace.observability,
  ]
}

# =============================================================================
# KINESIS DATA FIREHOSE DELIVERY STREAM & CLOUDWATCH LOGGING
# =============================================================================

# CloudWatch Log Group for Firehose error logging (team 3 requirement)
resource "aws_cloudwatch_log_group" "firehose" {
  name              = "/aws/kinesisfirehose/tf3-cdo1-sandbox-audit-stream"
  retention_in_days = 30
  kms_key_id        = var.kms_observability_arn # Encrypted with observability key

  tags = local.module_tags
}

resource "aws_cloudwatch_log_stream" "firehose" {
  name           = "S3Delivery"
  log_group_name = aws_cloudwatch_log_group.firehose.name
}

# Firehose IAM Role and policy
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

resource "aws_iam_role_policy" "firehose_policy" {
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
          "s3:PutObject"
        ]
        Resource = [
          var.s3_audit_bucket_arn,
          "${var.s3_audit_bucket_arn}/*"
        ]
      },
      {
        Sid    = "KMSAccess"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = [
          var.kms_audit_arn
        ]
      },
      {
        Sid    = "CloudWatchAccess"
        Effect = "Allow"
        Action = [
          "logs:PutLogEvents",
          "logs:CreateLogStream"
        ]
        Resource = [
          aws_cloudwatch_log_group.firehose.arn,
          "${aws_cloudwatch_log_group.firehose.arn}:*"
        ]
      }
    ]
  })
}

# Kinesis Firehose Delivery Stream
resource "aws_kinesis_firehose_delivery_stream" "audit_stream" {
  name        = "tf3-cdo1-sandbox-audit-stream"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose.arn
    bucket_arn = var.s3_audit_bucket_arn

    # Encryption configuration using cdo-audit-kms KMS Key
    kms_key_arn = var.kms_audit_arn

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose.name
      log_stream_name = aws_cloudwatch_log_stream.firehose.name
    }
  }

  tags = local.module_tags

  depends_on = [
    aws_iam_role_policy.firehose_policy
  ]
}

# =============================================================================
# EKS IRSA ROLE FOR WORKER SERVICE ACCOUNT (self-heal-executor)
# =============================================================================

# IRSA role allowing Worker to PutRecords to Firehose, read SQS, publish SNS, lock DynamoDB
resource "aws_iam_role" "worker_irsa" {
  name = "${var.name_prefix}-${var.environment}-worker-irsa"

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

resource "aws_iam_role_policy" "worker_policy" {
  name = "worker-policy"
  role = aws_iam_role.worker_irsa.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "FirehoseAccess"
        Effect = "Allow"
        Action = [
          "firehose:PutRecord",
          "firehose:PutRecordBatch"
        ]
        Resource = [
          aws_kinesis_firehose_delivery_stream.audit_stream.arn
        ]
      },
      {
        Sid    = "KMSAccess"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = [
          var.kms_audit_arn
        ]
      },
      {
        Sid    = "SQSAccess"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:ChangeMessageVisibility"
        ]
        Resource = "arn:aws:sqs:*:*:*"
      },
      {
        Sid    = "SNSAccess"
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = "arn:aws:sns:*:*:*"
      },
      {
        Sid    = "DynamoDBAccess"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem"
        ]
        Resource = "arn:aws:dynamodb:*:*:table/tf-3-aiops-idempotency-lock"
      }
    ]
  })
}
