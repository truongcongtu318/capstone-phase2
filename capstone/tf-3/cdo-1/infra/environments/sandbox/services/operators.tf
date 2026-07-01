# =============================================================================
# CRD OPERATORS — External Secrets, Kyverno, Argo Workflows, Argo Rollouts
# Images mirror từ ghcr.io/quay.io sang ECR (xem mirror-list.txt)
# =============================================================================

locals {
  ecr_registry = "474013238625.dkr.ecr.us-east-1.amazonaws.com"
}

# -----------------------------------------------------------------------------
# 1. External Secrets Operator
# -----------------------------------------------------------------------------

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "0.9.13"
  namespace        = "external-secrets-system"
  create_namespace = true

  timeout = 900
  wait    = false

  values = [
    yamlencode({
      installCRDs = true
      image = {
        repository = "${local.ecr_registry}/external-secrets/external-secrets"
        tag        = "v0.9.13"
      }
      certController = {
        image = {
          repository = "${local.ecr_registry}/external-secrets/external-secrets"
          tag        = "v0.9.13"
        }
      }
      webhook = {
        image = {
          repository = "${local.ecr_registry}/external-secrets/external-secrets"
          tag        = "v0.9.13"
        }
      }
      serviceAccount = {
        create = true
        name   = "external-secrets"
        annotations = {
          "eks.amazonaws.com/role-arn" = module.observability.eso_irsa_role_arn
        }
      }
      resources = {
        limits   = { cpu = "200m", memory = "256Mi" }
        requests = { cpu = "100m", memory = "128Mi" }
      }
      env = [
        {
          name  = "AWS_STS_REGIONAL_ENDPOINTS"
          value = "regional"
        }
      ]
    })
  ]
}

# -----------------------------------------------------------------------------
# 2. Kyverno — Policy Engine (v1.12.5 để khớp mirror-list)
# -----------------------------------------------------------------------------

resource "helm_release" "kyverno" {
  name             = "kyverno"
  repository       = "https://kyverno.github.io/kyverno"
  chart            = "kyverno"
  version          = "3.2.6"
  namespace        = "kyverno"
  create_namespace = true

  timeout = 900
  wait    = false

  values = [
    yamlencode({
      installCRDs = true
      replicaCount = 1
      global = {
        image = {
          registry = local.ecr_registry
        }
      }
      admissionController = {
        replicas = 1
        container = {
          image = {
            registry   = local.ecr_registry
            repository = "kyverno/kyverno"
            tag        = "v1.12.5"
          }
        }
        initContainer = {
          image = {
            registry   = local.ecr_registry
            repository = "kyverno/kyvernopre"
            tag        = "v1.12.5"
          }
        }
      }
      backgroundController = {
        replicas = 1
        container = {
          image = {
            registry   = local.ecr_registry
            repository = "kyverno/background-controller"
            tag        = "v1.12.5"
          }
        }
      }
      cleanupController = {
        replicas = 1
        container = {
          image = {
            registry   = local.ecr_registry
            repository = "kyverno/cleanup-controller"
            tag        = "v1.12.5"
          }
        }
      }
      reportsController = {
        replicas = 1
        container = {
          image = {
            registry   = local.ecr_registry
            repository = "kyverno/reports-controller"
            tag        = "v1.12.5"
          }
        }
      }
      cleanupJobs = {
        admissionReports        = { enabled = false }
        clusterAdmissionReports = { enabled = false }
        updateRequests          = { enabled = false }
        ephemeralReports        = { enabled = false }
        clusterEphemeralReports = { enabled = false }
      }
      resources = {
        limits   = { cpu = "1000m", memory = "512Mi" }
        requests = { cpu = "200m", memory = "256Mi" }
      }
    })
  ]
}

# -----------------------------------------------------------------------------
# 3. Argo Workflows
# -----------------------------------------------------------------------------

resource "helm_release" "argo_workflows" {
  name             = "argo-workflows"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-workflows"
  version          = "0.41.0"
  namespace        = "argo"
  create_namespace = true

  timeout = 900
  wait    = false

  values = [
    yamlencode({
      installCRDs = true
      images = {
        registry = local.ecr_registry
        tag      = "v3.5.5"
      }
      server = {
        enabled     = true
        replicas    = 1
        serviceType = "ClusterIP"
        image = {
          repository = "argoworkflows/argocli"
        }
      }
      controller = {
        replicas = 1
        image = {
          repository = "argoworkflows/workflow-controller"
        }
      }
      # executor mặc định chart dùng argoproj/argoexec
      # không cần override vì wait=false
      # executor chỉ chạy khi có workflow submitted, không cần cho CRD
    })
  ]
}

# -----------------------------------------------------------------------------
# 4. Argo Rollouts
# -----------------------------------------------------------------------------

resource "helm_release" "argo_rollouts" {
  name             = "argo-rollouts"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-rollouts"
  version          = "2.35.0"
  namespace        = "argo-rollouts"
  create_namespace = true

  timeout = 900
  wait    = false

  values = [
    yamlencode({
      installCRDs = true
      controller = {
        replicas = 1
        image = {
          repository = "${local.ecr_registry}/argorollouts/argo-rollouts"
          tag        = "v1.6.6"
        }
        resources = {
          limits   = { cpu = "500m", memory = "512Mi" }
          requests = { cpu = "100m", memory = "128Mi" }
        }
      }
      dashboard = {
        enabled = false
      }
    })
  ]
}

# -----------------------------------------------------------------------------
# 5. Karpenter Controller (v1.0.6)
# -----------------------------------------------------------------------------

resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = "1.0.6"
  namespace        = "karpenter"
  create_namespace = true

  timeout = 900
  wait    = false

  set {
    name  = "controller.image.repository"
    value = "${local.ecr_registry}/karpenter/controller"
  }
  set {
    name  = "controller.image.tag"
    value = "1.0.6"
  }
  set {
    name  = "controller.image.digest"
    value = ""
  }

  values = [
    yamlencode({
      serviceAccount = {
        create = true
        name   = "karpenter"
        annotations = {
          "eks.amazonaws.com/role-arn" = "arn:aws:iam::474013238625:role/tf3-cdo1-sandbox-karpenter-controller-role"
        }
      }
      settings = {
        clusterName = local.cluster_name
        aws = {
          isolatedVPC = true
        }
      }
      controller = {
        resources = {
          limits   = { cpu = "500m", memory = "512Mi" }
          requests = { cpu = "200m", memory = "256Mi" }
        }
      }
    })
  ]
}

