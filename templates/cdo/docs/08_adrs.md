# Architecture Decision Records - CDO <M> · Task force <N>

<!-- Doc owner: <Nhóm CDO>
     Status: Ongoing log W11-W12
     Format: 1 ADR per major decision. Append-only - không xóa ADR cũ. -->

> **ADR là gì**: Architecture Decision Record. File log mỗi quyết định kiến trúc quan trọng + lý do tại sao chọn cái đó (chứ không phải mấy phương án khác). Mục đích: 6 tháng sau quay lại codebase vẫn nhớ "à hồi đó chọn X vì Y, không phải vì tôi thích".
>
> **Khi nào viết ADR**:
> - Decision có **trade-off thật** (chọn X có cost, chọn Y có benefit).
> - Decision **reversal cost cao** (vd đổi compute target = rebuild infra).
> - Decision có thể bị hỏi "sao chọn vậy?" trong Individual Defense buổi chấm.
>
> **KHÔNG cần ADR cho**: chuyện nhỏ không có trade-off (tên resource, naming convention, vv).
>
> **Khi 1 ADR cũ không còn áp dụng**: đánh dấu `Status: Superseded by ADR-NNN`, KHÔNG xóa ADR cũ. Append-only.

**Target**: ≥3 ADR cho Pack #1 (W11) · ≥5 ADR cho Pack #2 (W12).

**Ví dụ topic cần ADR (Nhóm CDO)**:
- Infra angle pick (serverless / K8s / streaming / lakehouse / managed observability)
- Compute target (Lambda vs ECS Fargate vs EKS)
- Data storage (DynamoDB vs RDS vs S3+Athena)
- CI/CD strategy (GitHub Actions vs CodePipeline, canary vs blue-green)
- Observability stack (Prometheus+Grafana vs CloudWatch native)
- Security baseline (IAM scope, secrets injection pattern, network isolation)
- Cost trade-off (Reserved Instance vs On-demand cho demo)

---

## ADR-001 - Argo Workflows over AWS Step Functions for GitOps Orchestration

* **Status**: Accepted

* **Date**: 2026-06-24

* **Context**:

Self-Heal Engine cần một thành phần điều phối để quản lý các quy trình xử lý sự cố theo nhiều bước như Detect → Decide → Execute → Verify → Rollback. Nhóm đã cân nhắc sử dụng AWS Step Functions hoặc Argo Workflows.

Ban đầu Step Functions được đánh giá cao vì dễ quản lý state và retry từ bên ngoài cluster. Tuy nhiên sau khi phân tích luồng GitOps, nhóm nhận thấy các thay đổi cấu hình sẽ được thực hiện thông qua Git và ArgoCD, nghĩa là bộ điều phối không cần trực tiếp truy cập Kubernetes API. Việc đặt orchestration bên ngoài cluster không còn mang lại nhiều lợi ích bảo mật như dự kiến ban đầu.

Ngoài ra, nhóm xác nhận đã có thành viên từng làm việc với Argo Workflows nên rủi ro học công nghệ mới được giảm đáng kể.

* **Decision**:

Chọn Argo Workflows làm orchestration engine cho các workflow GitOps thay vì AWS Step Functions.

* **Consequence**:

  * ✅ Retry, timeout và workflow state được hỗ trợ sẵn.
  * ✅ Toàn bộ orchestration nằm trong cùng Kubernetes ecosystem với ArgoCD và Self-Heal Engine.
  * ✅ Có giao diện trực quan giúp theo dõi từng bước xử lý sự cố khi demo.
  * ✅ Giảm nhu cầu cấu hình bridge giữa AWS IAM và Kubernetes RBAC.
  * ⚠️ Argo Controller phải chạy liên tục trong cluster nên phát sinh chi phí cố định.
  * ⚠️ Nhóm cần quản lý thêm CRD và workflow YAML.

* **Alternatives considered**:

  * **Option A – AWS Step Functions + Lambda**

    * Ưu điểm: Pay-per-use, không tốn chi phí khi không có incident, state management tốt.
    * Nhược điểm: Tạo thêm một trust boundary giữa AWS và Kubernetes, cần quản lý IAM và credential phức tạp hơn.
    * Rejected vì lợi ích bảo mật không còn đáng kể sau khi áp dụng GitOps với ArgoCD.

  * **Option B – Argo Workflows**

    * Ưu điểm: Native Kubernetes, tích hợp tốt với ArgoCD, có workflow UI.
    * Nhược điểm: Có chi phí vận hành cố định.
    * Chosen.

## ADR-002 - In-Cluster Direct Patch Engine for Critical Incidents

* **Status**: Accepted

* **Date**: 2026-06-24

* **Context**:

Một trong các mục tiêu chính của Self-Heal Engine là giảm thời gian phản hồi đối với các sự cố phổ biến như Pod OOMKilled hoặc Service Stuck. Những sự cố này thường chỉ cần một hành động đơn giản như restart deployment hoặc patch resource limit để khôi phục dịch vụ.

Nhóm đã cân nhắc giữa việc xử lý trực tiếp bên trong Kubernetes cluster hoặc triển khai một thành phần bên ngoài cluster (AWS Lambda) để gọi ngược vào Kubernetes API.

Với yêu cầu phản hồi nhanh và phạm vi chỉ là sandbox cluster cho capstone, việc đưa logic xử lý vào ngay trong cluster giúp đơn giản hóa kiến trúc và giảm số lượng thành phần cần vận hành.

* **Decision**:

Triển khai Direct Patch Engine dưới dạng Python module chạy cùng Pod với Webhook Receiver và sử dụng Kubernetes Python Client để thực hiện các hành động remediation.

* **Consequence**:

  * ✅ Giảm độ trễ do không cần đi qua nhiều lớp mạng trung gian.
  * ✅ Không cần quản lý kubeconfig hoặc credential truy cập cluster từ bên ngoài.
  * ✅ Kiến trúc đơn giản hơn, phù hợp với thời gian triển khai 2 tuần.
  * ✅ Dễ tích hợp với RBAC và ServiceAccount nội bộ của cluster.
  * ⚠️ Direct Patch Engine phụ thuộc vào lifecycle của Webhook Receiver.
  * ⚠️ Khó scale độc lập nếu workload tăng mạnh trong tương lai.

* **Alternatives considered**:

  * **Option A – AWS Lambda gọi EKS API**

    * Ưu điểm: Scale độc lập, tách biệt khỏi cluster.
    * Nhược điểm: Cần cấu hình IAM, IRSA và quản lý credential phức tạp hơn.
    * Rejected vì chi phí triển khai và vận hành không tương xứng với phạm vi capstone.

  * **Option B – In-Cluster Python Module**

    * Ưu điểm: Đơn giản, độ trễ thấp, tận dụng ServiceAccount nội bộ.
    * Nhược điểm: Coupling với Webhook Receiver.
    * Chosen.

---

## ADR-003 - ArgoCD as GitOps Controller

* **Status**: Accepted

* **Date**: 2026-06-24

* **Context**:

Một số loại remediation không phù hợp để patch trực tiếp vào Kubernetes vì liên quan đến cấu hình hoặc số lượng replica cần được quản lý lâu dài. Nếu chỉ patch trực tiếp, trạng thái thực tế của cluster sẽ khác với trạng thái được lưu trong Git và dễ bị ghi đè ở lần deploy tiếp theo.

Nhóm cần một cơ chế đảm bảo Git luôn là nguồn dữ liệu chính (Source of Truth) và mọi thay đổi đều có lịch sử rõ ràng để phục vụ audit.

* **Decision**:

Sử dụng ArgoCD làm GitOps Controller để đồng bộ trạng thái từ Git Repository vào Kubernetes Cluster.

* **Consequence**:

  * ✅ Git trở thành nguồn dữ liệu chính cho mọi thay đổi.
  * ✅ Có lịch sử commit giúp truy vết nguyên nhân thay đổi.
  * ✅ Hỗ trợ rollback thông qua Git.
  * ✅ Giao diện ArgoCD trực quan và phù hợp cho demo.
  * ✅ Dễ triển khai mô hình multi-tenant bằng Application-per-Tenant.
  * ⚠️ Phát sinh thêm thành phần cần vận hành trong cluster.
  * ⚠️ Một số thay đổi cần thời gian sync nên không nhanh bằng patch trực tiếp.

* **Alternatives considered**:

  * **Option A – Direct Patch Everything**

    * Ưu điểm: Nhanh và đơn giản.
    * Nhược điểm: Dễ gây drift giữa Git và cluster.
    * Rejected vì không phù hợp với yêu cầu audit và GitOps.

  * **Option B – ArgoCD**

    * Ưu điểm: GitOps mature, UI tốt, rollback dễ.
    * Nhược điểm: Tăng độ phức tạp vận hành.
    * Chosen.

---


<!-- Append ADR mới ở dưới. Khi 1 ADR bị superseded, đánh dấu Status + link forward.

Suggested ADR areas (tham khảo, không bắt buộc đủ):
- Compute layer choice (Lambda vs Fargate vs EKS)
- Database choice + multi-tenant pattern (silo/pool/bridge)
- Event bus (EventBridge vs Kinesis vs MSK)
- IaC tool (Terraform vs CDK)
- GitOps tool (ArgoCD vs Flux)
- Observability stack (CloudWatch vs Grafana stack)
- Tenant isolation depth (compute level vs data level vs network level)
- Cost optimization trade-off (cold start vs always-on)
-->
