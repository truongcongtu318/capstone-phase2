# ST2 → ST3 Handoff — Deployment Specification

> Tài liệu này cung cấp mọi thông số ST3 cần để viết Kustomize overlays, Prometheus scrape config, và test trên EKS sandbox.

---

## 1. Images (ECR)

Sau khi CI pipeline chạy thành công trên `main`, 3 image được build và push lên ECR:

| Service | ECR Repository | Port |
|---|---|---|
| Webhook Receiver | `474013238625.dkr.ecr.us-east-1.amazonaws.com/tf-3-webhook-receiver` | `8443` |
| SQS Worker | `474013238625.dkr.ecr.us-east-1.amazonaws.com/tf-3-self-heal-worker` | metrics: `9090` |
| AI Engine Demo | `474013238625.dkr.ecr.us-east-1.amazonaws.com/tf-3-ai-engine-demo` | `8080` |

**Image tag format:** `sha-<git-sha>` (ví dụ: `sha-a1b2c3d4e5f6...`)

**Namespace:** `self-heal-system`

---

## 2. Webhook Receiver

### Container spec
```yaml
image: 474013238625.dkr.ecr.us-east-1.amazonaws.com/tf-3-webhook-receiver:sha-<TAG>
ports:
  - containerPort: 8443
    name: https
livenessProbe:
  httpGet:
    path: /health
    port: 8443
  initialDelaySeconds: 10
  periodSeconds: 15
readinessProbe:
  httpGet:
    path: /health
    port: 8443
  initialDelaySeconds: 5
  periodSeconds: 10
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

### Environment variables (từ ConfigMap + Secret)

| Var | Giá trị | Source |
|---|---|---|
| `AWS_DEFAULT_REGION` | `us-east-1` | ConfigMap |
| `SQS_QUEUE_URL` | `https://sqs.us-east-1.amazonaws.com/474013238625/tf3-cdo1-sandbox-self-heal-queue` | ConfigMap |
| `DYNAMODB_TABLE_NAME` | `tf-3-aiops-app-idempotency-lock` | ConfigMap |
| `DRY_RUN` | `false` | ConfigMap |

**Không set** `DYNAMODB_ENDPOINT_URL`, `SQS_ENDPOINT_URL` — boto3 tự dùng IRSA.

### ServiceAccount + IRSA
```yaml
serviceAccountName: webhook-receiver
# Annotation trên ServiceAccount:
# eks.amazonaws.com/role-arn: arn:aws:iam::474013238625:role/tf3-cdo1-sandbox-irsa-webhook-receiver
```

### Prometheus scrape annotations
```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8443"
  prometheus.io/path: "/metrics"
```

---

## 3. SQS Worker

### Container spec
```yaml
image: 474013238625.dkr.ecr.us-east-1.amazonaws.com/tf-3-self-heal-worker:sha-<TAG>
ports:
  - containerPort: 9090
    name: metrics
# Không expose HTTP port — worker là SQS daemon (không có HTTP server ngoài /metrics)
livenessProbe:
  httpGet:
    path: /metrics
    port: 9090
  initialDelaySeconds: 15
  periodSeconds: 30
resources:
  requests:
    cpu: 200m
    memory: 256Mi
  limits:
    cpu: 1000m
    memory: 1Gi
```

### Environment variables

| Var | Giá trị | Source |
|---|---|---|
| `AWS_DEFAULT_REGION` | `us-east-1` | ConfigMap |
| `SQS_QUEUE_URL` | `https://sqs.us-east-1.amazonaws.com/474013238625/tf3-cdo1-sandbox-self-heal-queue` | ConfigMap |
| `SNS_TOPIC_ARN` | `arn:aws:sns:us-east-1:474013238625:tf3-cdo1-sandbox-alerts-escalation` | ConfigMap |
| `FIREHOSE_STREAM_NAME` | `tf3-cdo1-sandbox-audit-stream` | ConfigMap |
| `DYNAMODB_TABLE_NAME` | `tf-3-aiops-app-idempotency-lock` | ConfigMap |
| `AI_ENGINE_URL` | `http://ai-engine.self-heal-system.svc.cluster.local:8080` | ConfigMap |
| `DRY_RUN` | `false` | ConfigMap |
| `ARGOCD_SERVER_URL` | URL ArgoCD server trong cluster (vd: `http://argocd-server.argocd.svc.cluster.local`) | ConfigMap |
| `ARGOCD_AUTH_TOKEN` | Bearer token của ArgoCD service account | Secret (ESO) |
| `CODECOMMIT_REPO_URL` | `https://git-codecommit.us-east-1.amazonaws.com/v1/repos/tf3-cdo1-sandbox-gitops` | ConfigMap |
| `CODECOMMIT_BRANCH` | `main` | ConfigMap |

**Không set** `*_ENDPOINT_URL` — boto3 tự dùng IRSA.

> **Lưu ý ArgoCD app naming:** worker tự suy ra tên ArgoCD Application theo pattern `{namespace}-app`. Ví dụ: namespace `tenant-payment` → ArgoCD app `tenant-payment-app`. ST3 cần đặt tên Application đúng convention này.

### ServiceAccount + IRSA
```yaml
serviceAccountName: self-heal-executor
# Annotation trên ServiceAccount:
# eks.amazonaws.com/role-arn: arn:aws:iam::474013238625:role/tf3-cdo1-sandbox-irsa-audit-writer
```

> **Tại sao 2 ServiceAccount riêng (webhook-receiver và self-heal-executor)?**
> Do khác nhau về quyền AWS:
> - `webhook-receiver`: DynamoDB PutItem (lock) + SQS SendMessage
> - `self-heal-executor`: SQS Receive/Delete + DynamoDB PutItem (CB) + Firehose PutRecord + SNS Publish + K8s API patch deployment
>
> Dùng chung 1 SA sẽ vi phạm least-privilege và Brain/Hands separation. ST1 đã tạo đúng 2 IRSA role riêng.

### Prometheus scrape annotations
```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "9090"
  prometheus.io/path: "/metrics"
```

---

## 4. AI Engine Demo (Tạm dùng thay AI Engine thật)

> AI Engine thật chưa có API chính thức. Tạm dùng demo skeleton — trả response hợp lệ theo contract nhưng cứng kết quả.

### Container spec
```yaml
image: 474013238625.dkr.ecr.us-east-1.amazonaws.com/tf-3-ai-engine-demo:sha-<TAG>
ports:
  - containerPort: 8080
    name: http
livenessProbe:
  httpGet:
    path: /health
    port: 8080
  initialDelaySeconds: 10
  periodSeconds: 15
readinessProbe:
  httpGet:
    path: /ready
    port: 8080
  initialDelaySeconds: 5
  periodSeconds: 10
resources:
  requests:
    cpu: 500m
    memory: 1Gi
  limits:
    cpu: 1000m
    memory: 2Gi
```

### Service (ClusterIP — internal only)
```yaml
apiVersion: v1
kind: Service
metadata:
  name: ai-engine
  namespace: self-heal-system
spec:
  selector:
    app: ai-engine
  ports:
    - port: 8080
      targetPort: 8080
  type: ClusterIP
```

**URL mà worker gọi:** `http://ai-engine.self-heal-system.svc.cluster.local:8080`

> Khi AI Engine thật sẵn sàng: chỉ đổi image tag và image repo — không cần thay đổi Service hay env vars.

---

## 5. Metrics ST3 cần monitor (Prometheus)

### Webhook Receiver
| Metric | Type | Ý nghĩa |
|---|---|---|
| `http_request_duration_seconds{handler="/alerts"}` | Histogram | Latency nhận alert |
| `webhook_alerts_queued_total{tenant_id}` | Counter | Alert được push SQS |
| `webhook_security_violations_total` | Counter | Số lần reject 403 |
| `webhook_duplicate_alerts_total{tenant_id}` | Counter | Số lần reject 409 (duplicate) |

### SQS Worker
| Metric | Type | Ý nghĩa |
|---|---|---|
| `worker_messages_processed_total{status}` | Counter | Tổng message: COMPLETED/FAILED/DRY_RUN |
| `worker_ai_call_duration_seconds{endpoint}` | Histogram | AI Engine latency per endpoint |
| `worker_ai_errors_total{endpoint,status_code}` | Counter | Lỗi AI Engine |
| `worker_executions_total{action,lane,status}` | Counter | K8s patch executions |
| `worker_circuit_breaker_open_total{tenant_id}` | Counter | CB flip to OPEN |
| `worker_circuit_breaker_skips_total{tenant_id}` | Counter | Message bị skip do CB OPEN |
| `worker_escalations_total{reason}` | Counter | Escalate to SRE |
| `worker_rollbacks_total{status}` | Counter | Rollback attempts |

---

## 6. Deploy services lên EKS — ConfigMap + Secret YAML

Apply các YAML này **trước** khi deploy pods. Không set `*_ENDPOINT_URL` — boto3 tự dùng IRSA.

### webhook-receiver ConfigMap
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: webhook-receiver-config
  namespace: self-heal-system
data:
  AWS_DEFAULT_REGION: "us-east-1"
  DYNAMODB_TABLE_NAME: "tf-3-aiops-app-idempotency-lock"
  SQS_QUEUE_URL: "https://sqs.us-east-1.amazonaws.com/474013238625/tf3-cdo1-sandbox-self-heal-queue"
```

### sqs-worker ConfigMap
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: sqs-worker-config
  namespace: self-heal-system
data:
  AWS_DEFAULT_REGION: "us-east-1"
  SQS_QUEUE_URL: "https://sqs.us-east-1.amazonaws.com/474013238625/tf3-cdo1-sandbox-self-heal-queue"
  SNS_TOPIC_ARN: "arn:aws:sns:us-east-1:474013238625:tf3-cdo1-sandbox-alerts-escalation"
  FIREHOSE_STREAM_NAME: "tf3-cdo1-sandbox-audit-stream"
  DYNAMODB_TABLE_NAME: "tf-3-aiops-app-idempotency-lock"
  AI_ENGINE_URL: "http://ai-engine.self-heal-system.svc.cluster.local:8080"
  ARGOCD_SERVER_URL: "http://argocd-server.argocd.svc.cluster.local"
  CODECOMMIT_REPO_URL: "https://git-codecommit.us-east-1.amazonaws.com/v1/repos/tf3-cdo1-sandbox-gitops"
  CODECOMMIT_BRANCH: "main"
  DRY_RUN: "false"
```

### ArgoCD token Secret
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: argocd-token
  namespace: self-heal-system
type: Opaque
stringData:
  token: "<output của: argocd account generate-token --account admin>"
```

### Cách inject vào container

**webhook-receiver Deployment:**
```yaml
envFrom:
  - configMapRef:
      name: webhook-receiver-config
```

**sqs-worker Deployment:**
```yaml
envFrom:
  - configMapRef:
      name: sqs-worker-config
env:
  - name: ARGOCD_AUTH_TOKEN
    valueFrom:
      secretKeyRef:
        name: argocd-token
        key: token
```

### Verify pods healthy sau deploy
```bash
aws ecr list-images --repository-name tf-3-webhook-receiver --region us-east-1
aws ecr list-images --repository-name tf-3-self-heal-worker --region us-east-1
aws ecr list-images --repository-name tf-3-ai-engine-demo --region us-east-1

kubectl get pods -n self-heal-system
# Expected: webhook-receiver, sqs-worker, ai-engine đều Running

kubectl logs -n self-heal-system -l app=sqs-worker --tail=10
# Expected: "Starting metrics server on :9090" + "Starting SQS polling loop"
```

---

## 7. Test E2E — 10 Scenarios với Real Alertmanager

### 7.1 Tổng quan infrastructure cần tạo

3 patterns × 2 tenants = **6 test Deployments** + 2 namespaces + 2 ArgoCD Applications + RBAC:

| Deployment | Namespace | Pattern | alertname sẽ fire |
|---|---|---|---|
| `order-service` | tenant-payment | OOMKilled → PATCH_MEMORY_LIMIT | `PodOOMKilled` |
| `checkout-api` | tenant-checkout | OOMKilled → PATCH_MEMORY_LIMIT | `PodOOMKilled` |
| `order-api` | tenant-payment | Stuck → RESTART_DEPLOYMENT | `ServiceStuck` |
| `checkout-frontend` | tenant-checkout | Stuck → RESTART_DEPLOYMENT | `ServiceStuck` |
| `payment-worker` | tenant-payment | Backlog → SCALE_REPLICAS | `SQSQueueBacklog` |
| `checkout-worker` | tenant-checkout | Backlog → SCALE_REPLICAS | `SQSQueueBacklog` |

---

### 7.2 Namespaces + RBAC

```yaml
# namespaces.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-payment
---
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-checkout
```

RBAC — áp dụng cho **cả 2 namespaces** (copy YAML, đổi `namespace:` field):
```yaml
# role-self-heal-patcher.yaml (tạo cho tenant-payment VÀ tenant-checkout)
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: self-heal-patcher
  namespace: tenant-payment    # đổi thành tenant-checkout cho bản thứ 2
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: self-heal-patcher-binding
  namespace: tenant-payment    # đổi thành tenant-checkout cho bản thứ 2
subjects:
  - kind: ServiceAccount
    name: self-heal-executor
    namespace: self-heal-system
roleRef:
  kind: Role
  apiGroup: rbac.authorization.k8s.io
  name: self-heal-patcher
```

---

### 7.3 Helm charts trong CodeCommit (bắt buộc để tránh ArgoCD drift)

> **Tại sao cần Helm chart thay vì raw YAML?**
> Fast Lane sau khi patch K8s sẽ commit `values.yaml` mới lên CodeCommit rồi resume ArgoCD.
> ArgoCD render lại Helm template → K8s state = Git state = không drift.
> Nếu dùng raw YAML với `memory: 256Mi` hardcode, ArgoCD sẽ revert về 256Mi sau khi resume.

**Cấu trúc thư mục CodeCommit (6 Helm charts):**
```
gitops/
├── tenant-payment/
│   ├── kustomization.yaml          # aggregates 3 Helm charts
│   ├── order-service/
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   └── templates/deployment.yaml
│   ├── order-api/
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   └── templates/deployment.yaml
│   └── payment-worker/
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/deployment.yaml
└── tenant-checkout/
    ├── kustomization.yaml
    ├── checkout-api/
    ├── checkout-frontend/
    └── checkout-worker/
```

**Chart.yaml** (dùng mẫu này, đổi `name` theo service):
```yaml
apiVersion: v2
name: order-service
description: Self-heal E2E test service
type: application
version: 0.1.0
```

**values.yaml** — dùng đúng format K8s (worker ghi vào `resources.limits.memory` và `replicaCount`):
```yaml
# gitops/tenant-payment/order-service/values.yaml
resources:
  limits:
    memory: "256Mi"
    cpu: "500m"
  requests:
    memory: "128Mi"
    cpu: "100m"
replicaCount: 1
serviceName: order-service
containerName: main
namespace: tenant-payment
```

> `memory_limit_mb: 256` là format sai — worker lưu `resources.limits.memory: "256Mi"` (K8s format). Phải dùng đúng cấu trúc trên.

**templates/deployment.yaml** (dùng chung mẫu, giá trị từ Values):
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Values.serviceName }}
  namespace: {{ .Values.namespace }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Values.serviceName }}
  template:
    metadata:
      labels:
        app: {{ .Values.serviceName }}
    spec:
      containers:
        - name: {{ .Values.containerName }}
          image: 474013238625.dkr.ecr.us-east-1.amazonaws.com/busybox:1.36
          command: ["sh", "-c", "while true; do sleep 3600; done"]
          resources:
            requests:
              memory: {{ .Values.resources.requests.memory }}
              cpu: {{ .Values.resources.requests.cpu }}
            limits:
              memory: {{ .Values.resources.limits.memory }}
              cpu: {{ .Values.resources.limits.cpu }}
```

**kustomization.yaml** (mỗi namespace folder có 1 file này):
```yaml
# gitops/tenant-payment/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
helmCharts:
  - name: order-service
    releaseName: order-service
    version: "0.1.0"
    localPath: ./order-service
    valuesFile: ./order-service/values.yaml
    namespace: tenant-payment
  - name: order-api
    releaseName: order-api
    version: "0.1.0"
    localPath: ./order-api
    valuesFile: ./order-api/values.yaml
    namespace: tenant-payment
  - name: payment-worker
    releaseName: payment-worker
    version: "0.1.0"
    localPath: ./payment-worker
    valuesFile: ./payment-worker/values.yaml
    namespace: tenant-payment
```

---

### 7.4 ArgoCD Applications

Worker hardcode `app = f"{namespace}-app"` → tạo đúng 2 Applications:

```yaml
# tenant-payment-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tenant-payment-app        # BẮT BUỘC đúng tên này
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://git-codecommit.us-east-1.amazonaws.com/v1/repos/tf3-cdo1-sandbox-gitops
    targetRevision: main
    path: gitops/tenant-payment   # quản lý TẤT CẢ services trong namespace
  destination:
    server: https://kubernetes.default.svc
    namespace: tenant-payment
  syncPolicy:
    automated:
      prune: false
      selfHeal: false             # BẮT BUỘC false — tránh revert annotation RESTART_DEPLOYMENT
---
# tenant-checkout-app.yaml — tương tự, đổi name + path + namespace
```

> **selfHeal: false là bắt buộc.** RESTART_DEPLOYMENT inject annotation `cdo.self-heal/restart-at` vào K8s pod spec. Nếu selfHeal=true, ArgoCD revert annotation về Git state (không có annotation) → rolling restart bị cancel.

---

### 7.5 PrometheusRule + Alertmanager config

**PrometheusRule** (apply vào namespace `monitoring`, label phải khớp với Helm release của ST1):
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: self-heal-alerts
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: self-heal.oom
      interval: 30s
      rules:
        - alert: PodOOMKilled
          expr: |
            increase(kube_pod_container_status_restarts_total[5m]) > 0
            and on(pod, namespace)
            kube_pod_container_status_last_terminated_reason{reason="OOMKilled",namespace=~"tenant-.*"} == 1
          for: 0m
          labels:
            severity: critical
          annotations:
            summary: "OOMKilled {{ $labels.pod }} in {{ $labels.namespace }}"
            service: "{{ $labels.container }}"

    - name: self-heal.stuck
      interval: 30s
      rules:
        - alert: ServiceStuck
          expr: |
            kube_deployment_status_replicas_available{namespace=~"tenant-.*"}
              / kube_deployment_spec_replicas{namespace=~"tenant-.*"} < 0.5
          for: 2m
          labels:
            severity: warning
          annotations:
            summary: "Deployment {{ $labels.deployment }} stuck in {{ $labels.namespace }}"
            service: "{{ $labels.deployment }}"

    - name: self-heal.backlog
      interval: 60s
      rules:
        - alert: SQSQueueBacklog
          expr: aws_sqs_approximate_number_of_messages_visible{queue_name=~".*self-heal.*"} > 100
          for: 1m
          labels:
            severity: warning
            namespace: tenant-payment
          annotations:
            summary: "SQS queue backlog detected"
            service: "payment-worker"
```

> `aws_sqs_approximate_number_of_messages_visible` cần CloudWatch Exporter. Nếu chưa setup, inject S06/S07 bằng curl (xem §7.7).

**Alertmanager routing** — merge vào Helm values của kube-prometheus-stack hoặc AlertmanagerConfig CRD:
```yaml
route:
  group_by: ["alertname", "namespace"]
  group_wait: 10s
  group_interval: 30s
  repeat_interval: 4h
  routes:
    - matchers:
        - namespace="tenant-payment"
      receiver: webhook-tenant-payment
    - matchers:
        - namespace="tenant-checkout"
      receiver: webhook-tenant-checkout

receivers:
  - name: webhook-tenant-payment
    webhook_configs:
      - url: "https://<WEBHOOK_INGRESS>/alerts"
        http_config:
          headers:
            X-Tenant-Id: "d3b07384-d113-495f-9f58-20d18d357d75"
        send_resolved: false
  - name: webhook-tenant-checkout
    webhook_configs:
      - url: "https://<WEBHOOK_INGRESS>/alerts"
        http_config:
          headers:
            X-Tenant-Id: "6c8b4b2b-4d45-4209-a1b4-4b532d56a31c"
        send_resolved: false
```

> **Quan trọng:** Alert phải có label `service: <deployment-name>` để worker map đúng deployment cần patch. Verify alert payload: `curl -s http://alertmanager:9093/api/v2/alerts | jq '.[].labels'`

---

### 7.6 10 Scenarios — Injection Plan

| # | Scenario | Inject method | Alert fires | Expected engine | Tính 60%? |
|---|---|---|---|---|---|
| S01 | OOMKilled — order-service | stress-ng vượt 256Mi limit | `PodOOMKilled` ns=tenant-payment | PATCH_MEMORY_LIMIT → 768Mi | ✅ |
| S02 | OOMKilled — checkout-api | stress-ng vượt 256Mi limit | `PodOOMKilled` ns=tenant-checkout | PATCH_MEMORY_LIMIT → 768Mi | ✅ |
| S03 | Duplicate lock (idempotency) | Gửi S01 alert lần 2 <180s | — (webhook) | HTTP 409 | ❌ by design |
| S04 | Stuck — order-api | Patch readiness probe `["false"]` | `ServiceStuck` sau 2m | RESTART_DEPLOYMENT | ✅ |
| S05 | Stuck — checkout-frontend | Same | `ServiceStuck` sau 2m | RESTART_DEPLOYMENT | ✅ |
| S06 | Queue backlog — payment-worker | Push >100 msgs SQS | `SQSQueueBacklog` | SCALE_REPLICAS → 3 | ✅ |
| S07 | Queue backlog — checkout-worker | Same | `SQSQueueBacklog` | SCALE_REPLICAS → 3 | ✅ |
| S08 | Blast radius blocked | Alert ns=kube-system | Worker PermissionError → escalate | không patch | ❌ by design |
| S09 | Cross-tenant violation | X-Tenant-Id sai | Webhook 403 | không push SQS | ❌ by design |
| S10 | Circuit breaker open | network-blockade.sh 3 lần | CB OPEN | SNS escalation | ❌ by design |

**S01+S02+S04+S05+S06+S07 = 6/10 = 60% auto-resolve ✅**

---

### 7.7 Cách inject từng scenario

#### S01/S02 — OOMKilled (stress-ng)

```bash
# Hạ memory limit xuống thấp trước khi inject
kubectl set resources deployment/order-service -n tenant-payment \
  --limits=memory=10Mi --requests=memory=8Mi

# Chạy stress-ng để force OOMKill (image đã mirror bởi ST1)
kubectl run oom-trigger -n tenant-payment \
  --image=474013238625.dkr.ecr.us-east-1.amazonaws.com/alexeiled/stress-ng:latest \
  --restart=Never \
  -- stress-ng --vm 1 --vm-bytes 256M --timeout 30s

# Theo dõi OOMKill event
kubectl get events -n tenant-payment --field-selector reason=OOMKilling --watch
# Sau khi OOMKilled: Alertmanager fire PodOOMKilled → webhook nhận → worker xử lý

# Cleanup
kubectl delete pod oom-trigger -n tenant-payment
# (S02 tương tự trên checkout-api trong tenant-checkout)
```

#### S03 — Duplicate idempotency test

Trong vòng 180s sau S01 đã pass, gửi cùng alert lần 2:
```bash
curl -s -o /dev/null -w "%{http_code}" \
  -X POST "https://<WEBHOOK_INGRESS>/alerts" \
  -H "X-Tenant-Id: d3b07384-d113-495f-9f58-20d18d357d75" \
  -H "Content-Type: application/json" \
  -d '{"alerts":[{"status":"firing","labels":{"alertname":"PodOOMKilled","namespace":"tenant-payment","service":"order-service","severity":"critical"},"annotations":{"summary":"OOM"}}]}'
# Expected output: 409
```

#### S04/S05 — Stuck service (broken readiness probe)

```bash
# Inject failing readiness probe
kubectl patch deployment order-api -n tenant-payment --type=json -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/readinessProbe",
   "value":{"exec":{"command":["false"]},"periodSeconds":5,"failureThreshold":1}}
]'

# Đợi ~2m → ServiceStuck alert fire → worker nhận → RESTART_DEPLOYMENT
kubectl rollout status deployment/order-api -n tenant-payment
# Sẽ stuck — worker sẽ patch rolling restart annotation

# Cleanup nếu cần reset thủ công
kubectl patch deployment order-api -n tenant-payment --type=json -p='[
  {"op":"remove","path":"/spec/template/spec/containers/0/readinessProbe"}
]'
# (S05 tương tự trên checkout-frontend trong tenant-checkout)
```

#### S06/S07 — Queue backlog (SQS push)

```bash
# Push >100 messages
for i in $(seq 1 110); do
  aws sqs send-message \
    --queue-url "https://sqs.us-east-1.amazonaws.com/474013238625/tf3-cdo1-sandbox-self-heal-queue" \
    --message-body "{\"test\":\"backlog\",\"seq\":$i}" \
    --region us-east-1
done

# Verify queue depth
aws sqs get-queue-attributes \
  --queue-url "https://sqs.us-east-1.amazonaws.com/474013238625/tf3-cdo1-sandbox-self-heal-queue" \
  --attribute-names ApproximateNumberOfMessages --region us-east-1

# Nếu CloudWatch Exporter chưa setup, inject alert thủ công:
curl -s -X POST "https://<WEBHOOK_INGRESS>/alerts" \
  -H "X-Tenant-Id: d3b07384-d113-495f-9f58-20d18d357d75" \
  -H "Content-Type: application/json" \
  -d '{"alerts":[{"status":"firing","labels":{"alertname":"SQSQueueBacklog","namespace":"tenant-payment","service":"payment-worker","severity":"warning"},"annotations":{"summary":"Queue backlog"}}]}'
```

#### S08 — Blast radius (namespace bị cấm)

```bash
curl -s -w "\nHTTP: %{http_code}" \
  -X POST "https://<WEBHOOK_INGRESS>/alerts" \
  -H "X-Tenant-Id: d3b07384-d113-495f-9f58-20d18d357d75" \
  -H "Content-Type: application/json" \
  -d '{"alerts":[{"status":"firing","labels":{"alertname":"PodOOMKilled","namespace":"kube-system","service":"coredns","severity":"critical"},"annotations":{"summary":"OOM"}}]}'
# Webhook: 202 (nhận OK)
# Worker log: PermissionError namespace 'kube-system' ngoài RBAC boundary
# Verify: worker_escalations_total{reason="EXEC_FAILED"} tăng
```

#### S09 — Cross-tenant violation

```bash
# tenant-checkout UUID gửi alert cho tenant-payment namespace
curl -s -w "\nHTTP: %{http_code}" \
  -X POST "https://<WEBHOOK_INGRESS>/alerts" \
  -H "X-Tenant-Id: 6c8b4b2b-4d45-4209-a1b4-4b532d56a31c" \
  -H "Content-Type: application/json" \
  -d '{"alerts":[{"status":"firing","labels":{"alertname":"PodOOMKilled","namespace":"tenant-payment","service":"order-service","severity":"critical"},"annotations":{"summary":"OOM"}}]}'
# Expected: HTTP 403
# Verify: webhook_security_violations_total tăng
```

#### S10 — Circuit breaker open

```bash
# Dùng network-blockade.sh (ST3 hoàn thiện TODO stub) để block AI Engine port 8080
# Gây 3 consecutive AI errors trong vòng 1h
# Hoặc thủ công: xóa tạm NetworkPolicy allow cho sqs-worker → ai-engine, gửi 3 alerts

# Verify
kubectl port-forward -n self-heal-system svc/sqs-worker 9090:9090 &
curl -s http://localhost:9090/metrics | grep worker_circuit_breaker_open_total
# Expected: worker_circuit_breaker_open_total{tenant_id="d3b07..."} 1

# Verify SNS message
aws sqs receive-message \
  --queue-url "https://sqs.us-east-1.amazonaws.com/474013238625/tf3-cdo1-sandbox-alerts-escalation" \
  --region us-east-1
```

---

### 7.8 Happy path output từng pattern

#### PATCH_MEMORY_LIMIT (S01/S02)

```
[~0s]   K8s OOMKills pod → Alertmanager fires PodOOMKilled
        Webhook: POST /alerts → HTTP 202 {"status":"accepted","idempotency_key":"..."}

[~1s]   Worker SQS receive:
        LOG: INCIDENT_START tenant=d3b07384... service=order-service correlation_id=<uuid>

[~1-2s] AI detect → decide:
        LOG: audit_emit_ok event_type=DETECT
        LOG: audit_emit_ok event_type=DECIDE  [action=PATCH_MEMORY_LIMIT memory_limit_mb=768]

[~2s]   ArgoCD suspend:
        LOG: argocd_suspend app=tenant-payment-app

[~2s]   K8s patch:
        LOG: k8s_patch_applied deployment=order-service ns=tenant-payment

[~3s]   CodeCommit commit (values.yaml: memory "256Mi" → "768Mi"):
        LOG: fast_lane_git_committed sha=abc1234 ns=tenant-payment dep=order-service

[~3s]   ArgoCD resume:
        LOG: argocd_resume app=tenant-payment-app

[~4s]   AI verify → DONE:
        LOG: audit_emit_ok event_type=VERIFY
        LOG: audit_emit_ok event_type=DONE
        LOG: DONE correlation_id=<uuid>

Verify K8s:
  kubectl get deploy order-service -n tenant-payment \
    -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'
  → 768Mi ✅

Verify GitOps:
  cat gitops/tenant-payment/order-service/values.yaml
  → resources.limits.memory: "768Mi" ✅

Verify metrics:
  worker_messages_processed_total{status="COMPLETED"} += 1
  worker_executions_total{action="PATCH_MEMORY_LIMIT",lane="fast",status="COMPLETED"} += 1
  worker_ai_call_duration_seconds (3 observations: detect/decide/verify)

Verify S3 (sau ~5 phút):
  Events: INCIDENT_START → DETECT → DECIDE → EXECUTE_START → EXECUTE_DONE → VERIFY → DONE
```

#### RESTART_DEPLOYMENT (S04/S05)

```
[~0s]   Readiness probe fail >2m → Alertmanager fires ServiceStuck
        Webhook: HTTP 202 accepted

[~1-2s] Worker: AI decide action=RESTART_DEPLOYMENT
        LOG: audit_emit_ok event_type=DECIDE

[~2s]   ArgoCD suspend: tenant-payment-app
        K8s patch (rolling restart annotation):
        LOG: k8s_patch_applied deployment=order-api ns=tenant-payment
        Note: KHÔNG commit CodeCommit — RESTART_DEPLOYMENT annotation là ephemeral,
              không có values.yaml tương đương. (by design, bug đã fix trong patch_executor.py)

[~3s]   ArgoCD resume
        AI verify → DONE

Verify K8s:
  kubectl get pods -n tenant-payment -l app=order-api
  → AGE pods rất nhỏ (vừa restart)
  kubectl get deploy order-api -n tenant-payment \
    -o jsonpath='{.spec.template.metadata.annotations}'
  → {"cdo.self-heal/restart-at":"<timestamp>"} ✅

Verify metrics:
  worker_executions_total{action="RESTART_DEPLOYMENT",lane="fast",status="COMPLETED"} += 1

Note: Không có commit mới trong CodeCommit — expected behavior ✅
```

#### SCALE_REPLICAS (S06/S07)

```
[~0s]   SQS queue depth > 100 → Alertmanager fires SQSQueueBacklog
        Webhook: HTTP 202 accepted

[~1-2s] Worker: AI decide action=SCALE_REPLICAS replicas=3
        LOG: audit_emit_ok event_type=DECIDE

[~2s]   ArgoCD suspend: tenant-payment-app
        K8s patch (spec.replicas=3):
        LOG: k8s_patch_applied deployment=payment-worker ns=tenant-payment

[~3s]   CodeCommit commit (values.yaml: replicaCount 1 → 3):
        LOG: fast_lane_git_committed sha=def5678

[~3s]   ArgoCD resume
        AI verify → DONE

Verify K8s:
  kubectl get deploy payment-worker -n tenant-payment
  → READY 3/3 ✅

Verify GitOps:
  cat gitops/tenant-payment/payment-worker/values.yaml | grep replicaCount
  → replicaCount: 3 ✅

Verify metrics:
  worker_executions_total{action="SCALE_REPLICAS",lane="fast",status="COMPLETED"} += 1
```

### 7.9 Verify tổng hợp sau demo

```bash
# Tất cả metrics
kubectl port-forward -n self-heal-system svc/sqs-worker 9090:9090 &
curl -s http://localhost:9090/metrics | grep -E 'worker_(messages|executions|escalations|circuit)'

# S3 audit trail
aws s3 ls s3://tf-3-aiops-audit-trail/ --recursive | sort

# Webhook metrics
kubectl port-forward -n self-heal-system svc/webhook-receiver 8443:8443 &
curl -sk https://localhost:8443/metrics | grep webhook_

# SNS escalation queue (S10)
aws sqs receive-message \
  --queue-url "https://sqs.us-east-1.amazonaws.com/474013238625/tf3-cdo1-sandbox-alerts-escalation" \
  --region us-east-1
```

---

## 8. Hành vi AI Engine Demo — 3 Patterns (Updated)

AI demo đã được cập nhật để route action theo `alertname`:

| alertname | action trả về | params |
|---|---|---|
| `PodOOMKilled` (default) | `PATCH_MEMORY_LIMIT` | memory_limit_mb=768, memory_request_mb=512, container=main |
| `ServiceStuck` / `DeploymentAvailableReplicasLow` | `RESTART_DEPLOYMENT` | container=main |
| `SQSQueueBacklog` / `WorkerQueueBacklog` | `SCALE_REPLICAS` | replicas=3 |

**Happy path với DRY_RUN=true:**
```
INCIDENT_START → DETECT → DECIDE → EXECUTE_START (DRY_RUN skip K8s) → EXECUTE_DONE → VERIFY → DONE
worker_messages_processed_total{status="DRY_RUN"} tăng
```

**Giới hạn còn lại:**

| Hành vi | Lý do |
|---|---|
| `anomaly_detected` luôn true | Demo skeleton |
| `next_action` luôn DONE | Demo không có verify logic |
| `pattern_type` luôn "urgent" | Fast Lane luôn được chọn |
| Không test ROLLBACK/ESCALATE | Cần AI Engine thật |

**Khi AI Engine thật deploy:** chỉ đổi image tag + image repo trong Kustomize overlay — Service, env vars, URL không đổi.

---

## 9. Liên hệ ST2

- Lead: Tan (PM + ST2 Lead)
- GitHub branch naming: `app/<component>-<desc>`
- ECR repos: CI pipeline tự tạo khi push nếu chưa tồn tại
- Bug fix patch_executor.py: RESTART_DEPLOYMENT không còn lỗi ValueError khi CC_REPO set
