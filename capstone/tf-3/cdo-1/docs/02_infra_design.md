# Infrastructure Design - Task force 3 · CDO 1

<!-- Doc owner: <Nhóm CDO>
     Status: Draft (W11 T3-T4) → Final (W11 T6 Pack #1) → Updated (W12 T4 Pack #2)
     Word target: 1500-2500 từ
     Tier: Medium -->

## 1. Architecture diagram

<!-- Mermaid diagram thể hiện VPC layout, EKS cluster, subnets, data flow -->

*Caption: <giải thích flow + tại sao layout này>*

## 2. Component table

| Component | AWS Service | Reason | Cost note |
|---|---|---|---|
| Compute | | | $X |
| API entry | | | $X |
| Database | | | $X |
| Storage | | | $X |
| Event bus | | | $X |
| Observability | | | $X |

## 3. Differentiation angle deep-dive

### 3.1 Why this angle?

<!-- Tại sao chọn hướng tiếp cận này? Lý do chi tiết -->

### 3.2 Vượt trội ở đâu (số liệu)

| Axis | My number | Competing angle estimate |
|---|---|---|
| Cost / tenant / month | $X | $Y |
| P99 latency | Xms | Yms |
| Ops overhead (hr/week) | X | Y |
| Time to onboard tenant | X min | Y min |

### 3.3 Weakness chấp nhận

<!-- Honest về trade-off. Reviewer thích honesty hơn là "everything is great" -->

## 4. Multi-tenant approach
4.1. Mô hình định danh tenant

Trong hệ thống Self-Heal Platform, một tenant được hiểu là một khách hàng hoặc một team sở hữu một nhóm microservice trên Kubernetes.

Với phạm vi capstone, nhóm sẽ demo ít nhất 2 tenant để chứng minh hệ thống có thể tách quyền rõ ràng giữa các khách hàng.

Tenant ID	Namespace	Tier	Service demo
tnt-payment-demo	tenant-payment	Pro	payment-api
tnt-checkout-demo	tenant-checkout	Basic	checkout-api

Mỗi tenant có một mã định danh riêng là tenant_id.

Mọi request, alert, telemetry package, remediation action và audit log đều phải gắn tenant_id. Nhờ vậy, hệ thống luôn biết incident này thuộc tenant nào, service nào, namespace nào và policy nào cần được áp dụng.

Ví dụ một alert gửi vào Webhook Receiver:

{
  "tenant_id": "tnt-payment-demo",
  "namespace": "tenant-payment",
  "service": "payment-api",
  "alert_name": "CrashLoopBackOff",
  "severity": "critical"
}

Request gửi vào Webhook Receiver phải có header:

X-Tenant-Id: <tenant_id>

Tuy nhiên, hệ thống không tin header này một cách tuyệt đối. Trước khi xử lý alert, Webhook Receiver phải validate tenant context.

Luồng validate tenant:

Request đi vào Internal ALB
→ FastAPI middleware đọc header X-Tenant-Id
→ Lookup tenant registry từ DynamoDB hoặc Kubernetes namespace label
→ Kiểm tra tenant_id có khớp namespace/service không
→ Kiểm tra tenant có policy cho action này không
→ Nếu hợp lệ: cho request đi tiếp
→ Nếu không hợp lệ: trả 403 và ghi audit event SECURITY_VIOLATION

Ví dụ request không hợp lệ:

X-Tenant-Id = tnt-payment-demo
namespace = tenant-checkout

Request này sẽ bị chặn vì tnt-payment-demo chỉ được thao tác trong namespace tenant-payment, không được thao tác vào namespace tenant-checkout.

Response khi bị chặn:

{
  "error": "TENANT_NAMESPACE_MISMATCH",
  "message": "Tenant is not allowed to operate on the requested namespace."
}

Audit log tương ứng:

{
  "event_type": "SECURITY_VIOLATION",
  "reason": "TENANT_NAMESPACE_MISMATCH",
  "tenant_id": "tnt-payment-demo",
  "requested_namespace": "tenant-checkout",
  "decision": "DENY"
}

Hệ thống hỗ trợ 3 tier dịch vụ:

Tier	Mục đích	Ảnh hưởng
Basic	Service ít quan trọng hoặc môi trường demo/dev	Quota thấp hơn, cooldown lâu hơn
Pro	Service production thông thường	Quota trung bình, remediation tiêu chuẩn
Enterprise	Service quan trọng	Quota cao hơn, audit nghiêm hơn, policy chặt hơn

Trong demo capstone, nhóm sẽ dùng:

tnt-checkout-demo → Basic
tnt-payment-demo  → Pro
4.2. Cách tách biệt dữ liệu và quyền giữa các tenant

Nhóm chọn mô hình Bridge Isolation.

Bridge Isolation nghĩa là:

Hạ tầng dữ liệu dùng chung để tiết kiệm chi phí, nhưng dữ liệu luôn được gắn tenant_id; còn quyền thực thi trong Kubernetes và GitOps được tách bằng namespace, RBAC, ArgoCD Application và ArgoCD AppProject.

Nhóm đã cân nhắc 3 mô hình:

Mô hình	Cách hoạt động	Ưu điểm	Nhược điểm
Silo Isolation	Mỗi tenant có database, queue, bucket và compute riêng	An sau nhất	Chi phí cao, setup lâu, không phù hợp scope 2 tuần
Pool Isolation	Tất cả tenant dùng chung hạ tầng, chỉ phân biệt bằng tenant_id	Rẻ nhất, build nhanh	Rủi ro cao nếu code filter sai tenant
Bridge Isolation	Data layer dùng chung nhưng partition bằng tenant_id; execution tách bằng namespace/RBAC/GitOps	Cân bằng giữa chi phí và an toàn	Cần validate tenant và policy kỹ

Nhóm không chọn Silo vì nếu mỗi tenant có DynamoDB table riêng, S3 bucket riêng, SQS queue riêng thì chi phí và độ phức tạp sẽ tăng nhanh. Cách này phù hợp production lớn nhưng quá nặng cho capstone 2 tuần.

Nhóm cũng không chọn Pool hoàn toàn vì nếu chỉ dựa vào tenant_id trong code thì một lỗi filter có thể làm tenant này đọc nhầm dữ liệu hoặc sửa nhầm workload của tenant khác.

Vì vậy, nhóm chọn Bridge Isolation để cân bằng giữa cost và safety.

4.2.1. Data isolation

Các service dữ liệu dùng chung gồm DynamoDB, SQS và S3. Tuy nhiên, mọi record, message và object đều phải có thông tin tenant.

DynamoDB

DynamoDB dùng để lưu incident state, idempotency lock, cooldown và tenant registry.

Incident state key:

PK = tenant_id#incident_id

Ví dụ:

tnt-payment-demo#inc-001
tnt-checkout-demo#inc-002

Idempotency lock key:

lock_key = tenant_id#namespace#service#alert_name#action_type

Ví dụ:

tnt-payment-demo#tenant-payment#payment-api#CrashLoopBackOff#RESTART_DEPLOYMENT

Ý nghĩa:

Cùng một alert trong cùng tenant sẽ không tạo nhiều remediation trùng lặp.
Tenant này không ghi đè lock của tenant khác.
Có thể áp dụng cooldown theo từng tenant, từng service và từng action.
S3 audit log

S3 audit bucket dùng chung nhưng tách bằng prefix theo tenant.

Cấu trúc path:

s3://selfheal-audit/<tenant_id>/<yyyy>/<mm>/<dd>/<incident_id>.json

Ví dụ:

s3://selfheal-audit/tnt-payment-demo/2026/06/23/inc-001.json
s3://selfheal-audit/tnt-checkout-demo/2026/06/23/inc-002.json

Cách này giúp:

Audit log của từng tenant được tách rõ ràng.
Athena có thể query theo tenant dễ hơn.
Có thể mở rộng lifecycle policy hoặc retention policy theo tenant/tier trong tương lai.
SQS

SQS Standard queue dùng chung để giảm chi phí và đơn giản hóa vận hành.

Tuy nhiên, tenant metadata phải được đặt trong MessageAttributes, không chỉ nằm trong message body.

MessageAttributes:

tenant_id
incident_id
severity
action_type

Ví dụ:

{
  "tenant_id": "tnt-payment-demo",
  "incident_id": "inc-001",
  "severity": "critical",
  "action_type": "RESTART_DEPLOYMENT"
}

Message body chứa full payload:

{
  "incident_id": "inc-001",
  "tenant_id": "tnt-payment-demo",
  "namespace": "tenant-payment",
  "service": "payment-api",
  "alert": {
    "name": "CrashLoopBackOff",
    "severity": "critical"
  },
  "telemetry": {},
  "ai_action_plan": {}
}

Lý do đặt tenant_id trong MessageAttributes:

Worker có thể kiểm tra tenant nhanh mà chưa cần deserialize toàn bộ body.
Sau này có thể route message theo tenant hoặc severity.
Khi message vào DLQ, việc debug theo tenant dễ hơn.

4.2.2. Execution isolation

Hệ thống có 2 execution path, nên cách tách quyền cũng được thiết kế riêng cho từng path.

Path 1: Direct Patch path

Direct Patch path dùng cho lỗi khẩn cấp như OOMKilled, CrashLoopBackOff hoặc service stuck. Mục tiêu là xử lý nhanh để giảm MTTR.

Luồng:

Webhook Receiver
→ Policy Guardrail
→ Direct Patch Engine
→ Kubernetes API
→ Verify
→ Audit

Direct Patch Engine chạy in-process cùng Pod với Webhook Receiver và dùng load_incluster_config() để gọi Kubernetes API trong cluster.

ServiceAccount:

Name: selfheal-executor
Namespace: self-heal-system

ServiceAccount này không được cấp quyền cluster-wide cho remediation. Thay vào đó, nó được bind bằng RoleBinding theo từng namespace tenant.

Ví dụ:

RoleBinding trong namespace tenant-payment:
selfheal-executor → Role patch-deployments

RoleBinding trong namespace tenant-checkout:
selfheal-executor → Role patch-deployments

Quyền cho phép:

Allowed:
- get/list/watch pods
- get/list/watch events
- get/list/watch deployments
- patch deployment trong namespace được phép
- restart workload trong namespace được phép

Quyền bị chặn:

Blocked:
- access kube-system
- delete namespace
- patch ClusterRole / ClusterRoleBinding
- modify namespace của tenant khác
- delete service/deployment nếu không có approval

Ví dụ:

tnt-payment-demo chỉ được restart payment-api trong namespace tenant-payment.
Nếu cố restart checkout-api trong namespace tenant-checkout → bị chặn bởi middleware và RBAC.

Như vậy, Direct Patch path có 2 lớp bảo vệ:

Lớp 1: FastAPI middleware validate tenant_id và namespace
Lớp 2: Kubernetes RBAC chặn nếu code cố thao tác sai namespace
Path 2: GitOps path

GitOps path dùng cho các lỗi không quá khẩn cấp hoặc thay đổi cấu hình lâu dài, ví dụ queue backlog cần scale pod, tăng memory limit hoặc cập nhật config.

Luồng:

Webhook Receiver
→ Argo Workflow
→ Git Commit Engine
→ GitHub repo
→ ArgoCD sync
→ Tenant namespace
→ Verify
→ Audit

Mỗi tenant có folder Git riêng:

gitops-state/
└── tenants/
    ├── tnt-payment-demo/
    │   └── manifests/
    └── tnt-checkout-demo/
        └── manifests/

Mỗi tenant có một ArgoCD Application riêng:

selfheal-tnt-payment-demo
selfheal-tnt-checkout-demo

Tuy nhiên, chỉ có ArgoCD Application riêng là chưa đủ. Để enforce isolation tốt hơn, mỗi tenant cần có ArgoCD AppProject giới hạn source repo và namespace đích.

Ví dụ AppProject cho tnt-payment-demo:

apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: selfheal-payment
  namespace: argocd
spec:
  sourceRepos:
    - https://github.com/<org>/<repo>
  destinations:
    - namespace: tenant-payment
      server: https://kubernetes.default.svc

Ý nghĩa:

App của tnt-payment-demo chỉ được sync manifest vào namespace tenant-payment.
App này không được sync sang namespace tenant-checkout.
Nếu Git Commit Engine hoặc manifest bị lỗi path, ArgoCD AppProject vẫn là lớp chặn cuối.

Tóm lại:

Direct Patch path isolation = tenant validation + namespace RBAC
GitOps path isolation = Git folder riêng + ArgoCD Application riêng + AppProject giới hạn namespace
Data isolation = tenant_id partition + S3 prefix + SQS MessageAttributes



### 4.3. Quy trình thêm tenant mới

Khi có tenant mới muốn sử dụng Self-Heal Platform, nhóm dùng onboarding flow 5 bước.

Mục tiêu là tenant mới được tạo nhất quán, có namespace riêng, có RBAC riêng, có GitOps app riêng và được kiểm tra bằng smoke test trước khi active.

Bước 1: Register tenant

Platform admin tạo thông tin tenant mới.

Ví dụ:

{
  "tenant_id": "tnt-payment-demo",
  "tenant_name": "Payment Team",
  "tier": "pro",
  "namespace": "tenant-payment",
  "contact": "payment-oncall@example.com"
}

Thông tin này được lưu vào tenant registry.

Tenant registry có thể nằm trong DynamoDB table:

Table: tenant_registry
PK: tenant_id

Ví dụ record:

{
  "tenant_id": "tnt-payment-demo",
  "namespace": "tenant-payment",
  "tier": "pro",
  "status": "ACTIVE"
}
Bước 2: Tạo namespace và label

Terraform hoặc GitOps manifest tạo namespace cho tenant.

Ví dụ:

apiVersion: v1
kind: Namespace
metadata:
  name: tenant-payment
  labels:
    tenant_id: tnt-payment-demo
    tier: pro
    selfheal/enabled: "true"

Label này dùng để:

xác định namespace thuộc tenant nào;
validate tenant_id trong request;
hỗ trợ policy và routing.
Bước 3: Tạo RBAC và tenant policy

Hệ thống tạo Role và RoleBinding cho remediation executor trong namespace của tenant.

Ví dụ policy cho tnt-payment-demo:

tenant_id: tnt-payment-demo
namespace: tenant-payment
allowed_actions:
  - RESTART_DEPLOYMENT
  - SCALE_UP_PODS
blocked_actions:
  - DELETE_NAMESPACE
  - ACCESS_KUBE_SYSTEM
  - PATCH_CLUSTER_ROLE
limits:
  max_scale_multiplier: 2
  cooldown_minutes: 5

Ý nghĩa:

Tenant được phép restart/scale workload trong namespace của chính nó.
Tenant không được thao tác namespace khác.
Tenant không được thao tác tài nguyên cluster-level.
Action nguy hiểm phải bị block hoặc escalate.
Bước 4: Tạo GitOps folder, ArgoCD Application và AppProject

Mỗi tenant có folder Git riêng:

gitops-state/tenants/tnt-payment-demo/

Sau đó tạo ArgoCD Application riêng:

selfheal-tnt-payment-demo

Và AppProject riêng:

selfheal-payment

Application này chỉ được sync manifest từ folder của tenant vào namespace của tenant.

Cách này giúp GitOps path không sửa nhầm manifest hoặc namespace của tenant khác.

Bước 5: Chạy smoke test

Sau khi onboarding xong, hệ thống chạy smoke test trước khi tenant được dùng thật.

Smoke test gồm:

1. Gửi fake alert đúng tenant_id và namespace → expect ACCEPTED
2. Gửi fake alert sai namespace → expect 403 TENANT_NAMESPACE_MISMATCH
3. Thử remediation trong namespace của tenant → expect ALLOWED
4. Thử remediation sang namespace tenant khác → expect DENIED
5. Kiểm tra audit log được ghi đúng S3 prefix của tenant
6. Kiểm tra ArgoCD Application chỉ sync vào namespace được phép

Tenant chỉ được chuyển sang trạng thái ACTIVE sau khi smoke test pass.

Nếu dùng Terraform, các bước 2, 3 và 4 có thể được đóng gói trong module:

module: tenant-provision

Output của module:

- Kubernetes namespace
- namespace labels
- RBAC Role/RoleBinding
- tenant policy config
- GitOps folder
- ArgoCD Application
- ArgoCD AppProject
4.4. Chống một tenant chiếm hết tài nguyên

Trong hệ thống multi-tenant, một tenant có thể tạo quá nhiều alert hoặc remediation request, làm ảnh hưởng đến tenant khác. Trường hợp này gọi là noisy neighbor.

Ví dụ:

tnt-payment-demo bị lỗi CrashLoopBackOff liên tục
→ gửi 500 alert trong vài phút
→ worker xử lý toàn alert của payment
→ alert của checkout bị chậm hoặc không được xử lý kịp

Để tránh vấn đề này, hệ thống dùng 5 cơ chế:

1. Per-tenant rate limit
2. Idempotency lock và cooldown
3. Per-tenant concurrency limit
4. ResourceQuota trong namespace
5. Blast-radius policy theo từng action
4.4.1. Per-tenant rate limit

Mỗi tenant có giới hạn số incident được xử lý trong một phút.

Tier	Incident/phút	Concurrent remediation	Cooldown
Basic	10	2	10 phút
Pro	30	5	5 phút
Enterprise	60	10	2 phút

Trong demo:

tnt-checkout-demo:
- Tier: Basic
- 10 incidents/phút
- tối đa 2 remediation song song
- cooldown 10 phút

tnt-payment-demo:
- Tier: Pro
- 30 incidents/phút
- tối đa 5 remediation song song
- cooldown 5 phút

Vì Webhook Receiver expose qua Internal ALB, không dùng API Gateway, rate limit được implement trong FastAPI middleware.

Cơ chế: DynamoDB token bucket.

Table:

tenant_rate_limits

Key:

PK = tenant_id
SK = window_timestamp

Attributes:

count
quota
ttl

Luồng xử lý:

Request đi vào Webhook Receiver
→ FastAPI middleware đọc tenant_id
→ Tăng counter trong DynamoDB cho window 60 giây hiện tại
→ So sánh count với quota của tenant
→ Nếu count <= quota: cho request đi tiếp
→ Nếu count > quota: trả 429 và ghi audit event RATE_LIMITED

Response khi vượt quota:

HTTP 429 Too Many Requests
Retry-After: 30

Audit event:

{
  "event_type": "RATE_LIMITED",
  "tenant_id": "tnt-checkout-demo",
  "tier": "basic",
  "quota": "10 incidents/minute",
  "decision": "DENY"
}
4.4.2. Idempotency lock và cooldown

Rate limit xử lý vấn đề quá nhiều request. Nhưng với self-heal, còn một vấn đề khác: cùng một alert có thể bị gửi lặp lại nhiều lần.

Ví dụ:

payment-api CrashLoopBackOff
→ Alertmanager gửi alert liên tục
→ Nếu không có lock, platform có thể restart deployment quá nhiều lần

Để tránh điều này, hệ thống dùng DynamoDB conditional write để tạo idempotency lock.

Lock key:

tenant_id#namespace#service#alert_name#action_type

Ví dụ:

tnt-payment-demo#tenant-payment#payment-api#CrashLoopBackOff#RESTART_DEPLOYMENT

Nếu lock chưa tồn tại, platform tạo lock và thực hiện remediation.

Nếu lock đã tồn tại trong cooldown window, platform không execute lại action. Incident mới sẽ được đánh dấu:

SUPPRESSED_DUPLICATE

Ví dụ:

{
  "event_type": "SUPPRESSED_DUPLICATE",
  "tenant_id": "tnt-payment-demo",
  "service": "payment-api",
  "action_type": "RESTART_DEPLOYMENT",
  "reason": "Existing cooldown lock is still active."
}

Cách này giúp tránh restart/rollback liên tục trên cùng một workload.

4.4.3. Per-tenant concurrency limit

Ngoài rate limit, hệ thống cũng giới hạn số remediation chạy song song theo tenant.

Với Direct Patch path, Webhook Receiver dùng per-tenant semaphore trong FastAPI process.

Ví dụ:

Basic: asyncio.Semaphore(2)
Pro: asyncio.Semaphore(5)
Enterprise: asyncio.Semaphore(10)

Với GitOps path, Argo Workflows dùng workflow-level semaphore để giới hạn số workflow đang chạy của từng tenant.

Ví dụ:

Basic: tối đa 2 workflow đang chạy
Pro: tối đa 5 workflow đang chạy
Enterprise: tối đa 10 workflow đang chạy

Nếu tenant đã đạt giới hạn concurrency, incident mới sẽ chờ hoặc được đánh dấu:

TENANT_CONCURRENCY_LIMITED

Audit event:

{
  "event_type": "TENANT_CONCURRENCY_LIMITED",
  "tenant_id": "tnt-payment-demo",
  "limit": 5,
  "decision": "DELAY"
}
4.4.4. ResourceQuota trong namespace

Mỗi tenant có namespace riêng, nên hệ thống có thể áp dụng ResourceQuota và LimitRange để tenant này không dùng hết tài nguyên cluster.

Ví dụ ResourceQuota cho tenant-payment:

apiVersion: v1
kind: ResourceQuota
metadata:
  name: tenant-payment-quota
  namespace: tenant-payment
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 8Gi
    limits.cpu: "8"
    limits.memory: 16Gi
    pods: "40"

Ý nghĩa:

tenant-payment không thể tạo quá nhiều pod.
tenant-payment không thể dùng hết CPU/memory của cluster.
Tenant khác vẫn còn tài nguyên để chạy workload và remediation.
4.4.5. Blast-radius policy theo action

Không phải action nào AI đề xuất cũng được execute tự động. CDO platform phải kiểm tra blast radius trước khi chạy.

Action	Giới hạn
RESTART_DEPLOYMENT	Chỉ được restart deployment trong namespace của tenant
SCALE_UP_PODS	Tối đa tăng 2 lần số replicas hiện tại
ADJUST_MEMORY_LIMIT	Tối đa tăng 50% mỗi lần
ROLLBACK_DEPLOYMENT	Chỉ rollback về revision gần nhất đã ổn định
Unknown action	Block và escalate
Action đụng kube-system	Block
Action đụng tenant khác	Block

Nếu action bị block, incident có trạng thái:

BLOCKED_BY_POLICY

Nếu remediation fail nhiều lần hoặc verification không pass, incident có trạng thái:

ESCALATED

Ví dụ audit event khi bị block:

{
  "event_type": "BLOCKED_BY_POLICY",
  "tenant_id": "tnt-payment-demo",
  "service": "payment-api",
  "action_type": "SCALE_UP_PODS",
  "reason": "Requested scale exceeds max_scale_multiplier=2",
  "decision": "DENY"
}

Tóm lại, nhóm chọn Bridge Isolation vì mô hình này khớp với thiết kế hạ tầng đã chọn: DynamoDB, SQS và S3 dùng chung để giảm chi phí, còn quyền thực thi được tách bằng namespace, RBAC, ArgoCD Application và AppProject. Cách này tiết kiệm hơn Silo nhưng an toàn hơn Pool thuần, đồng thời vẫn chứng minh được isolation với ít nhất 2 tenant trong phạm vi capstone.








# 5. Alternatives Considered & Infrastructure Components

Tài liệu này phân tích các giải pháp thay thế kỹ thuật đối với từng cấu phần (service) trong hệ thống tự chữa lành thuộc dự án Capstone, đồng thời biện luận dựa trên quy mô thực tế của doanh nghiệp SaaS B2B lớn (200+ microservices, lưu trữ 12TB dữ liệu với traffic biến động cao từ 120 khách hàng doanh nghiệp).

## 5.1 Compute Layer (EKS Compute Provisioning)

* **Option A — EKS Fargate Profile:**
    * *Pros:* Mô hình Serverless hoàn toàn cho Kubernetes, loại bỏ hoàn toàn công sức vận hành, vá lỗi và quản lý EC2 node phía dưới.
    * *Cons:* Gặp **technical blocker thực sự**: Fargate không hỗ trợ triển khai `DaemonSet`. Trong khi đó, hệ thống giám sát bắt buộc phải chạy ADOT/OTel Collector dưới dạng `DaemonSet` mức node để thu thập chỉ số hạ tầng theo deployment-contract. Ngoài ra, cấu phần `ArgoCD repo-server` cần một writable local filesystem ổn định, điều thường xuyên gây friction (xung đột/lỗi gán ổ đĩa) trên Fargate. Xét góc nhìn SaaS lớn, việc chạy Fargate sẽ khiến chi phí tích lũy theo từng Pod lẻ nhảy vọt lên mức khổng lồ, không có khả năng tối ưu hóa chia sẻ tài nguyên.
    * *Estimated Cost:* ~$120–180/tháng cho workload tương đương sandbox.
* **Option B — EKS Managed Node Group + Karpenter:**
    * *Pros:* Node provisioning thông minh, tự động phân tích nhu cầu của Pod để cấp phát các node EC2 với size tối ưu nhất (bin-packing), giúp tiết kiệm chi phí biên cực tốt cho môi trường Production dài hạn.
    * *Cons:* Độ dốc học tập (learning curve) cao, tốn nhiều thời gian cấu hình và kiểm thử vận hành lớn, tạo ra rủi ro trễ hạn đối với timeline 2 tuần của dự án Capstone.
    * *Estimated Cost:* ~$90–120/tháng.
* **Option C — EKS Managed Node Group + Cluster Autoscaler:**
    * *Pros:* Công nghệ mature và phổ biến, tài liệu module EKS và Terraform module hoạt động cực kỳ ổn định. Hỗ trợ đầy đủ và native cho các `DaemonSet` mức node. Cho phép **Resource Pooling** (gom nhiều microservices nhỏ vào chung các node EC2 lớn m5.large để tối ưu hóa hiệu năng phần cứng và tiết kiệm chi phí nền).
    * *Cons:* Tốc độ scale node chậm hơn Karpenter (phải chờ AWS ASG kích hoạt) và khả năng bin-packing chưa tối ưu bằng Karpenter ở quy mô siêu lớn.
    * *Estimated Cost:* ~$96–110/tháng (02 node m5.large chạy 24/7 trong 2 tuần demo + phí EKS Control Plane).

✅ **Chosen:** Option C — EKS Managed Node Group + Cluster Autoscaler
* **Reason:** Đáp ứng đầy đủ technical constraint của ADOT DaemonSet, triển khai nhanh bằng Terraform, phù hợp ngân sách sandbox và bảo toàn năng lực gom cụm tài nguyên cho 200+ microservices của SaaS lớn. Phương án Karpenter được ghi nhận và đẩy vào "production roadmap" trong tương lai.

## 5.2 State & Idempotency Database

* **Option A — Amazon ElastiCache Redis:**
    * *Pros:* Tốc độ phản hồi cực nhanh (in-memory latency < 1ms), hỗ trợ cơ chế thiết lập TTL native để tự động xóa khóa phân tán rất tiện lợi.
    * *Cons:* Phải duy trì cụm node chạy liên tục 24/7 (phát sinh chi phí cố định ngay cả khi hệ thống hoàn toàn idle), tăng tải vận hành (ops overhead). Với bài toán SaaS lớn chạm mốc 12TB dữ liệu, việc lưu trữ lượng lớn trạng thái transaction trên RAM của Redis sẽ đẩy chi phí hạ tầng tăng lên theo cấp số nhân.
    * *Estimated Cost:* ~$15–30/tháng.
* **Option B — DynamoDB On-Demand + Conditional Write:**
    * *Pros:* Cơ chế tính phí Pay-per-request giúp tối ưu hóa chi phí về $0 khi không có traffic (idle). Tính năng `conditional write` giải quyết trực tiếp yêu cầu làm Idempotency Lock Store chống xử lý trùng lặp alert. Khả năng scale-out vô hạn về cả dung lượng và throughput, hoàn toàn đáp ứng nhu cầu tăng trưởng dữ liệu 12TB của doanh nghiệp SaaS lớn. Đồng bộ pattern xử lý dữ liệu với AI team.
    * *Cons:* Latency cao hơn Redis vài mili-giây do truy xuất qua tầng HTTPS API và phải thiết kế cấu trúc Partition Key cẩn thận từ đầu.
    * *Estimated Cost:* ~$0–5/tháng (traffic sandbox nằm hoàn toàn trong Free Tier).

✅ **Chosen:** Option B — DynamoDB On-Demand
* **Reason:** Tối ưu chi phí sandbox về mức tối thiểu, đồng thời vẫn chứng minh được khả năng scale vượt trội cho bài toán SaaS lớn. Cơ chế conditional-write giải quyết triệt để yêu cầu chống xử lý trùng lặp lệnh khi xảy ra bão alert.

## 5.3 Webhook Receiver (Entry Layer)

* **Option A — AWS API Gateway + Lambda:**
    * *Pros:* Fully managed bởi AWS, tự động scale theo traffic, mô hình chi phí pay-per-use tối ưu.
    * *Cons:* Làm phức tạp hóa ranh giới bảo mật không cần thiết. Buộc phải thiết lập thêm một chuỗi kết nối phức tạp (`IAM ↔ K8s credential bridge`) để Lambda từ ngoài gọi ngược vào EKS API Server, làm mở rộng ranh giới bảo mật (Trust Boundary).
    * *Estimated Cost:* ~$0–10/tháng.
* **Option B — FastAPI Deployment trên EKS cụm nội bộ:**
    * *Pros:* Nằm trọn vẹn trong cùng một Trust Boundary bảo mật với hệ thống tự chữa lành (namespace `self-heal-system`). Sử dụng trực tiếp ServiceAccount nội bộ cụm thông qua hàm `load_incluster_config()`, loại bỏ hoàn toàn việc expose IAM credential ra ngoài. Đồng bộ stack code FastAPI với nhóm AI.
    * *Cons:* Phải tự quản lý manifest deployment và chạy liên tục trên cluster.
    * *Estimated Cost:* $0 thêm (Tận dụng không gian Compute Headroom của EKS Node Group có sẵn ở mục 5.1).

✅ **Chosen:** Option B — FastAPI Deployment
* **Reason:** Đơn giản hóa kiến trúc bảo mật, loại bỏ hoàn toàn cơ chế credential bridging phức tạp và tận dụng tối đa hạ tầng EKS sẵn có.
  
## 5.4 Orchestrator (GitOps Path)

* **Option A — AWS Step Functions + Lambda:**
    * *Pros:* Trạng thái xử lý (state machine), cơ chế retry và timeout được build-in sẵn. Quản lý luồng trực quan trực tiếp trên AWS Console UI, chi phí pay-per-use lý tưởng.
    * *Cons:* Bộ điều phối nằm ngoài cluster, làm tăng độ phức tạp khi phân quyền chéo. Bản chất luồng GitOps xử lý lỗi Loại 2 không cần chạm trực tiếp vào EKS API mà đi qua Git repository, nên việc đưa state machine ra ngoài không mang lại lợi ích bảo mật nào thực tế.
    * *Estimated Cost:* ~$0–5/tháng.
* **Option B — Argo Workflows (Self-hosted trên K8s):**
    * *Pros:* Native Kubernetes CRD chạy ngay trong cụm, hỗ trợ xử lý luồng phức tạp dạng DAG và retry container mạnh mẽ. Giao diện UI hiển thị real-time đồng bộ trong hệ sinh thái K8s giúp demo trực quan hơn. Đội dự án đã de-risked rủi ro nhân sự khi có 01 thành viên chủ chốt có kinh nghiệm vận hành thực tế.
    * *Cons:* Phải quản lý các CRD nội bộ trong cụm K8s.
    * *Estimated Cost:* $0 thêm (Compute overhead chạy trực tiếp trên EKS Node Group sẵn có, chi phí đã được gộp trọn gói vào mục 5.1).

✅ **Chosen:** Option B — Argo Workflows
* **Reason:** Toàn bộ bộ não điều phối nằm trong cùng một Trust Boundary bảo mật với ArgoCD và Direct Patch Engine, giúp giảm độ phức tạp vận hành và tăng tính đồng bộ, thuyết phục khi demo thực tế.

## 5.5 Direct Patch Engine — Loại 1 (Khẩn Cấp / Out-of-Band)

* **Option A — AWS Lambda gọi vào EKS API:**
    * *Pros:* Tách biệt hoàn toàn khỏi lifecycle của cụm K8s, khả năng tự động scale-out độc lập khi gặp bão alert sự cố.
    * *Cons:* Tốn thêm network hop từ ngoài vào mạng nội bộ cụm EKS, cần cấu hình phân quyền IRSA phức tạp và làm tăng độ trễ (latency) xử lý hành động khẩn cấp.
    * *Estimated Cost:* ~$0–5/tháng.
* **Option B — Python kubernetes-client chạy In-Process:**
    * *Pros:* Thực hiện same-cluster API call (gọi trực tiếp trong cụm), mang lại latency thực thi cực thấp nhằm đáp ứng cam kết mốc thời gian phản hồi hành động chữa lành khẩn cấp dưới 15 giây. Triển khai cực kỳ đơn giản.
    * *Cons:* Gắn chặt vào lifecycle của Webhook Receiver pod, không thể bóc tách để scale độc lập cấu phần.
    * *Estimated Cost:* $0 thêm (Chạy chung pod với Webhook Receiver).

✅ **Chosen:** Option B — Python kubernetes-client
* **Reason:** Ưu tiên tối thượng cho tốc độ phản hồi cực thấp để xử lý các sự cố khẩn cấp (như Pod bị OOMKilled hoặc Service stuck) ở quy mô môi trường sandbox.

## 5.6 Event Queue (Telemetry Pipeline)

* **Option A — SQS FIFO (First-In-First-Out):**
    * *Pros:* Đảm bảo thứ tự tin nhắn tuyệt đối (ordering guarantee) và hỗ trợ chống trùng lặp dữ liệu ở mức hạ tầng Cloud.
    * *Cons:* Throughput bị giới hạn nghiêm ngặt (300 - 3000 msg/s), không cần thiết khi hệ thống đã được thiết kế phòng vệ nhiều lớp ở tầng trên.
    * *Estimated Cost:* ~$0–2/tháng.
* **Option B — SQS Standard Queue:**
    * *Pros:* Thống số throughput gần như không giới hạn, chi phí tiệm cận mức $0, dễ dàng cấu hình bằng Terraform và đáp ứng hoàn hảo kịch bản bão alert (alert storm) của hệ thống SaaS gồm 200+ dịch vụ nhỏ.
    * *Cons:* Chấp nhận rủi ro nhỏ về at-least-once delivery (có thể phân phát lặp lại tin nhắn trong điều kiện mạng lỗi).
    * *Estimated Cost:* ~$0–2/tháng (nằm trong hạn mức 1 triệu request Free Tier của AWS).

✅ **Chosen:** Option B — SQS Standard
* **Reason:** Rủi ro trùng lặp hay sai thứ tự đã được xử lý triệt để bởi lớp ứng dụng nhờ sự kết hợp giữa `Idempotency-Key` và `DynamoDB conditional write`, do đó sử dụng SQS Standard là phương án tối ưu nhất về mặt kiến trúc phần cứng.


## 5.7 Audit Query Layer

* **Option A — OpenSearch Cluster / CloudWatch Logs Insights:**
    * *Pros:* Khả năng tìm kiếm text nâng cao mạnh mẽ, hỗ trợ dựng các hệ thống dashboard và analytics thời gian thực cho đội ngũ vận hành.
    * *Cons:* Chi phí duy trì cụm instance OpenSearch cực cao, tốn nhiều công sức vận hành hạ tầng nền và hoàn toàn vượt biên ngân sách $200 của sandbox. Không hỗ trợ native việc lưu trữ cô lập dạng dữ liệu bất biến chống sửa xóa theo yêu cầu compliance bằng S3 Object Lock.
    * *Estimated Cost:* ~$30–100+/tháng.
* **Option B — Amazon Athena (Serverless SQL):**
    * *Pros:* Kiến trúc Serverless hoàn toàn, mô hình tính phí pay-per-query (chỉ tính tiền dựa trên lượng dữ liệu quét qua lúc demo thực tế). Cho phép dùng cú pháp SQL tiêu chuẩn để truy vấn trực tiếp trên các file log tĩnh được lưu trữ nghiêm ngặt tại S3. 
    * *Cons:* Tốc độ truy vấn chậm hơn OpenSearch đối với các tác vụ tìm kiếm tương tác thời gian thực liên tục (interactive search).
    * *Estimated Cost:* ~$1–5/tháng (chỉ tốn vài cent cho vài chục câu lệnh demo lúc chấm pitch).

✅ **Chosen:** Option B — Athena
* **Reason:** Đáp ứng xuất sắc yêu cầu bài toán audit trail với chi phí thấp và không mất công vận hành cluster riêng. Đặc biệt, Athena cho phép truy vấn trực tiếp trên S3 đã kích hoạt cấu hình **S3 Object Lock (Compliance Mode)** khóa cứng dữ liệu trong 90 ngày, đảm bảo tính bất biến tuyệt đối của dữ liệu log chống sửa xóa (*tamper-evident*) theo đúng luật đề bài.


## 5.8 Observability Layer

* **Option A — Self-hosted kube-prometheus-stack:**
    * *Pros:* Miễn phí hoàn toàn về mặt bản quyền service, toàn quyền kiểm soát cấu hình metrics hệ thống.
    * *Cons:* Đội thêm quá nhiều công việc vận hành hạ tầng cho team trong vòng 2 tuần (phải tự size dung lượng lưu trữ ổ đĩa PVC, tự cấu hình cụm tính sẵn sàng cao HA cho Prometheus, tự quản lý chính sách nén dữ liệu).
    * *Estimated Cost:* ~$20–50/tháng cho phần compute + storage gán thêm.
* **Option B — Amazon Managed Prometheus (AMP) + Amazon Managed Grafana (AMG):**
    * *Pros:* Mô hình managed hoàn toàn từ AWS. AWS chịu toàn bộ trách nhiệm về tính sẵn sàng cao (HA), khả năng lưu trữ (retention) và vá lỗi hệ thống. Tích hợp mượt mà và bảo mật với ADOT Collector chạy dạng `DaemonSet` mức node.
    * *Cons:* Chi phí dịch vụ tính riêng biệt trên hóa đơn AWS, phụ thuộc chặt chẽ vào hệ sinh thái managed của nhà cung cấp Cloud.
    * *Estimated Cost:* ~$10–20/tháng (tính theo lượng metric nạp vào và phí không gian workspace).

✅ **Chosen:** Option B — AMP + AMG
* **Reason:** Giảm tối đa khối lượng công việc vận hành hạ tầng (ops effort) trong thời gian ngắn ngủi 2 tuần, giải phóng 100% thời gian của các thành viên để tập trung hoàn thiện logic cốt lõi của Self-Heal Engine nhằm bàn giao sản phẩm đúng hạn kỳ Capstone.

## 6. Scaling strategy

- **Vertical**: <!-- CPU/memory bump triggers -->
- **Horizontal**: <!-- auto-scaling rules -->
- **Triggers**: <!-- target CPU 70% / request count / queue depth -->

## 7. Failure modes + recovery

| Failure | Detection | Recovery | RTO | RPO |
|---|---|---|---|---|
| Single task crash | ECS/K8s health check | Auto-restart | < 60s | 0 |
| AZ outage | CloudWatch alarm | Multi-AZ failover | < 5min | < 1min |
| DB primary fail | RDS event | Read replica promotion | < 5min | < 1min |
| Region outage | External monitor | Manual region switch | TBD | TBD |

## Related documents

- [`03_security_design.md`](03_security_design.md)
- [`04_deployment_design.md`](04_deployment_design.md)
- [`05_cost_analysis.md`](05_cost_analysis.md)
- [`08_adrs.md`](08_adrs.md)
