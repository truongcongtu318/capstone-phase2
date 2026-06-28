# Cost Explorer cần phân biệt chi phí theo Component → mỗi module merge thêm
# tag "Component" riêng, KHÔNG sửa key của global_tags (Project/TaskForce/Team/Env/ManagedBy)
locals {
  module_tags = merge(var.global_tags, {
    Component = "ingress"
  })
}
