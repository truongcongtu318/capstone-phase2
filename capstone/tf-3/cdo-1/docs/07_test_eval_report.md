# Test & Eval Report - Task force 1 · CDO 1

Tài liệu này thiết lập khung kế hoạch và các kịch bản kiểm thử toàn diện đối với hệ thống tự chữa lành (Self-Heal Engine) vận hành trên nền tảng GitOps Hybrid AWS & Karpenter Stack. Kế hoạch này được thiết kế để kiểm tra giới hạn chịu tải, ranh giới an toàn an ninh và khả năng cô lập đa thuê thuê nhằm đáp ứng bối cảnh nền tảng SaaS B2B lớn (200+ microservices, 120 khách hàng doanh nghiệp và 12TB dữ liệu).

---

## 1. Test coverage

Hệ thống phân rã quy trình kiểm thử thành 5 cấp độ độc lập nhằm kiểm soát chặt chẽ phạm vi ảnh hưởng (blast radius) của mã nguồn và hạ tầng trước khi nghiệm thu.

| Test type | Tool | Coverage / Scope |
|---|---|---|
| **Unit test** | `pytest` | Kiểm thử logic xử lý nội bộ của Webhook Receiver (FastAPI), module Regex ẩn danh hóa thông tin nhạy cảm và các hàm gọi API client nội bộ cụm. *[Mức % độ phủ sẽ được cập nhật sau]* |
| **Integration test** | `Postman` / `curl` | Kiểm thử luồng phân phối tín hiệu hệ thống (Tenant Provisioning flow), khả năng tương tác với các endpoint hợp đồng của AI Engine (`/detect`, `/decide`, `/v1/verify`), cơ chế bọc trạng thái sự cố trên DynamoDB State Machine và đẩy luồng log vào Kinesis Data Firehose. |
| **E2E test** | Custom Shell Scripts / `kubectl` | Kiểm thử toàn luồng (Happy Path) cho các kịch bản xử lý tự động khắc phục lỗi: <br>1. Sự cố khẩn cấp Loại 1 (Pod OOMKilled/Service stuck) $\rightarrow$ Direct Patch can thiệp tức thời. <br>2. Sự cố Loại 2 (Queue backlog/Config change) $\rightarrow$ Kích hoạt luồng GitOps thông qua Argo Workflows điều phối. <br>3. Sự cố quá ngưỡng $\rightarrow$ Engine bỏ cuộc $\rightarrow$ Emit AI-generated message đính kèm full context bundle lên mock pager (Slack Webhook). |
| **Load test** | `k6` | Thực hiện kiểm thử áp lực lớn (100 RPS duy trì liên tục trong 10 phút) trực tiếp vào Entry Layer (Application Load Balancer và Webhook Receiver) để giả lập bão sự cố. |
| **Chaos test** | Manual Injection Scripts | Giả lập 3 kịch bản sự cố bất ngờ (curveball scenarios): <br>1. Phá hủy đột ngột Pod của Webhook Receiver khi đang nhận tín hiệu cảnh báo. <br>2. Đột ngột ngắt kết nối mạng giữa cụm EKS và AWS API (Cô lập control plane). <br>3. Controller của bộ điều phối (Orchestrator) bị crash đột ngột khi đang thực thi dở một hành động tự chữa lành. |

---

## 2. SLO evidence

Bảng mục tiêu chất lượng dịch vụ (SLO) dưới đây đặt ra các tiêu chí kiểm định hiệu năng và tính ổn định bắt buộc, làm bằng chứng nghiệm thu cho kỳ đánh giá kết quả hạ tầng sandbox.

| SLO | Target | Measured | Window | Pass/Fail |
|---|---|---|---|---|
| **API availability** | ≥ 99.5% | [To be measured]% | 2 weeks build period | [Pending] |
| **P99 Execution Latency (Direct Patch)** | < 15,000ms (15s) | [To be measured]ms | Last 24h | [Pending] |
| **Error rate** | < 0.5% | [To be measured]% | Last 24h | [Pending] |
| **Tenant onboarding isolation** | < 30 min | [To be measured] min | 3 test tenants | [Pending] |

### 2.1 SLO breach analysis

*(Mục này dùng để ghi vết và phân tích nguyên nhân gốc rễ (Root Cause Analysis) nếu hệ thống ghi nhận bất kỳ sự vi phạm hoặc không đạt được mục tiêu cam kết nào đối với các chỉ số SLO nêu trên trong suốt giai đoạn chạy thử nghiệm).*

---

## 3. Load test results

### 3.1 Test setup

Kịch bản kiểm thử chịu tải (Load test) được thiết kế có chủ đích nhằm giả lập tình huống bão cảnh báo (alert storm) xuất hiện đồng loạt từ 200+ microservices trên hệ thống SaaS của client khi bị nghẽn tải phần cứng.

- **Load profile**: Tăng tải tuyến tính (ramp-up) từ 0 → 100 RPS trong vòng 5 phút đầu tiên, sau đó duy trì mức tải đỉnh ổn định (sustained) ở mức 100 RPS liên tục trong vòng 10 phút tiếp theo.
- **Tenants simulated**: Giả lập 10 khách hàng doanh nghiệp lớn (concurrent tenants) tạo tải và gửi dữ liệu cảnh báo sự cố chéo nhau tại cùng một thời điểm.
- **Tool**: Sử dụng công cụ mã nguồn mở `k6` để thực thi viết script kiểm thử chịu tải.

### 3.2 Results

| Metric | Target | Achieved |
|---|---|---|
| RPS sustained | 100 | [To be filled] |
| P99 latency at peak | < 1500ms | [To be filled]ms |
| Error rate at peak | < 1% | [To be filled]% |
| Auto-scale triggers | scale to ≥ 5 tasks / EC2 instances | [Pending] (Kiểm tra tín hiệu Karpenter mở rộng node tự động) |

### 3.3 Bottleneck identified

*(Mục này dùng để phân tích và chỉ mặt điểm tên các nút thắt cổ chai phần cứng thực tế sau khi ép tải hệ thống: Giới hạn kết nối của RDS PostgreSQL connection pool? Giới hạn throughput của DynamoDB? Tốc độ cấp phát node của Karpenter bị nghẽn? Sẽ cập nhật chi tiết sau khi có số liệu).*

---

## 4. Security test

### 4.1 Penetration touch points

Danh sách các điểm chạm thử nghiệm tấn công xâm nhập bảo mật (Penetration Test) mà nhóm cam kết thực hiện kiểm thử trên môi trường hạ tầng thực tế để bảo vệ an toàn cho hệ thống:

- [ ] **☐ API auth bypass attempt**: Thử nghiệm gửi dữ liệu alert giả mạo trực tiếp vào Ingress ALB mà không đính kèm mã xác thực Token hợp lệ để kiểm tra bộ lọc bảo mật ngắt kết nối.
- [ ] **☐ Cross-tenant data leak attempt**: Thử nghiệm giả lập tài khoản của Tenant A thay đổi tham số metadata để cố tình truy cập trái phép vào luồng xử lý hoặc xem dữ liệu cấu hình của Tenant B.
- [ ] **☐ NoSQL injection / Parameter tampering**: Thử nghiệm chèn mã độc vào API payload gửi về nhằm phá hoại cấu trúc bảng lưu trạng thái của DynamoDB và vượt qua bộ khóa chống trùng lặp `Idempotency Lock`.
- [ ] **☐ IAM privilege escalation**: Thử nghiệm từ một Pod bất kỳ trong cụm K8s tìm cách chiếm quyền, vượt qua Trust Boundary thông qua lỗ hổng IRSA để thao tác trái phép trên các tài nguyên cốt lõi của AWS (như RDS hay Secrets Manager).
- [ ] **☐ Secret exposure via logs**: Rà soát triệt để hệ thống log stream để chứng minh không có thông tin nhạy cảm nào (Email, Token, Database credentials) bị rò rỉ ra các file log tĩnh lưu tại S3.

### 4.2 Vulnerability scan

- **Tool**: `Trivy` (Sử dụng để quét lỗ hổng bảo mật trực tiếp trên Docker Image và các file manifest K8s trước khi triển khai).
- **CRITICAL findings**: 0 (Bắt buộc phải xóa bỏ hoàn toàn lỗ hổng nghiêm trọng trước khi nộp sản phẩm Pack #2).
- **HIGH findings**: ≤ 3 với đầy đủ tài liệu giải trình và giải pháp giảm thiểu rủi ro (mitigation plan) được phê duyệt.
- **Report**: Kết quả quét bảo mật được xuất thành file JSON lưu trữ tại thư mục `<repo>/security/scan-results.json`.

---

## 5. Multi-tenant isolation test

Kiểm thử tính cô lập đa thuê thuê nhằm ngăn chặn triệt để rủi ro rò rỉ dữ liệu giữa các khách hàng doanh nghiệp doanh nghiệp lớn, tuân thủ nghiêm ngặt quy định an toàn hệ thống.

| Test | Method | Result |
|---|---|---|
| **Tenant A reads Tenant B data via API** | Sử dụng mã Token/định danh hợp lệ của Tenant A để gửi request truy cập vào tài nguyên hoặc xem trạng thái sự cố của Tenant B. | ❌ Hệ thống bắt buộc phải từ chối truy cập và trả về mã lỗi **403 Forbidden**. |
| **Tenant A IAM role accesses B's S3 prefix** | Thao tác lệnh sử dụng IAM Role được phân quyền cho Tenant A để cố tình đọc/ghi file vào vùng tiền tố (S3 Prefix) riêng tư của Tenant B trên S3 Bucket. | ❌ Hệ thống AWS IAM và S3 Bucket Policy bắt buộc phải từ chối hành động (Access Denied). |
| **Cross-tenant queue contamination** | Tenant A cố tình tạo và gửi một thông điệp lỗi lặp lại nhưng chèn mã `tenant_id` của Tenant B vào SQS Standard Queue. | ❌ Hệ thống kiểm toán (Kinesis Firehose + Audit Log) phát hiện sự không trùng khớp định danh, tiến hành hủy bỏ thông điệp lặp và ghi vết cảnh báo. |
| **DB row-level security (RDS/DynamoDB)** | Thực hiện các câu lệnh truy vấn dữ liệu thô (Query/Scan) lên RDS PostgreSQL hoặc bảng DynamoDB nhưng cố tình bỏ trống bộ lọc khách hàng `tenant_id`. | ❌ Cấu trúc khóa phân vùng (Partition Key) và RBAC bắt buộc phải trả về kết quả rỗng hoặc báo lỗi thiếu quyền, ngăn chặn rò rỉ dữ liệu. |

**Cam kết tuyệt đối:** Tất cả các bài kiểm thử cô lập đa thuê thuê bắt buộc phải vượt qua (Pass) 100% - bất kỳ một hành vi rò rỉ dữ liệu chéo (data leak) nào giữa các khách hàng đều bị tính là sự cố an ninh nghiêm trọng mức độ SEV1.

---

## 6. Failure analysis

### 6.1 Failures encountered during 2-week build

Bảng ghi vết toàn bộ các sự cố lớn về hạ tầng phần cứng mà đội ngũ gặp phải trong suốt 2 tuần triển khai dự án thực tế, làm bằng chứng cho tính thực tế và minh bạch của sản phẩm hạ tầng.

| # | Failure | Root cause | Fix | Time to fix |
|---|---|---|---|---|
| 1 | [To be updated] | [To be updated] | [To be updated] | [To be filled] hours |
| 2 | [To be updated] | [To be updated] | [To be updated] | [To be filled] hours |

### 6.2 Test gaps acknowledged

Ghi nhận trung thực các điểm giới hạn mà hệ thống chưa thể kiểm thử toàn diện do ràng buộc về mặt thời gian 2 tuần hoặc giới hạn tài nguyên của môi trường Sandbox.

- **Gap 1**: Chưa thực hiện kiểm thử chịu tải vượt ngưỡng giới hạn tối đa của cụm Karpenter Provisioner (chưa ép tải lên mốc phá hủy hệ thống phần cứng do giới hạn ngân sách sandbox $200).
- **Gap 2**: Việc giả lập kịch bản mất kết nối hoàn toàn một phân vùng (Multi-region failure) chưa được thực thi, các kịch bản hỗn loạn mới chỉ dừng lại ở mức phá hủy tài nguyên trong một Availability Zone (AZ) cụ thể.

---

## Related documents

- [`02_infra_design.md`](02_infra_design.md) - Các chỉ số cam kết mục tiêu chất lượng dịch vụ (SLO targets) được định nghĩa và xác thực trong mục §3 của tài liệu này.
- [`03_security_design.md`](03_security_design.md) §14 - Danh mục quản trị và giảm thiểu rủi ro hệ thống (Risk registry) được bảo vệ bởi kết quả kiểm thử an ninh tại mục §6 của tài liệu này.
- [`../../ai/docs/04_eval_report.md`](../../ai/docs/04_eval_report.md) - Tài liệu phối hợp kiểm thử chung: Đo lường chất lượng xử lý của AI Engine kết hợp với năng lực tích hợp hạ tầng của nhóm CDO.