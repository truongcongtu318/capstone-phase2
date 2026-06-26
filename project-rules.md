# 📖 CẨM NANG QUY TẮC PHỐI HỢP & LÀM VIỆC NHÓM (PROJECT RULES)
**Dự án: Capstone Phase 2 — Hệ thống Tự Chữa Lành (Self-Heal System - CDO-01)**
*Bản Đặc Tả Kỹ Thuật Chi Tiết - Khớp 100% Tài Liệu Thiết Kế (Infra, Security, Deployment & Contracts)*

Tài liệu này là luật bất biến của dự án CDO-01. Tất cả 9 thành viên phải tuân thủ tuyệt đối để bảo vệ ranh giới an toàn mạng, tránh xung đột mã nguồn và đạt được các mục tiêu phi chức năng (NFRs) đã cam kết với khách hàng.

---

## I. QUY TẮC NHÁNH GIT & QUY TRÌNH PHÊ DUYỆT PULL REQUEST (PR)

### 1. Quản lý Nhánh (Branching Strategy)
*   **Nhánh chính (`main`):** Là Single Source of Truth của hệ thống. Nhánh này đại diện cho trạng thái mong muốn (Desired State) của cụm production/sandbox và luôn ở trạng thái sẵn sàng deployable. CẤM TUYỆT ĐỐI direct push và force push.
*   **Nhánh tính năng (`feature/*`, `fix/*`, `hotfix/*`, `docs/*`):** Tạo ra từ `main`. Phải tuân thủ quy tắc đặt tên nghiêm ngặt theo phân vùng làm việc của từng Sub-team.
*   **Quy tắc phân vùng tên nhánh (Branch Naming Matrix):**
    *   **Sub-team 1 (Platform):** `infra/<feature-name>` (Ví dụ: `infra/kms-audit-keys`, `infra/vpc-endpoints-s3`).
    *   **Sub-team 2 (App & AI):** `app/<component>-<feature-desc>` (Ví dụ: `app/receiver-cooldown`, `app/worker-kubernetes-client`).
    *   **Sub-team 3 (GitOps & QA):** `gitops/<app-name>-manifest` hoặc `test/<incident-type>-simulation` (Ví dụ: `gitops/prom-rules-oom`, `test/rds-block-network`).

### 2. Quy trình Quality Gate & Merge PR (4 Cửa Ải Bắt Buộc)
Mỗi PR trước khi được merge vào `main` bắt buộc phải đi qua và vượt qua đầy đủ 4 cổng kiểm soát chất lượng tự động và thủ công:
1.  **Cửa ải 1: Static Analysis & Security Testing (Automated CI Check)**
    *   **IaC (Terraform):** Tự động chạy `terraform fmt -check`, `terraform validate`, và scan bảo mật bằng `tfsec` hoặc `checkov`.
    *   **Python Code (FastAPI Webhook / SQS Worker):** Tự động chạy `ruff check .` để kiểm tra chất lượng code, chạy quét mã độc và lộ bí mật bằng `gitleaks-action`.
    *   **Kubernetes Manifests (YAML):** Quét lỗi cú pháp bằng `kube-linter` và tự động kiểm tra định dạng YAML thông qua Python YAML parser.
2.  **Cửa ải 2: Unit Test & Contract Verification**
    *   Các đoạn code nghiệp vụ (FastAPI, Worker, Python SDK) phải có unit tests viết bằng `pytest` đạt độ bao phủ dòng code (Test Coverage) **tối thiểu là 70%**.
    *   CI Pipeline chạy test trên môi trường giả lập (mock DynamoDB, mock SQS, mock AI API) để xác nhận code chạy đúng logic nghiệp vụ.
3.  **Cửa ải 3: Peer Review (Đánh giá chéo từ Sub-team khác)**
    *   Bắt buộc phải nhận được **tối thiểu 2 Approval** từ các thành viên thuộc các sub-team khác.
    *   **Quy tắc CODEOWNERS:** 
        *   Các file trong thư mục `infra/` phải được phê duyệt bởi ít nhất 1 thành viên của Sub-team 1.
        *   Các file trong thư mục `apps/` phải được phê duyệt bởi ít nhất 1 thành viên của Sub-team 2.
        *   Các file trong thư mục `gitops/` và `.github/` phải được phê duyệt bởi ít nhất 1 thành viên của Sub-team 3.
4.  **Cửa ải 4: Tech Lead Approval & Squash Merge**
    *   Chỉ có Tech Lead (anh Tú) mới có quyền bấm nút **Squash and Merge** sau khi các điều kiện trên đã được đáp ứng hoàn toàn.

---

## II. CHIẾN LƯỢC PHÂN TÁCH STATE & DEPLOY TỪNG PHẦN (INCREMENTAL DEPLOYMENT)

Hạ tầng AWS và các Platform Service được chia làm **4 Phase độc lập** để cô lập blast radius và tránh hiện tượng lock state chồng chéo khi 9 người cùng thao tác. 

### 1. Phân rã Phase & Key State trên S3
Tất cả các State File (`.tfstate`) được lưu trữ tại S3 Bucket chung `tf3-cdo1-sandbox-tfstate-<account-id>` và khóa DynamoDB `tf-3-aiops-idempotency-lock` với cấu trúc phân cấp:
*   **Phase 1: Bootstrapping (`infra/phases/01-bootstrap/`)**
    *   *Nhiệm vụ:* Khởi tạo State Bucket, DynamoDB Lock table, các KMS Key cơ sở, OIDC Provider kết nối GitHub Actions với AWS IAM Roles.
    *   *S3 State Key:* `sandbox/01-bootstrap.tfstate`
*   **Phase 2: Core Platform Network & Security (`infra/phases/02-core-platform/`)**
    *   *Nhiệm vụ:* VPC, 12 VPC Interface/Gateway Endpoints, Route Tables, 5 Security Groups, và KMS Keys.
    *   *S3 State Key:* `sandbox/02-core-platform.tfstate`
*   **Phase 3: Compute Engine Cluster (`infra/phases/03-compute-eks/`)**
    *   *Nhiệm vụ:* Amazon EKS Cluster Control Plane (v1.28), Managed Node Groups, Karpenter IAM Roles, OIDC Provider ARN cho EKS Pod IRSA.
    *   *S3 State Key:* `sandbox/03-compute-eks.tfstate`
*   **Phase 4: Platform Services & Workloads (`infra/phases/04-services/`)**
    *   *Nhiệm vụ:* Deploy Helm Releases (ArgoCD, Kube-Prometheus-Stack, External Secrets Operator, AWS Load Balancer Controller), Kyverno Policies, NetworkPolicies, và các K8s resources ban đầu.
    *   *S3 State Key:* `sandbox/04-services.tfstate`

### 2. Quy tắc Chia sẻ Dữ liệu Giữa các Phase (Remote State Constraints)
CẤM TUYỆT ĐỐI việc khai báo lại (Redefine) các tài nguyên của phase trước trong phase sau. Để lấy thông tin cấu hình (ví dụ: VPC ID, Subnet IDs, KMS ARN), các phase sau phải sử dụng `data.terraform_remote_state` để đọc output từ state của phase trước.

---

## III. MẠNG VPC NAT-LESS & BẢO MẬT RANH GIỚI (VPC ENDPOINTS & SECURITY GROUPS)

Môi trường Sandbox chạy EKS CDO-01 hoàn toàn cô lập với Internet công cộng (Không NAT Gateway). Toàn bộ luồng kết nối ngoại vi tới AWS API phải đi qua VPC Endpoints nằm trong mạng Private Subnets.

### 1. Luật Ingress/Egress Cứng cho 5 Security Groups cốt lõi

| Security Group | Attached to | Ingress Rules (Chiều Vào) | Egress Rules (Chiều Ra) |
|---|---|---|---|
| **`sg-alb-internal`** | Internal ALB | - TCP 443 từ IP CIDR của VPN/Internal Client hoặc Alert Relay Component. | - TCP 8443 đi đến `sg-eks-workload` (Webhook Receiver). <br>- TCP 8080 đi đến `sg-eks-workload` (AI Engine - nếu gọi trực tiếp). |
| **`sg-eks-workload`** | EKS Worker Nodes & Workload Pods | - TCP 8443 (Webhook Receiver) từ `sg-alb-internal`. <br>- TCP 8080 (AI Engine) từ các nguồn trong cụm EKS. <br>- TCP 10250 từ `sg-eks-control-plane`. <br>- Pod-to-Pod traffic mặc định bị chặn hoàn toàn, chỉ được mở qua K8s NetworkPolicy. | - TCP 443 đi đến `sg-vpc-endpoint`. <br>- TCP 5432 đi đến `sg-rds`. <br>- TCP 443 đi đến `sg-eks-control-plane`. |
| **`sg-eks-control-plane`** | EKS Control Plane ENIs | - TCP 443 từ `sg-eks-workload` (Nodes) và GitHub Actions Runner IP (nếu dùng self-hosted hoặc CIDR an toàn). | - TCP 10250 đi đến `sg-eks-workload` (Nodes). <br>- TCP 443 đi đến AWS API qua VPC Endpoints. |
| **`sg-rds`** | RDS Instance ENIs | - TCP 5432 chỉ cho phép nguồn từ `sg-eks-workload`. | - Chặn hoàn toàn (Egress None - Mọi phản hồi đi theo connection tracking mặc định). |
| **`sg-vpc-endpoint`** | Interface VPC Endpoints | - TCP 443 từ `sg-eks-workload`. <br>- TCP 443 từ `sg-eks-control-plane`. | - TCP 443 đi đến AWS service endpoint target tương ứng. |

### 2. Quy định Mirroring ECR bắt buộc
Do không có đường truyền Internet trực tiếp từ các worker nodes, cụm EKS không thể phân giải hoặc kéo các image công cộng từ Docker Hub, Quay.io hay các Helm charts ngoài.
*   **Thực thi:** Toàn bộ container images phục vụ hệ thống (FastAPI, Worker, Prometheus, Karpenter, Kyverno) bắt buộc phải được Sub-team 1 và Sub-team 3 kéo về máy local có internet, quét lỗ hổng bằng Trivy/Snyk, gắn thẻ tag theo commit SHA, và push lên **AWS ECR Private Registry** (`544011261607.dkr.ecr.us-east-1.amazonaws.com`).
*   Tất cả Helm charts phải được package dưới dạng `.tgz` và lưu trữ tại S3 Helm Repository nội bộ trước khi khai báo trong Terraform/ArgoCD.

---

## IV. PHÂN TÁCH ĐỊNH DANH IAM & ỦY QUYỀN KUBERNETES RBAC (ZERO TRUST MATRIX)

### 1. Phân tách Ranh giới Ủy quyền (Execution Boundary)
Hệ thống tuân thủ chặt chẽ nguyên tắc phân tách giữa Bộ Não (Brain) và Bàn Tay (Hands):
*   **AI Engine (Brain):** Được triển khai dưới dạng Pod trong namespace `self-heal-system`. Container của AI Engine KHÔNG ĐƯỢC chứa file `kubeconfig`, không được cài đặt `kubectl` hoặc Kubernetes client SDK, và không được gắn ServiceAccount có quyền thay đổi trạng thái cụm K8s API. AI Engine chỉ nhận input telemetry, gọi mô hình Bedrock Claude 3 qua IAM Role (IRSA), và trả về Action Plan.
*   **CDO Controller / Worker (Hands):** Là đối tượng duy nhất được phép tương tác với Kubernetes API Server để thực thi các hành động vá lỗi (Fast Lane/Slow Lane) dựa trên Action Plan từ AI Engine.

### 2. Ma trận Kubernetes RBAC (least-privilege)
*   `sa/patch-receiver` (Namespace: `self-heal-system`):
    *   *Permissions:* Chỉ được phép `get`, `list` đối với `configmaps`, `services`, `endpoints` trong namespace `self-heal-system`. Cấm tuyệt đối các verb: `create`, `update`, `patch`, `delete`.
*   `sa/patch-controller` (Namespace: `self-heal-system`):
    *   *Permissions:* Được phép `get`, `list`, `watch`, `patch`, `update` đối với `deployments`, `statefulsets`, `configmaps`, `horizontalpodautoscalers` tại các namespace của tenant được chỉ định cụ thể (`tenant-payment`, `tenant-checkout`). 
    *   *Quy tắc cấm:* Cấm tuyệt đối thao tác trên các namespace hệ thống (`kube-system`, `argocd`, `observability`).
*   `sa/argocd-application-controller` (Namespace: `argocd`):
    *   *Permissions:* Chỉ được thao tác với các resource được định nghĩa rõ ràng trong phạm vi quản lý của ArgoCD `AppProject`.

### 3. Admission Controller Guardrails (Kyverno Policy)
Để ngăn chặn lỗi leo thang đặc quyền (Privilege Escalation) từ phía CDO Controller/Worker, một Kyverno ClusterPolicy bắt buộc phải được kích hoạt trên cụm:
*   **Quy tắc:** Chỉ cho phép ServiceAccount `self-heal-executor` thực hiện hành động `PATCH` đối với các trường:
    *   `spec.replicas` (Khi scale pod)
    *   `spec.template.spec.containers[*].resources.limits` (Khi đổi RAM/CPU limits)
*   **Chặn đứng:** Mọi request sửa đổi cấu hình image tag, mount HostPath volume, chạy container dưới quyền Root (privileged: true), hoặc can thiệp các namespace bảo vệ (`kube-system`, `argocd`, `observability`) đều bị Admission Controller từ chối ở tầng API Server.

---

## V. CƠ CHẾ KHÓA TRÙNG LẶP (IDEMPOTENCY) & COOLDOWN SCAFFOLDING

### 1. Khóa Cooldown Nghiệp vụ (DynamoDB Table: `tf-3-aiops-idempotency-lock`)
Để ngăn chặn Alert Storm làm nghẽn hoặc sập hệ thống (ví dụ: pod OOMKilled liên tục bắn alert), Webhook Receiver bắt buộc phải thực hiện cơ chế khóa ghi có điều kiện (Conditional Write) xuống DynamoDB:
*   **Khóa định danh (Lock Key):** `lock_key = SHA256(tenant_id + namespace + service_name + alert_name)`
*   **Thời gian Cooldown Động theo Tenant Tier:**
    *   *Basic Tier (`tenant-checkout`):* Cooldown 5 phút (300 giây).
    *   *Pro Tier (`tenant-payment`):* Cooldown 3 phút (180 giây).
*   **Cú pháp DynamoDB Write:**
    ```json
    {
      "TableName": "tf-3-aiops-idempotency-lock",
      "Item": {
        "lock_key": {"S": "d3b07384-d113-495f-9f58-20d18d357d75#tenant-payment#payment-api#OOMKilled"},
        "expiration_time": {"N": "1782480000"}, // Current Epoch + Dynamic Cooldown (180s/300s)
        "status": {"S": "ACTIVE"}
      },
      "ConditionExpression": "attribute_not_exists(lock_key) OR expiration_time < :now",
      "ExpressionAttributeValues": {
        ":now": {"N": "1782479820"}
      }
    }
    ```
*   **Xử lý Logic:** 
    *   Nếu ghi thành công: Đẩy alert payload vào SQS Queue.
    *   Nếu nhận lỗi `ConditionalCheckFailedException`: Webhook trả về HTTP `409 Conflict` lập tức và bỏ qua alert này.

### 2. Khóa Idempotency Giao dịch AI Engine (Bắt buộc theo API Contract)
Khi Worker gọi API sang các endpoint của AI Engine (`/v1/detect`, `/v1/decide`, `/v1/verify`), bắt buộc phải truyền header `Idempotency-Key` dạng UUID v4 và header `X-Dry-Run-Mode` (dạng chuỗi `"true"` hoặc `"false"`). AI Engine sử dụng key này để ghi nhận trạng thái giao dịch bất biến, chống xử lý trùng lặp. Mọi payload request gửi sang AI Engine phải được validate cú pháp JSON Schema trước khi truyền đi để đảm bảo không bị trả lỗi 400 Bad Request. Dữ liệu nhạy cảm (credentials, password, token) xuất hiện trong application log trace bắt buộc phải được scrubbed (xóa/ẩn danh hóa) trước khi đóng gói thành telemetry gửi đi.

### 3. Log Kiểm Toán Bất Biến (Audit Trail Compliance)
*   **Mô tả:** Mọi hành động khắc phục sự cố (bắt đầu, kết thúc, kết quả) bắt buộc phải được ghi nhận bất biến (immutable logs) để phục vụ chứng chỉ SOC2 Type II.
*   **Kênh truyền dẫn:** Worker sử dụng SDK Python ghi log trực tiếp vào AWS Kinesis Data Firehose delivery stream mang tên `tf3-cdo1-sandbox-audit-stream` thông qua IRSA Role `tf3-cdo1-sandbox-irsa-audit-writer`.
*   **Lưu trữ bất biến:** Kinesis Firehose tự động chuyển tiếp log xuống S3 Audit Bucket `tf-3-aiops-audit-trail`. Bucket này được cấu hình **S3 Object Lock ở chế độ COMPLIANCE mode** với thời gian bảo vệ giữ lại tối thiểu **90 ngày**. Mọi quyền xóa/sửa đổi log trong thời gian này đều bị AWS chặn ở tầng vật lý, kể cả tài khoản root.

### 4. Cơ chế Ngắt Mạch Tự Động (Circuit Breaker)
*   **Ngưỡng ngắt mạch:** Nếu một dịch vụ của Tenant xảy ra lỗi và hành động tự vá lỗi (Direct Patch hoặc GitOps) thất bại liên tiếp **3 lần trong vòng 1 giờ**, hệ thống Circuit Breaker phải kích hoạt.
*   **Logic xử lý:** Đánh dấu trạng thái `CIRCUIT_BREAKER_OPEN` của dịch vụ đó lên bảng DynamoDB lock. Chặn toàn bộ các hành động tự chữa lành tự động tiếp theo cho dịch vụ đó.
*   **Escalation Path:** Tự động gọi SDK AWS SNS gửi tin nhắn khẩn cấp tới SNS Topic `tf3-cdo1-sandbox-alerts-escalation` để định tuyến cảnh báo trực tiếp về kênh Slack của đội ngũ on-call (TL/SRE) xử lý thủ công.

---

## VI. PHÂN LẬP TENANT TRÊN MÔ HÌNH BRIDGE ISOLATION

Hệ thống CDO-01 sử dụng mô hình **Bridge Isolation**: dùng chung hạ tầng tính toán EKS và database nhưng cách ly logic dữ liệu và quyền thực thi tuyệt đối:

### 1. Phân vùng dữ liệu logic (Data Partitioning)
*   **DynamoDB & RDS:** Mọi bảng dữ liệu phải chứa thuộc tính `tenant_id` làm khóa phân vùng (Partition Key).
*   **S3 Audit Bucket (`tf-3-aiops-audit-trail`):** Log của từng tenant được chia thư mục rõ ràng: `s3://tf-3-aiops-audit-trail/<tenant_id>/year=2026/...`

### 2. Xác thực chéo & Ngăn chặn Tấn công chéo (Cross-Tenant Attack)
*   **FastAPI Zero Trust Middleware:** Khi nhận alert, Webhook tự động giải mã header `X-Tenant-Id` (UUID v4) và đối chiếu với namespace của pod bị lỗi trong payload.
*   **Quy tắc cấm:** Nếu alert thuộc namespace `tenant-payment` nhưng lại gửi kèm `X-Tenant-Id` của `tenant-checkout` (UUID: `6c8b4b2b-4d45-4209-a1b4-4b532d56a31c`), hệ thống lập tức hủy request, ghi log lỗi bảo mật `SECURITY_VIOLATION` và từ chối xử lý.
*   **Rate Limiting:** Middleware giới hạn số lượng alert tối đa/phút dựa theo Subscription Tier của Tenant:
    *   *Basic Tier (`tenant-checkout`):* Tối đa 10 requests/phút, Cooldown 5 phút (300 giây).
    *   *Pro Tier (`tenant-payment`):* Tối đa 30 requests/phút, Cooldown 3 phút (180 giây).

---

## VII. ĐỊNH NGHĨA HOÀN THÀNH CỦA MỘT TÍNH NĂNG (DEFINITION OF DONE - DoD)

Một ticket/tính năng chỉ được phép coi là hoàn thành (Done) khi đáp ứng đầy đủ:
- [ ] **IaC/Code quality:** Chạy `terraform fmt` không bị đổi file, `terraform validate` pass sạch. Code Python không có lỗi từ `ruff`.
- [ ] **Security Verified:** Không có AWS credentials/secrets hardcode trong code. Gitleaks chạy local không phát hiện lỗi.
- [ ] **Independent Tested:** Có unit test chạy pass với tỉ lệ coverage $\ge 70\%$.
- [ ] **E2E Dry-run Success:** Module được plan thành công trên GitHub Actions PR, không bị lỗi phân quyền OIDC hay thiếu KMS policy.
- [ ] **Approved & Merged:** PR được approve bởi 2 reviewer khác và được Tech Lead merge qua Squash & Merge.

---

## VIII. LỘ TRÌNH REFACTOR THƯ MỤC INFRA CŨ (CHO SUB-TEAM 1 & 2)

Thư mục `infra/` cũ (Single-State) sẽ được giữ lại làm mã nguồn tham khảo và tiến hành refactor theo các bước sau để chuyển đổi sang mô hình Multi-State SDLC mới:

### 1. Phân tách Single-State thành các Module hạ tầng độc lập (Sub-team 1 thực hiện):
*   Tạo các thư mục môi trường tương ứng dưới `infra/environments/sandbox/`:
    *   `networking/`: Chứa file `main.tf`, `variables.tf`, `outputs.tf` cấu hình VPC, subnets, route tables, KMS keys và Security Groups.
    *   `compute/`: Chứa cấu hình EKS Cluster, Karpenter IAM Roles, NodeGroups. Sử dụng `terraform_remote_state` để đọc output `vpc_id` và `subnet_ids` từ `networking`.
    *   `services/`: Chứa cấu hình Helm/Kubernetes provider để cài đặt Karpenter NodePool, AWS Load Balancer Controller, ADOT, Prometheus. Sử dụng `terraform_remote_state` để đọc output từ `compute`.
*   Mỗi thư mục trên phải định cấu hình một file `backend.tf` riêng biệt trỏ đến S3 Key độc lập trên S3 bucket `tf-3-aiops-audit-trail` để chia nhỏ Blast Radius.

### 2. Di chuyển các Manifests và App code (Sub-team 2 & 3 thực hiện):
*   **App Code:** Chuyển toàn bộ code Python, Dockerfile, `requirements.txt` trong `infra/manifests/webhook-receiver/` ra một thư mục ứng dụng độc lập bên ngoài (ví dụ: `<root>/app/webhook-receiver/`) để phục vụ CI build image.
*   **Kubernetes Manifests:** Chuyển toàn bộ file YAML cấu hình K8s (`k8s.yaml`, NetworkPolicies, Kyverno rules) từ `infra/manifests/` sang thư mục `<root>/gitops/` để ArgoCD quản lý.
---

## 🔒 Quy trình Mirror Container Images thủ công lên ECR Private (Hardcore NAT-less)

Dự án CDO-01 tuân thủ nghiêm ngặt mô hình **NAT-less VPC** (Zero Internet Path). Toàn bộ container images phục vụ EKS Addons (ALBC, Karpenter, Kyverno, Prometheus Operator Stack) và Ứng dụng phải được **tải tay (pull/tag/push)** lên AWS ECR Private của dự án. Không sử dụng NAT Gateway.

### 1. Danh sách Docker Images bắt buộc phải Mirror (Target Registry: `544011261607.dkr.ecr.us-east-1.amazonaws.com`)

| Tên Service | Image Gốc (Public Registry) | Image Đích (ECR Private Override) |
|---|---|---|
| **AWS Load Balancer Controller** | `602401143452.dkr.ecr.us-west-2.amazonaws.com/amazon/aws-load-balancer-controller:v2.8.1` | `544011261607.dkr.ecr.us-east-1.amazonaws.com/amazon/aws-load-balancer-controller:v2.8.1` |
| **Karpenter Controller** | `public.ecr.aws/karpenter/controller:v0.37.0` | `544011261607.dkr.ecr.us-east-1.amazonaws.com/karpenter/controller:v0.37.0` |
| **Prometheus Operator** | `quay.io/prometheus-operator/prometheus-operator:v0.74.0` | `544011261607.dkr.ecr.us-east-1.amazonaws.com/prometheus-operator/prometheus-operator:v0.74.0` |
| **Prometheus Server** | `quay.io/prometheus/prometheus:v2.52.0` | `544011261607.dkr.ecr.us-east-1.amazonaws.com/prometheus/prometheus:v2.52.0` |
| **Alertmanager** | `quay.io/prometheus/alertmanager:v0.27.0` | `544011261607.dkr.ecr.us-east-1.amazonaws.com/prometheus/alertmanager:v0.27.0` |
| **Grafana** | `docker.io/grafana/grafana:10.4.3` | `544011261607.dkr.ecr.us-east-1.amazonaws.com/grafana/grafana:10.4.3` |
| **Kube State Metrics** | `registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.12.0` | `544011261607.dkr.ecr.us-east-1.amazonaws.com/kube-state-metrics/kube-state-metrics:v2.12.0` |
| **Node Exporter** | `quay.io/prometheus/node-exporter:v1.8.1` | `544011261607.dkr.ecr.us-east-1.amazonaws.com/prometheus/node-exporter:v1.8.1` |
| **K8s Sidecar (Grafana Config)** | `quay.io/kiwigrid/k8s-sidecar:1.27.4` | `544011261607.dkr.ecr.us-east-1.amazonaws.com/kiwigrid/k8s-sidecar:1.27.4` |
| **Kyverno Controller** | `ghcr.io/kyverno/kyverno:v1.12.5` | `544011261607.dkr.ecr.us-east-1.amazonaws.com/kyverno/kyverno:v1.12.5` |
| **Kyverno Pre-install** | `ghcr.io/kyverno/kyvernopre:v1.12.5` | `544011261607.dkr.ecr.us-east-1.amazonaws.com/kyverno/kyvernopre:v1.12.5` |
| **Kyverno Background** | `ghcr.io/kyverno/background-controller:v1.12.5` | `544011261607.dkr.ecr.us-east-1.amazonaws.com/kyverno/background-controller:v1.12.5` |
| **Kyverno Cleanup** | `ghcr.io/kyverno/cleanup-controller:v1.12.5` | `544011261607.dkr.ecr.us-east-1.amazonaws.com/kyverno/cleanup-controller:v1.12.5` |
| **Kyverno Reports** | `ghcr.io/kyverno/reports-controller:v1.12.5` | `544011261607.dkr.ecr.us-east-1.amazonaws.com/kyverno/reports-controller:v1.12.5` |

### 2. Lệnh thực hiện "Tải tay" & Quản lý Phân Vai (Run locally with Internet access)

*   **Vị trí file script:** Toàn bộ logic chạy tự động hóa pull/push và auto-create ECR private repository được lưu tại tệp: `capstone/tf-3/cdo-1/gitops/mirror-images.sh`.
*   **Thành viên chịu trách nhiệm thực thi:**
    *   **Sub-team 3 — Member 8 & 9 (Observability, Audit & QA Lead):** Chịu trách nhiệm kéo, quét bảo mật qua Trivy, và push các images thuộc nhóm Observability (Prometheus Stack), Kyverno, Stress-NG (Chaos), Alpine/BusyBox.
    *   **Sub-team 1 — Member 3 (Compute Cluster & Ingress Lead):** Chịu trách nhiệm push images ALB Controller và Karpenter Controller phục vụ bootstrap hạ tầng ban đầu.
*   **Cách thức thực hiện:**
    1. Đảm bảo AWS CLI local đã cấu hình đúng credentials có quyền Admin/PowerUser ECR.
    2. Cấp quyền và chạy file script:
       ```bash
       chmod +x capstone/tf-3/cdo-1/gitops/mirror-images.sh
       ./capstone/tf-3/cdo-1/gitops/mirror-images.sh
       ```
    3. Script sẽ tự tạo 19 ECR Private Repositories, pull ảnh public, tag và đẩy lên registry `544011261607.dkr.ecr.us-east-1.amazonaws.com` theo đúng cấu trúc.


### 3. Phương án Tự động hóa Dài hạn qua GitHub Actions (GitHub-to-ECR Mirroring Pipeline)

Để loại bỏ các rủi ro vận hành thủ công (lỗi gõ phím, quên quét Trivy, nghẽn tiến độ của DEV), dự án áp dụng phương án xây dựng **Mirroring Pipeline tự động** chạy trên GitHub Actions.

*   **Nguyên lý hoạt động:**
    1.  Danh sách ảnh cần mirror được quản lý tập trung tại file text cấu hình: `capstone/tf-3/cdo-1/gitops/mirror-list.txt`.
    2.  Khi có nhu cầu bổ sung hoặc cập nhật phiên bản image, thành viên chỉ cần tạo Pull Request sửa đổi file `mirror-list.txt` $ightarrow$ Kích hoạt GitHub Actions Workflow `mirror-pipeline.yml`.
    3.  Workflow sẽ tự động kéo ảnh từ Internet public, chạy scan lỗ hổng bằng Trivy, đăng nhập AWS ECR thông qua IAM OIDC Role (`github-ci-apply`), tự động tạo repo đích nếu chưa có và push ảnh lên.

*   **Mẫu cấu hình GitHub Actions Workflow (`.github/workflows/mirror-pipeline.yml`):**
    ```yaml
    name: Auto Container Image Mirroring to ECR Private

    on:
      push:
        branches: [ main ]
        paths:
          - 'capstone/tf-3/cdo-1/gitops/mirror-list.txt'
      workflow_dispatch: # Cho phép trigger thủ công khi cần

    permissions:
      id-token: write # Bắt buộc để authenticate OIDC IAM Role
      contents: read

    jobs:
      mirror-images:
        runs-on: ubuntu-latest
        steps:
          - name: Checkout Code
            uses: actions/checkout@v4

          - name: Configure AWS Credentials (OIDC)
            uses: aws-actions/configure-aws-credentials@v4
            with:
              role-to-assume: arn:aws:iam::544011261607:role/tf3-cdo1-sandbox-github-ci-apply
              aws-region: us-east-1

          - name: Login to AWS ECR
            id: login-ecr
            uses: aws-actions/amazon-ecr-login@v2

          - name: Read, Scan & Mirror Images
            run: |
              REGISTRY="${{ steps.login-ecr.outputs.registry }}"
              while IFS= read -r line || [ -n "$line" ]; do
                # Bỏ qua dòng trống hoặc comment bắt đầu bằng #
                [[ -z "$line" || "$line" =~ ^# ]] && continue
                
                # Cấu trúc dòng: public_source_image target_path
                # Ví dụ: ghcr.io/kyverno/kyverno:v1.12.5 kyverno/kyverno:v1.12.5
                src_img=$(echo "$line" | awk '{print $1}')
                dest_path=$(echo "$line" | awk '{print $2}')
                repo_name=$(echo "$dest_path" | cut -d':' -f1)
                
                echo "========================================================"
                echo "🔄 Kéo ảnh public: $src_img"
                docker pull "$src_img"
                
                echo "🛡️ Quét lỗ hổng bảo mật bằng Trivy..."
                # Chạy Trivy scan (tạm thời để cảnh báo, có thể cấu hình fail build nếu có lỗi Critical)
                # trivy image --severity HIGH,CRITICAL --exit-code 1 "$src_img"
                
                echo "📦 Đảm bảo AWS ECR Repository tồn tại: $repo_name"
                aws ecr describe-repositories --repository-name "$repo_name" --region us-east-1 >/dev/null 2>&1 ||                   aws ecr create-repository \
                    --repository-name "$repo_name" \
                    --region us-east-1 \
                    --image-scanning-configuration scanOnPush=true \
                    --encryption-configuration encryptionType=AES256
                    
                echo "🏷️ Gắn tag ECR Private: ${REGISTRY}/${dest_path}"
                docker tag "$src_img" "${REGISTRY}/${dest_path}"
                
                echo "🚀 Đẩy ảnh lên ECR Private..."
                docker push "${REGISTRY}/${dest_path}"
                echo "✅ Hoàn thành mirror: $repo_name"
              done < capstone/tf-3/cdo-1/gitops/mirror-list.txt
    ```

---

### 4. Cách sử dụng Container Images trên cụm EKS NAT-less

Sau khi ảnh đã được đẩy lên ECR Private, các team thực hiện khai báo sử dụng như sau:

*   **Không cần `imagePullSecrets`:** EKS Node Group đã được Sub-team 1 gán sẵn IAM Role có policy `AmazonEC2ContainerRegistryReadOnly`. Do đó EKS tự động kéo ảnh từ ECR Private mà không cần khai báo credentials gì thêm.
*   **Với App Manifest (Sub-team 2):** Thay đổi trường `image` trỏ thẳng về ECR Private kèm commit tag:
    `image: 544011261607.dkr.ecr.us-east-1.amazonaws.com/webhook-receiver:<commit-sha>`
*   **Với Helm Charts (Sub-team 3):** Ghi đè tham số Registry trong file `values.yaml`:
    ```yaml
    global:
      imageRegistry: "544011261607.dkr.ecr.us-east-1.amazonaws.com"
    ```
