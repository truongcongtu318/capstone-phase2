# Test & Eval Report - Task force 1 · CDO 1

  Doc owner: Nhóm CDO-01
     Status: NEW (W12 T4 Pack #2 only)
     Word target: 1000-1800 từ

Tài liệu này thiết lập khung kế hoạch kiểm thử, xác định các công cụ, kịch bản tải và các điểm chạm bảo mật nhằm đánh giá toàn diện hệ thống tự chữa lành (Self-Heal System) trên nền tảng GitOps Hybrid AWS & K8s Stack. Các thông số đo lường thực tế sẽ được cập nhật liên tục trong quá trình chạy nghiệm thu.

---

## 1. Test coverage

Hệ thống phân rã quy trình kiểm thử thành 5 cấp độ từ nhỏ đến lớn nhằm đảm bảo kiểm soát chặt chẽ phạm vi ảnh hưởng của mã nguồn và hạ tầng trước khi nghiệm thu.

| Test type | Tool | Coverage / Scope |
|---|---|---|
| **Unit test** | `pytest` | Kiểm thử logic xử lý nội bộ của Webhook Receiver (FastAPI) và các hàm tương tác của Direct Patch Engine (`kubernetes-client`). *[Cột độ phủ % sẽ cập nhật sau khi chạy]* |
| **Integration test** | `Postman` / `curl` scripts | Kiểm thử luồng phân phối tín hiệu (Tenant Provision), khả năng bọc Idempotency Lock trên DynamoDB và cơ chế đẩy tin nhắn vào mạng SQS Standard Queue. |
| **E2E test** | `k6` / Manual Shell Scripts | Kiểm thử toàn luồng theo 3 kịch bản cốt lõi: kích hoạt lỗi khẩn cấp để kích hoạt Direct Patch Engine (<15s) và kích hoạt bão alert sự cố để Argo Workflows điều phối nhánh GitOps Path. |
| **Load test** | `k6` | Thực hiện kiểm thử chịu tải ở mức 100 RPS duy trì liên tục trong 10 phút tại Entry Layer (Webhook Receiver) để giả lập bão sự cố từ môi trường SaaS. |
| **Chaos test** | `kubectl` manual injection / scripts | Giả lập 3 tình huống bất ngờ (curveball): Xóa đột ngột Webhook Pod, cô lập mạng giữa cụm EKS và AWS API, giả lập lỗi crash giữa chừng của bộ điều phối khi đang chạy dở action. |

---

## 2. SLO evidence

Bảng này định hình các mục tiêu chất lượng dịch vụ (SLO) cốt lõi bắt buộc phải đạt được, làm căn cứ để Task 8 và hội đồng đánh giá mức độ hoàn thiện của hệ thống hạ tầng SaaS lớn.

| SLO | Target | Measured | Window | Pass/Fail |
|---|---|---|---|---|
| **API availability** | ≥ 99.5% | [To be measured] | 2 weeks build period | [Pending] |
| **P99 latency (Direct Patch)** | < 15,000ms (15s) | [To be measured] | Last 24h | [Pending] |
| **Error rate** | < 0.5% | [To be measured] | Last 24h | [Pending] |
| **Tenant onboarding isolation** | < 30 min | [To be measured] | 3 test tenants | [Pending] |

### 2.1 SLO breach analysis

*(Mục này sẽ được cập nhật chi tiết nguyên nhân gốc rễ (Root Cause) và phương án khắc phục nếu hệ thống xảy ra tình trạng miss hoặc vi phạm các chỉ số SLO cam kết ở trên trong quá trình build 2 tuần).*

---

## 3. Load test results

### 3.1 Test setup

Kịch bản kiểm thử chịu tải (Load test) được thiết kế nhằm giả lập kịch bản bão cảnh báo (alert storm) xuất hiện đồng thời từ nhiều microservices của mô hình SaaS 200+ dịch vụ nhỏ để thử thách sức chịu đựng của cụm EKS Node Group và DynamoDB.

*   **Load profile**: Tăng tải tuyến tính (ramp-up) từ 0 → 100 RPS trong vòng 5 phút đầu tiên, sau đó duy trì tải (sustained) ở mức đỉnh 100 RPS liên tục trong 10 phút tiếp theo.
*   **Tenants simulated**: Giả lập 10 khách hàng doanh nghiệp lớn (concurrent tenants) đồng thời tạo ra các sự cố ngẫu nhiên để ép Webhook Receiver phải phân tách định danh.
*   **Tool**: Sử dụng công cụ mã nguồn mở `k6` (nhẹ, viết script bằng JavaScript, chạy native cực tốt trong môi trường container K8s).

### 3.2 Results

| Metric | Target | Achieved |
|---|---|---|
| RPS sustained | 100 | [To be filled] |
| P99 latency at peak | < 1500ms | [To be filled]ms |
| Error rate at peak | < 1% | [To be filled]% |
| Auto-scale triggers | scale to ≥ 5 tasks (Cluster Autoscaler) | [Pending] |

### 3.3 Bottleneck identified

*(Mục này dùng để phân tích các nút thắt cổ chai thực tế sau khi chạy tải: Giới hạn kết nối kết nối vào DynamoDB DB connection pool? AI engine throttle? Compute? Sẽ cập nhật sau).*

---

## 4. Security test

### 4.1 Penetration touch points

Danh sách các điểm chạm kiểm thử xâm nhập bảo mật mà nhóm cam kết sẽ thực hiện thử nghiệm tấn công (không cần kết quả, chỉ đánh dấu các điểm sẽ thử nghiệm theo kiến trúc thật):

*   [x] **API auth bypass attempt**: Thử nghiệm gửi alert giả mạo trực tiếp vào Internal ALB/Webhook Receiver mà không kèm mã định danh hợp lệ để xem hệ thống có từ chối hay không.
*   [x] **Cross-tenant data leak attempt**: Giả lập tài khoản của Tenant A tìm cách gọi các hàm tự chữa lành hoặc đọc log audit của Tenant B thông qua việc thay đổi metadata.
*   [x] **NoSQL injection / Parameter tampering**: Thử nghiệm chèn các chuỗi lệnh độc hại vào API payload nhằm phá hoại cấu trúc bảng khóa chống trùng lặp `Idempotency Lock` của DynamoDB.
*   [x] **IAM privilege escalation**: Thử nghiệm chiếm quyền từ một Pod bất kỳ trong cụm K8s xem có thể vượt qua Trust Boundary để assume các IAM role thao tác trên tài nguyên AWS nền hay không.
*   [x] **Secret exposure via logs**: Rà soát hệ thống ghi vết cảnh báo để đảm bảo tuyệt đối không có mã cấu hình nhạy cảm, Token hay thông tin dữ liệu của khách hàng bị rò rỉ ra các file log tĩnh trên S3.

### 4.2 Vulnerability scan

*   **Tool**: `Trivy` (Sử dụng để quét lỗ hổng bảo mật trực tiếp trên Docker Image của FastAPI container và các file cấu hình manifest K8s).
*   **CRITICAL findings**: 0 (Cam kết loại bỏ 100% lỗi nghiêm trọng trước khi nộp Pack #2).
*   **HIGH findings**: ≤ 3 với tài liệu giải trình và phương án giảm thiểu (mitigation) được phê duyệt.
*   **Report**: Đường dẫn file kết quả quét lỗ hổng dạng JSON lưu tại `<repo>/security/scan-results.json`.

---

## 5. Multi-tenant isolation test

Khung kiểm thử xác nhận cơ chế cô lập dữ liệu và định danh khách hàng. Nhóm xác nhận 4 trường hợp dưới đây hoàn toàn khớp 100% với kiến trúc hạ tầng đa thuê thuê (Multi-tenancy) thực tế của nhóm:

| Test | Method | Result |
|---|---|---|
| **Tenant A reads Tenant B data via API** | Sử dụng mã Token hợp lệ của Tenant A để gửi request truy cập vào tài nguyên hoặc gọi hành động khắc phục lỗi của Tenant B. | ❌ Mặc định phải fail với mã lỗi **403 Forbidden** ở tầng Webhook. |
| **Tenant A IAM role accesses B's S3 prefix** | Sử dụng quyền truy cập được cấp phát cho Tenant A để cố tình đọc/ghi file log tĩnh vào thư mục tiền tố (S3 prefix) đã được khóa cứng bằng Object Lock của Tenant B. | ❌ Hệ thống AWS IAM Policy và S3 Bucket Policy phải từ chối quyền truy cập công khai này. |
| **Cross-tenant queue contamination** | Tenant A cố tình tạo ra một thông điệp lỗi lặp lại nhưng cố tình chèn mã định danh `tenant_id` của Tenant B vào SQS Standard Queue. | ❌ Hệ thống đối chiếu dữ liệu (Audit log) phát hiện sự không khớp giữa Token ký duyệt và nội dung thông điệp, thực hiện hủy bỏ và đánh dấu vi phạm an ninh. |
| **DB row-level security (DynamoDB)** | Thực hiện một câu lệnh truy vấn dữ liệu khóa chống trùng lặp lên bảng DynamoDB nhưng cố tình bỏ trống hoặc không truyền tham số lọc theo mã khách hàng (`tenant_id`). | ❌ Cấu trúc thiết kế khóa phân vùng (Partition Key) bắt buộc trả về kết quả rỗng hoặc báo lỗi thiếu tham số phân quyền, ngăn chặn triệt để rò rỉ dữ liệu diện rộng. |

**Chiến thắng tuyệt đối:** Tất cả các bài kiểm thử trên bắt buộc phải vượt qua (Pass) 100% - bất kỳ một dấu hiệu rò rỉ dữ liệu chéo nào giữa các khách hàng doanh nghiệp đều bị tính là sự cố nghiêm trọng mức độ SEV1.

---

## 6. Failure analysis

### 6.1 Failures encountered during 2-week build

*(Bảng nhật ký ghi lại các lỗi hạ tầng lớn mà nhóm gặp phải trong suốt 2 tuần triển khai thực tế, cách xử lý và thời gian khôi phục để chứng minh tính thực tế của dự án).*

| # | Failure | Root cause | Fix | Time to fix |
|---|---|---|---|---|
| 1 | *[Ví dụ: Lỗi phân quyền EKS CNI]* | *[To be updated]* | *[To be updated]* | *X hours* |

### 6.2 Test gaps acknowledged

*(Ghi nhận trung thực các điểm hệ thống chưa thể kiểm thử triệt để do giới hạn về mặt thời gian 2 tuần hoặc do môi trường Sandbox giới hạn tài nguyên).*

*   **Gap 1**: Chưa thực hiện tải kiểm thử vượt ngưỡng giới hạn của AWS Auto Scaling Group (chưa test kịch bản quá 5 node m5.large do giới hạn ngân sách $200).
*   **Gap 2**: Việc giả lập mất kết nối hoàn toàn một phân vùng AWS Region (Multi-region failure) chưa được thực hiện, mới chỉ dừng lại ở mức phá hủy tài nguyên trong một Availability Zone (AZ).

---

## Related documents

*   [`02_infra_design.md`](02_infra_design.md) - Chỉ số cam kết mục tiêu chất lượng SLO được xác thực tại §3 của tài liệu này[cite: 1].
*   [`03_security_design.md`](03_security_design.md) §14 - Danh mục quản trị rủi ro hệ thống được giảm thiểu trực tiếp bởi kết quả kiểm thử an ninh tại §6 của tài liệu này[cite: 1].
*   [`../../ai/docs/04_eval_report.md`](../../ai/docs/04_eval_report.md) - Tài liệu phối hợp kiểm thử chung: Đo lường chất lượng xử lý của AI Engine kết hợp với năng lực phản hồi hạ tầng của CDO[cite: 1].