# TODO(INFRA-2): implement theo docs/02_infra_design.md §2 (Component table)
# và docs/03_security_design.md §1.1 / §1.3 (Network Diagram, VPC Endpoint).
#
# Resource cần có:
# - aws_vpc (var.vpc_cidr)
# - aws_subnet private x len(var.azs), public x len(var.azs)
# - aws_internet_gateway (chỉ cho public subnet, không dùng cho private)
# - aws_route_table + aws_route_table_association cho private/public
# - aws_vpc_endpoint Gateway type: S3, DynamoDB
# - aws_vpc_endpoint Interface type: SQS, Kinesis Firehose, Secrets Manager, KMS,
#   CloudWatch Logs/Metrics, ECR API + ECR Docker, STS, CodeCommit Git + API, SNS
#   (danh sách đầy đủ ở docs/03_security_design.md §1.3) — gắn sg_vpc_endpoint_id
#   từ module.security khi wire ở environments/sandbox/foundation/networking.tf
#
# KHÔNG tạo NAT Gateway — sandbox cố tình không dùng (xem docs/03_security_design.md
# §1.1 "chủ động không dùng NAT Gateway cho runtime workloads").

# Cost tracking: mọi resource hỗ trợ tag PHẢI dùng `tags = local.module_tags`
# (xem tags.tf) — không dùng var.tags trực tiếp, để Cost Explorer group theo Component.
