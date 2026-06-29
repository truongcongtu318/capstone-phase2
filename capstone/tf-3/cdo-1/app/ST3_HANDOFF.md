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
| `DYNAMODB_TABLE_NAME` | `tf-3-aiops-idempotency-lock` | ConfigMap |
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
| `DYNAMODB_TABLE_NAME` | `tf-3-aiops-idempotency-lock` | ConfigMap |
| `AI_ENGINE_URL` | `http://ai-engine.self-heal-system.svc.cluster.local:8080` | ConfigMap |
| `DRY_RUN` | `false` | ConfigMap |
| `ARGOCD_SERVER_URL` | URL ArgoCD server trong cluster (vd: `http://argocd-server.argocd.svc.cluster.local`) | ConfigMap |
| `ARGOCD_AUTH_TOKEN` | Bearer token của ArgoCD service account | Secret (ESO) |
| `CODECOMMIT_REPO_URL` | URL CodeCommit repo GitOps | ConfigMap |
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

## 6. Quy trình test trên production (EKS sandbox)

### Bước 1: Verify images đã có trên ECR
```bash
aws ecr list-images --repository-name tf-3-webhook-receiver --region us-east-1
aws ecr list-images --repository-name tf-3-self-heal-worker --region us-east-1
aws ecr list-images --repository-name tf-3-ai-engine-demo --region us-east-1
```

### Bước 2: ST3 deploy qua ArgoCD
ST3 cập nhật Kustomize overlay với image tag mới nhất → ArgoCD sync → pods lên.

### Bước 3: Verify pods healthy
```bash
kubectl get pods -n self-heal-system
# Expected: webhook-receiver, sqs-worker, ai-engine tất cả Running
kubectl logs -n self-heal-system -l app=sqs-worker --tail=20
```

### Bước 4: Test end-to-end

Lấy Webhook URL từ Ingress của ST3:
```bash
WEBHOOK_URL=$(kubectl get ingress -n self-heal-system -o jsonpath='{.items[0].spec.rules[0].host}')
```

Gửi alert tenant-payment (OOMKilled):
```bash
curl -s -X POST "https://$WEBHOOK_URL/alerts" \
  -H "Content-Type: application/json" \
  -H "X-Tenant-Id: d3b07384-d113-495f-9f58-20d18d357d75" \
  -d '{
    "alerts": [{
      "status": "firing",
      "labels": {
        "alertname": "PodOOMKilled",
        "namespace": "tenant-payment",
        "service": "order-service",
        "severity": "critical"
      },
      "annotations": {"summary": "OOM Kill detected"}
    }]
  }'
# Expected: {"status":"accepted"}
```

### Bước 5: Verify Prometheus metrics
```bash
# Port-forward tới worker metrics
kubectl port-forward -n self-heal-system svc/sqs-worker 9090:9090 &
curl -s http://localhost:9090/metrics | grep worker_messages_processed
```

### Bước 6: Verify audit log lên Firehose/S3
```bash
# Chờ ~5 phút cho Firehose buffer flush
aws s3 ls s3://tf-3-aiops-audit-trail/ --recursive | sort | tail -5
```

---

## 7. Test E2E thật trên EKS với DRY_RUN=false

> Mục tiêu: xem worker thực sự patch K8s deployment, ghi GitOps, emit audit log, và expose metrics — không phải dry-run log.

### 7.1 Tiền đề ST3 cần tạo

**Namespace + test Deployment (khớp với alert sẽ gửi):**
```yaml
# Tạo namespace (nếu chưa có)
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-payment
---
# Deployment tên order-service — khớp với trường "service" trong alert
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-service
  namespace: tenant-payment
spec:
  replicas: 1
  selector:
    matchLabels: { app: order-service }
  template:
    metadata:
      labels: { app: order-service }
    spec:
      containers:
        - name: order-service
          image: nginx:alpine          # placeholder, nội dung không quan trọng
          resources:
            requests:
              memory: 128Mi
              cpu: 100m
            limits:
              memory: 256Mi            # worker sẽ patch lên 512Mi
              cpu: 500m
```

**ArgoCD Application (để worker suspend/resume auto-sync):**
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tenant-payment-app            # PHẢI khớp pattern {namespace}-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: <CODECOMMIT_REPO_URL>
    targetRevision: main
    path: gitops/tenant-payment/order-service  # xem §7.2
  destination:
    server: https://kubernetes.default.svc
    namespace: tenant-payment
  syncPolicy:
    automated: { prune: false, selfHeal: false }
```

**File values.yaml trong CodeCommit** (worker dùng để commit config mới sau khi patch):
```
# Tạo file tại đường dẫn: gitops/tenant-payment/order-service/values.yaml
memory_limit_mb: 256
memory_request_mb: 128
cpu_limit: "500m"
replicas: 1
```

**K8s RBAC cho self-heal-executor trong namespace tenant-payment:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: self-heal-patcher
  namespace: tenant-payment
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: self-heal-patcher-binding
  namespace: tenant-payment
subjects:
  - kind: ServiceAccount
    name: self-heal-executor
    namespace: self-heal-system
roleRef:
  kind: Role
  apiGroup: rbac.authorization.k8s.io
  name: self-heal-patcher
```

**ArgoCD token cho worker (ESO hoặc manual):**
```bash
# Lấy token từ ArgoCD (cần ArgoCD admin rights)
argocd account generate-token --account admin
# → đặt vào Secret, inject qua env ARGOCD_AUTH_TOKEN
```

**Env vars bổ sung trên sqs-worker Deployment:**
```yaml
- name: ARGOCD_SERVER_URL
  value: http://argocd-server.argocd.svc.cluster.local
- name: ARGOCD_AUTH_TOKEN
  valueFrom:
    secretKeyRef: { name: argocd-token, key: token }
- name: CODECOMMIT_REPO_URL
  value: <CodeCommit HTTPS clone URL>
- name: CODECOMMIT_BRANCH
  value: main
- name: DRY_RUN
  value: "false"
```

---

### 7.2 Gửi alert và theo dõi kết quả

**Test Fast Lane (OOMKilled → tăng memory limit):**
```bash
WEBHOOK_URL=$(kubectl get ingress -n self-heal-system -o jsonpath='{.items[0].spec.rules[0].host}')

curl -s -X POST "https://$WEBHOOK_URL/alerts" \
  -H "Content-Type: application/json" \
  -H "X-Tenant-Id: d3b07384-d113-495f-9f58-20d18d357d75" \
  -d '{
    "alerts": [{
      "status": "firing",
      "labels": {
        "alertname": "PodOOMKilled",
        "namespace": "tenant-payment",
        "service": "order-service",
        "severity": "critical"
      },
      "annotations": {"summary": "OOM Kill detected on order-service"}
    }]
  }'
# Expected: {"status":"accepted","idempotency_key":"<sha256>"}
```

---

### 7.3 Kiểm tra K8s deployment đã được patch

```bash
# Memory limit phải tăng từ 256Mi → 512Mi (giá trị AI demo trả về)
kubectl get deployment order-service -n tenant-payment \
  -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'
# Expected: 512Mi (hoặc giá trị AI demo quyết định)

# Xem thêm annotation ArgoCD đã suspend/resume chưa
kubectl get application tenant-payment-app -n argocd -o jsonpath='{.spec.syncPolicy}'
```

---

### 7.4 Kiểm tra GitOps (CodeCommit đã update chưa)

```bash
# Clone repo CodeCommit ra xem
git clone <CODECOMMIT_REPO_URL> /tmp/gitops-verify
cat /tmp/gitops-verify/gitops/tenant-payment/order-service/values.yaml
# Expected: memory_limit_mb: 512  ← worker đã commit giá trị mới
git -C /tmp/gitops-verify log --oneline -3
# Expected: commit message kiểu "chore(self-heal): [<corr_id>] fast-lane PATCH_MEMORY_LIMIT on tenant-payment/order-service"
```

---

### 7.5 Kiểm tra audit log trên S3

```bash
# Firehose buffer flush mất ~2-5 phút
aws s3 ls s3://tf-3-aiops-audit-trail/tenant-payment/ --recursive | sort | tail -5
aws s3 cp s3://tf-3-aiops-audit-trail/tenant-payment/<latest-file> - | head -20
# Expected: INCIDENT_START, DETECT, DECIDE, EXECUTE_START, EXECUTE_DONE, VERIFY, DONE
```

---

### 7.6 Kiểm tra Prometheus metrics

```bash
kubectl port-forward -n self-heal-system svc/sqs-worker 9090:9090 &
sleep 2

# Message đã xử lý thành công
curl -s http://localhost:9090/metrics | grep worker_messages_processed
# Expected: worker_messages_processed_total{status="COMPLETED"} 1

# Execution counter
curl -s http://localhost:9090/metrics | grep worker_executions_total
# Expected: worker_executions_total{action="PATCH_MEMORY_LIMIT",lane="fast",status="COMPLETED"} 1

# AI call latency
curl -s http://localhost:9090/metrics | grep worker_ai_call_duration
```

---

### 7.7 Kịch bản Slow Lane (deferred)

> AI demo hiện cứng trả `pattern_type: "urgent"` → Fast Lane luôn được chọn. Để test Slow Lane, tạm thời chỉnh AI demo trả `"deferred"` trong `/v1/decide`. Khi đó worker sẽ commit thẳng lên CodeCommit mà không patch K8s trực tiếp → ArgoCD tự sync sau 2–5 phút.

---

## 8. Hành vi khi dùng AI Engine Demo

AI demo đã được cập nhật để echo namespace từ request payload (giống AI Engine thật). Pipeline chạy đến **COMPLETED** với `DRY_RUN=true`.

**Happy path với DRY_RUN=true:**
```
INCIDENT_START → DETECT → DECIDE → EXECUTE_START (DRY_RUN skip K8s) → EXECUTE_DONE → VERIFY → DONE
worker_messages_processed_total{status="DRY_RUN"} tăng
```

**Giới hạn còn lại:**

| Hành vi | Lý do |
|---|---|
| AI luôn trả `anomaly_detected=true` | Demo skeleton cứng kết quả |
| AI luôn trả `next_action=DONE` | Demo không có verify logic thật |
| K8s patch và Git commit không thật | `DRY_RUN=true` — xem log `[DRY_RUN]` |
| Không test được ROLLBACK/ESCALATE từ verify | Cần AI Engine thật hoặc inject thủ công |

**Khi AI Engine thật deploy:** chỉ đổi image tag trong Kustomize overlay — không cần thay đổi Service, env vars, hay bất kỳ config nào khác.

---

## 8. Liên hệ ST2

- Lead: Tan (PM + ST2 Lead)
- GitHub branch naming: `app/<component>-<desc>`
- ECR repos được tạo bởi ST1 Terraform (liên hệ ST1 nếu repo chưa tồn tại)
