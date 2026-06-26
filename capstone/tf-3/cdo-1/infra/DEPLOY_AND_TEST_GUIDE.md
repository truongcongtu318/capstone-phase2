# Hướng dẫn Deploy & Test — CDO Infra Pack #1 + AI Engine + Webhook Receiver

Tài liệu này dành cho team sau khi toàn bộ Pack #1 (INFRA-1→8) đã apply xong.
Mục tiêu: build 2 images, deploy lên cluster, chạy được luồng
Alertmanager → Receiver → AI Engine → log quyết định.

---

## 1. Điều kiện tiên quyết

### 1.1 Apply Pack #1 theo thứ tự

```bash
# Từ capstone/tf-3/cdo-1/infra/
terraform apply -target=module.bootstrap
terraform apply -target=module.networking -target=module.security
terraform apply -target=module.eks          # phải riêng — EKS vừa là resource vừa là provider
terraform apply                             # INFRA-5,6,7 + phần còn lại
```

Kiểm tra sau khi apply xong:
```bash
kubectl get nodes
kubectl get pods -n kube-system             # aws-load-balancer-controller phải Running
kubectl get pods -n observability           # kube-prometheus-stack phải Running
```

### 1.2 Bật NetworkPolicy enforcement (INFRA-8 — nhờ owner INFRA-4)

```bash
kubectl get daemonset aws-node -n kube-system \
  -o jsonpath='{.spec.template.spec.containers[0].env}' | grep -i networkpolicy
```
Nếu chưa thấy `ENABLE_NETWORK_POLICY=true` → owner INFRA-4 thêm `enableNetworkPolicy: true`
vào EKS addon `vpc-cni` rồi apply lại module EKS.

### 1.3 Điền CLUSTER_POD_CIDR vào networkpolicy.yaml

```bash
POD_CIDR=$(terraform -chdir=environments/sandbox/foundation \
  output -raw vpc_cidr 2>/dev/null || echo "10.0.0.0/16")

sed -i '' "s|<CLUSTER_POD_CIDR>|$POD_CIDR|g" \
  capstone/tf-3/cdo-1/infra/manifests/ai-engine/networkpolicy.yaml
```

---

## 2. Source code AI Engine (đã có sẵn)

Source code đã được copy từ `lab-w11/Capstone-Phase-2-CodeAI/demo/app/` vào repo:

```
manifests/ai-engine/
├── main.py           ← FastAPI dummy engine (port 8080, /health /ready /metrics /v1/*)
├── Dockerfile        ← python:3.11-slim, uvicorn
├── requirements.txt  ← fastapi==0.111.0, uvicorn==0.30.1
├── deployment.yaml   ← K8s Deployment (điền ECR URI trước khi apply)
├── service.yaml      ← ClusterIP :8080
└── networkpolicy.yaml ← 3 policy deny-all + allow
```

App là dummy engine luôn trả về anomaly detected, đủ để test luồng E2E Pack #1.
**Không dùng** `lab-w11/.../demo/terraform/` — stack ECS/VPC riêng của AI team,
không phải topology EKS đã ký trong `contracts/deployment-contract.md`.

---

## 3. Build & Push Images (làm 1 lần, cả 2 image)

Dùng **cùng 1 ECR registry**, 2 repo riêng biệt cho 2 image.

### Bước 1 — Login ECR (1 lần duy nhất)

```bash
REGION=$(aws configure get region)
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"

aws ecr get-login-password --region $REGION | \
  docker login --username AWS --password-stdin "$ECR_REGISTRY"

echo "ECR Registry: $ECR_REGISTRY"
```

### Bước 2 — Tạo ECR repos (nếu chưa có)

```bash
# AI Engine repo (AI team có thể đã tạo sẵn — kiểm tra trước)
aws ecr describe-repositories --repository-names tf-3-ai-engine 2>/dev/null || \
  aws ecr create-repository --repository-name tf-3-ai-engine --region $REGION

# Webhook Receiver repo
aws ecr describe-repositories --repository-names tf-3-webhook-receiver 2>/dev/null || \
  aws ecr create-repository --repository-name tf-3-webhook-receiver --region $REGION

AI_ENGINE_URI="$ECR_REGISTRY/tf-3-ai-engine"
RECEIVER_URI="$ECR_REGISTRY/tf-3-webhook-receiver"

echo "AI Engine  : $AI_ENGINE_URI:latest"
echo "Receiver   : $RECEIVER_URI:latest"
```

### Bước 3 — Build & push AI Engine (chỉ khi đã có Dockerfile từ AI team)

```bash
cd capstone/tf-3/cdo-1/infra/manifests/ai-engine

docker build -t tf-3-ai-engine:latest .
docker tag tf-3-ai-engine:latest "$AI_ENGINE_URI:latest"
docker push "$AI_ENGINE_URI:latest"
```

### Bước 4 — Build & push Webhook Receiver

```bash
cd capstone/tf-3/cdo-1/infra/manifests/webhook-receiver

docker build -t tf-3-webhook-receiver:latest .
docker tag tf-3-webhook-receiver:latest "$RECEIVER_URI:latest"
docker push "$RECEIVER_URI:latest"
```

### Bước 5 — Điền image URI vào manifests

```bash
# Về lại root repo
cd <repo-root>

# AI Engine
sed -i '' "s|<ECR_IMAGE_URI>|$AI_ENGINE_URI|g" \
  capstone/tf-3/cdo-1/infra/manifests/ai-engine/deployment.yaml

# Webhook Receiver
sed -i '' "s|<ECR_RECEIVER_IMAGE_URI>|$RECEIVER_URI|g" \
  capstone/tf-3/cdo-1/infra/manifests/webhook-receiver/k8s.yaml
```

---

## 4. Deploy lên EKS

```bash
# Tạo namespace
kubectl create namespace self-heal-system --dry-run=client -o yaml | kubectl apply -f -

# AI Engine (deployment + service + networkpolicy)
kubectl apply -f capstone/tf-3/cdo-1/infra/manifests/ai-engine/
kubectl rollout status deployment/ai-engine -n self-heal-system --timeout=120s

# Webhook Receiver (deployment + service + 2 networkpolicy)
kubectl apply -f capstone/tf-3/cdo-1/infra/manifests/webhook-receiver/k8s.yaml
kubectl rollout status deployment/patch-receiver -n self-heal-system --timeout=60s
```

Kiểm tra sau deploy:
```bash
kubectl get pods -n self-heal-system
# Expected:
#   ai-engine-xxxxx       2/2  Running
#   patch-receiver-xxxxx  1/1  Running

kubectl get svc -n self-heal-system
# Expected:
#   ai-engine      ClusterIP  <IP>  8080/TCP
#   patch-receiver ClusterIP  <IP>  8443/TCP

kubectl get networkpolicy -n self-heal-system
# Expected: 5 policies
#   ai-engine-default-deny
#   ai-engine-allow-ingress
#   ai-engine-allow-egress
#   patch-receiver-allow-ingress
#   patch-receiver-allow-egress
```

---

## 5. Test Cases — Từng bước kiểm chứng

### Test 1 — AI Engine health check

```bash
kubectl run health-check --rm -it --restart=Never \
  --image=curlimages/curl -n self-heal-system \
  --labels="app=cdo-self-heal-controller" \
  -- curl -s http://ai-engine.self-heal-system.svc.cluster.local:8080/health
```
**Expect:** `{"status": "healthy"}`

---

### Test 2 — NetworkPolicy ALLOW (pod có đúng label)

```bash
kubectl run allowed --rm -it --restart=Never \
  --image=curlimages/curl -n self-heal-system \
  --labels="app=cdo-self-heal-controller" \
  -- curl -s -o /dev/null -w "%{http_code}" \
  http://ai-engine.self-heal-system.svc.cluster.local:8080/health
```
**Expect:** `200`

---

### Test 3 — NetworkPolicy BLOCK (pod sai label)

```bash
kubectl run blocked --rm -it --restart=Never \
  --image=curlimages/curl -n self-heal-system \
  -- curl -s --max-time 5 \
  http://ai-engine.self-heal-system.svc.cluster.local:8080/health \
  || echo "BLOCKED (expected)"
```
**Expect:** timeout + `BLOCKED (expected)`. Nếu thấy response → VPC CNI chưa enforce NetworkPolicy.

---

### Test 4 — Gọi /v1/detect trực tiếp (contract test)

```bash
IKEY=$(uuidgen | tr '[:upper:]' '[:lower:]')

kubectl run api-test --rm -it --restart=Never \
  --image=curlimages/curl -n self-heal-system \
  --labels="app=cdo-self-heal-controller" \
  -- curl -s -X POST \
  http://ai-engine.self-heal-system.svc.cluster.local:8080/v1/detect \
  -H "Content-Type: application/json" \
  -H "X-Tenant-Id: d3b07384-d113-495f-9f58-20d18d357d75" \
  -H "Idempotency-Key: $IKEY" \
  -H "X-Dry-Run-Mode: true" \
  -d "{\"idempotency_key\":\"$IKEY\",\"dry_run_mode\":true,\"telemetry_window\":[{\"metric_name\":\"pod_restart_count\",\"value\":5,\"timestamp\":\"2026-06-26T10:00:00Z\",\"labels\":{\"namespace\":\"tenant-payment\",\"pod\":\"api-server-xyz\"}}]}"
```
> Không thêm `Authorization` header — contract đã bỏ SigV4 (Local Trust model).

**Expect:** JSON với `anomaly_detected` và `confidence`.

---

### Test 5 — Trigger alert giả → Alertmanager → Receiver → AI Engine (E2E Pack #1)

**Bước 5a:** Apply PrometheusRule test
```bash
kubectl apply -f capstone/tf-3/cdo-1/infra/manifests/webhook-receiver/test-alert-rule.yaml
```

**Bước 5b:** Xác nhận Prometheus pick up rule (~30s)
```bash
kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090 &
# Mở http://localhost:9090/rules → tìm group "self-heal-test" → status GREEN
```

**Bước 5c:** Xác nhận Alertmanager nhận alert (~1-2 phút)
```bash
kubectl port-forward -n observability svc/kube-prometheus-stack-alertmanager 9093:9093 &
# Mở http://localhost:9093 → tab Alerts → thấy TestAlwaysFiring FIRING
```

**Bước 5d:** Xem logs receiver để verify luồng đầu cuối
```bash
kubectl logs -n self-heal-system -l component=patch-receiver -f
```

**Output mong đợi (luồng thành công):**
```
Received webhook: status=firing alerts=1
[<uuid>] Processing alert: TestAlwaysFiring namespace=tenant-payment pod=test-pod-fake
[<uuid>] /v1/detect → anomaly_detected=true confidence=0.87
[<uuid>] /v1/decide → action_type=scale_up target=tenant-payment/test-pod-fake
[<uuid>] DECISION (not executed in Pack #1): action_type=scale_up ...
```

---

### Test 6 — Trigger crash alert thực tế (optional)

```bash
kubectl run crasher --image=busybox --restart=Always -n default \
  -- sh -c "sleep 2; exit 1"

# Chờ ~5 phút để PodCrashLooping rule fire
kubectl logs -n self-heal-system -l component=patch-receiver --since=10m
```

---

### Test 7 — Grafana + Prometheus hoạt động

```bash
# Grafana
kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80 &
GRAFANA_PASS=$(kubectl get secret -n observability kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d)
echo "Grafana: http://localhost:3000  admin / $GRAFANA_PASS"
```

---

## 6. Tóm tắt output Pack #1 sau apply thành công

```
AWS Account
└── VPC (private, 3 AZ)
    └── EKS Cluster
        ├── Karpenter nodes (scale-on-demand)
        ├── namespace: kube-system
        │   ├── aws-load-balancer-controller
        │   └── vpc-cni (enforce NetworkPolicy)
        ├── namespace: observability
        │   ├── Prometheus → scrape metrics + fire alerts
        │   ├── Grafana → http://localhost:3000 (port-forward)
        │   └── Alertmanager → gửi alert tới patch-receiver:8443
        └── namespace: self-heal-system
            ├── ai-engine  (ClusterIP :8080, 2 replicas)
            ├── patch-receiver (ClusterIP :8443, 1 replica)
            └── 5 NetworkPolicy (deny-all + allow theo contract)

AWS Services
├── S3:        tf-3-aiops-audit-trail
├── DynamoDB:  tf-3-aiops-idempotency-lock
├── KMS:       5 CMKs (audit/app-data/secrets/infra/observability)
├── CloudWatch: /aws/eks/<cluster>/cluster (90 ngày)
└── IAM:       GitHub Actions OIDC + plan/apply roles
```

**Có thể demo ngay:** Alert giả fire → Receiver nhận → AI Engine detect + decide → log.
**Chưa có:** Self-Heal Controller thực thi action, ArgoCD, RDS, tenant workloads.

---

## 7. Known Issues cần fix trước khi test

| Issue | Ảnh hưởng | Cần làm |
|---|---|---|
| AI Engine source chưa trong repo | Không build được image | AI team push Dockerfile vào `manifests/ai-engine/` hoặc cung cấp ECR URI |
| KMS `cdo-observability-kms` thiếu key policy cho CloudWatch Logs | `aws_cloudwatch_log_group` fail khi apply | Fix trong PR #46 (security module) |
| `sg-eks-workload` thiếu ingress 10250 từ control-plane | Kubelet có thể fail nếu không có cluster SG | Fix trong PR #46 hoặc document rõ cluster SG covers it |
| `sg-alb-internal` mở 443 cho toàn VPC CIDR | Wider trust boundary hơn design | Acceptable sandbox, TODO narrow khi có Alert Relay SG |
| ServiceAccount `ai-engine` chưa có IRSA | AI Engine không gọi được S3/Bedrock/DynamoDB | Tạo IRSA SA — INFRA-4 owner hoặc module mới |
