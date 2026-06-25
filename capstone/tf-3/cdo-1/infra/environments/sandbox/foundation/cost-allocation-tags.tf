# INFRA-7 (Cost Allocation Tagging) owner: chỉ sửa file này + tags.tf của từng module.
#
# Đây là bước "activate" tag để Cost Explorer dùng được — KHÁC với việc gắn tag lên
# resource (đã làm ở tags.tf mỗi module qua local.module_tags). 2 việc đều cần,
# thiếu 1 trong 2 thì Cost Explorer vẫn không filter/group theo tag được:
#   1. Resource phải có tag (tags.tf mỗi module) — bắt buộc trước.
#   2. Tag key đó phải được "Activate" ở tài khoản (file này).
#
# Lưu ý quan trọng (đọc trước khi apply):
# - Tag key chỉ xuất hiện trong danh sách "available to activate" SAU KHI đã được
#   dùng trên ít nhất 1 resource thật, và có thể mất tới 24h để AWS nhận diện.
#   => Resource dưới đây sẽ FAIL ở lần apply đầu tiên (trước khi modules khác có
#   resource thật mang tag). Apply lại file này SAU KHI INFRA-2..INFRA-6 đã apply
#   xong và đã đợi tag propagate.
# - Nếu sandbox account nằm trong AWS Organizations (consolidated billing), việc
#   activate cost allocation tag THƯỜNG chỉ làm được từ management/payer account,
#   không phải member account. Cần IAM permission `ce:UpdateCostAllocationTagsStatus`
#   + `ce:ListCostAllocationTags`. Nếu apply bị AccessDenied → ghi thành Open
#   Question trong docs/08_adrs.md, không tự retry vô hạn.

resource "aws_ce_cost_allocation_tag" "project" {
  tag_key = "Project"
  status  = "Active"
}

resource "aws_ce_cost_allocation_tag" "task_force" {
  tag_key = "TaskForce"
  status  = "Active"
}

resource "aws_ce_cost_allocation_tag" "team" {
  tag_key = "Team"
  status  = "Active"
}

resource "aws_ce_cost_allocation_tag" "env" {
  tag_key = "Env"
  status  = "Active"
}

resource "aws_ce_cost_allocation_tag" "component" {
  tag_key = "Component"
  status  = "Active"
}
