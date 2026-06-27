# ==============================================================================
# INFRA-7: Cost Allocation Tagging Kích Hoạt Biến Gộp Chi Phí
# Owner: Only modify this file and tags.tf of each module.
# ==============================================================================

# Lưu ý quan trọng: Tài nguyên này có thể báo lỗi ở lần apply đầu tiên nếu AWS chưa 
# ghi nhận các tag key này xuất hiện trên tài nguyên thật (quá trình propagate mất tới 24h).
# Nếu bị AccessDenied do giới hạn tài khoản AWS Organizations, ghi nhận thành Open Question tại 08_adrs.md.

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