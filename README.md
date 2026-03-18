# Terraform Azure POC — Reusable Workflow + Callers

POC de pipeline Terraform com arquitetura **Reusable Workflow + Callers** para deploy em Azure.

## Arquitetura

```
.github/workflows/
├── terraform-deploy.yml    # Reusable (genérico — não conhece a infra)
├── deploy-prd.yml          # Caller → PRD
├── deploy-nprd.yml         # Caller → NPRD
└── deploy-lzone.yml        # Caller → Landing Zone

terraform/
├── prd/                    # Infra do ambiente PRD
├── nprd/                   # Infra do ambiente NPRD
└── lzone/                  # Infra do ambiente Landing Zone
```

## Pipeline

| Job | Descrição |
|-----|-----------|
| **Plan** | `init` → `fmt` → `validate` → `plan` → `trivy` → summary → artifacts |
| **Apply** | Download plan → `apply` (só quando `apply=true` via dispatch) |

## Como usar

1. **Só Plan**: Push em `terraform/<env>/**` ou dispatch manual com `apply=false`
2. **Plan + Apply**: Dispatch manual com `apply=true`

## Versões

| Tool | Versão |
|------|--------|
| Terraform | 1.14.7 |
| AzureRM Provider | ~> 4.64 |
| Trivy Action | 0.34.2 |
| GitHub Actions | checkout@v4, setup-terraform@v3, azure/login@v2 |

## Secrets necessários

| Secret | Descrição |
|--------|-----------|
| `AZURE_TENANT_ID` | Tenant ID do Azure AD |
| `AZURE_CLIENT_ID` | Client ID da App Registration (OIDC) |
| `AZURE_SUBSCRIPTION_ID` | Subscription ID |
| `TF_STATE_RG` | Resource Group do tfstate |
| `TF_STATE_SA` | Storage Account do tfstate |
