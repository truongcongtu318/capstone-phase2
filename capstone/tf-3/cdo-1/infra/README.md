# 🛠️ CDO-01 Infra Directory Structure (TODO)
This directory defines the Multi-State Infrastructure as Code structure. 
Each team member of **Sub-team 1** must refactor the old code from `infra-old/` into the structured folders below:

## Folder Map

- `bootstrap/` - Configures Backend (S3 & DynamoDB) and OIDC Roles for GitHub Actions (Already configured).
- `environments/sandbox/` - Environment configuration targets.
  - `networking/` - VPC, Subnets, Route Tables, KMS, Security Groups.
  - `compute/` - EKS Cluster, Node Groups, Karpenter IAM Roles.
  - `services/` - Karpenter NodePools, Ingress Controllers, Monitoring Collectors.

*Note: Use `terraform_remote_state` to feed outputs sequentially.*
