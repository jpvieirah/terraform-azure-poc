# Terraform Azure POC — Reusable Workflow + Callers

POC de pipeline Terraform com arquitetura **Reusable Workflow + Callers** para deploy em Azure, usando autenticação OIDC (sem secrets de senha) e governança com Trivy.

---

## Índice

- [Arquitetura](#arquitetura)
- [Pré-requisitos](#pré-requisitos)
- [Setup Inicial](#setup-inicial)
  - [1. Azure — Infra de tfstate](#1-azure--infra-de-tfstate)
  - [2. Azure — App Registration + OIDC](#2-azure--app-registration--oidc)
  - [3. GitHub — Secrets](#3-github--secrets)
  - [4. GitHub — Environments](#4-github--environments)
- [Como usar](#como-usar)
  - [Fluxo de Plan (automático)](#fluxo-de-plan-automático)
  - [Fluxo de Apply (manual)](#fluxo-de-apply-manual)
  - [Adicionando um novo ambiente](#adicionando-um-novo-ambiente)
- [Pipeline — Detalhamento](#pipeline--detalhamento)
- [Versões](#versões)
- [Estrutura do Repositório](#estrutura-do-repositório)

---

## Arquitetura

```
.github/workflows/
├── terraform-deploy.yml    # Reusable Workflow (genérico — não conhece a infra)
├── deploy-prd.yml          # Caller → PRD
├── deploy-nprd.yml         # Caller → NPRD
└── deploy-lzone.yml        # Caller → Landing Zone

terraform/
├── prd/                    # Infra do ambiente PRD
│   ├── main.tf
│   ├── providers.tf
│   ├── variables.tf
│   └── outputs.tf
├── nprd/                   # Infra do ambiente NPRD
└── lzone/                  # Infra do ambiente Landing Zone
```

**Princípio**: O reusable workflow **não conhece a infra**. Ele apenas recebe o ambiente e o diretório do caller, e mantém a governança (validação, segurança, aprovação, deploy).

---

## Pré-requisitos

| Requisito | Detalhes |
|-----------|----------|
| **Azure CLI** | `az` instalado e autenticado (`az login`) |
| **GitHub CLI** | `gh` instalado e autenticado (`gh auth login`) |
| **Terraform** | >= 1.14.0 (local, para desenvolvimento) |
| **Conta Azure** | Subscription ativa com permissão para criar App Registrations e atribuir roles |
| **Conta GitHub** | Repo privado. Para usar environment protection rules (required reviewers), é necessário plano **GitHub Team** (org) ou repo público |

---

## Setup Inicial

### 1. Azure — Infra de tfstate

Crie o Resource Group e Storage Account para armazenar o estado do Terraform:

```bash
# Variáveis
RG_NAME="rg-tfstate-poc"
SA_NAME="sttfstatepoc$(openssl rand -hex 3)"   # nome único
LOCATION="brazilsouth"
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

# Resource Group
az group create --name $RG_NAME --location $LOCATION

# Storage Account
az storage account create \
  --name $SA_NAME \
  --resource-group $RG_NAME \
  --location $LOCATION \
  --sku Standard_LRS \
  --kind StorageV2 \
  --allow-blob-public-access false

# Container para tfstate
az storage container create \
  --name tfstate \
  --account-name $SA_NAME \
  --auth-mode login
```

### 2. Azure — App Registration + OIDC

Crie a App Registration com Federated Credentials para autenticação OIDC (sem client secret):

```bash
# Criar App Registration
APP_ID=$(az ad app create --display-name "github-oidc-terraform-poc" --query appId -o tsv)

# Criar Service Principal
az ad sp create --id $APP_ID

# Atribuir roles
# Contributor na subscription (para criar recursos)
az role assignment create \
  --assignee $APP_ID \
  --role Contributor \
  --scope /subscriptions/$SUBSCRIPTION_ID

# Storage Blob Data Contributor no Storage Account do tfstate
SA_ID=$(az storage account show --name $SA_NAME --resource-group $RG_NAME --query id -o tsv)
az role assignment create \
  --assignee $APP_ID \
  --role "Storage Blob Data Contributor" \
  --scope $SA_ID

# Criar Federated Credentials (uma por ambiente + branch main)
REPO="<seu-usuario>/<seu-repo>"

for ENV in prd nprd lzone; do
  az ad app federated-credential create --id $APP_ID --parameters "{
    \"name\": \"github-env-$ENV\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"repo:$REPO:environment:$ENV\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }"
done

az ad app federated-credential create --id $APP_ID --parameters "{
  \"name\": \"github-branch-main\",
  \"issuer\": \"https://token.actions.githubusercontent.com\",
  \"subject\": \"repo:$REPO:ref:refs/heads/main\",
  \"audiences\": [\"api://AzureADTokenExchange\"]
}"
```

### 3. GitHub — Secrets

Configure os secrets no repositório:

```bash
REPO="<seu-usuario>/<seu-repo>"
TENANT_ID=$(az account show --query tenantId -o tsv)

gh secret set AZURE_TENANT_ID       --repo $REPO --body "$TENANT_ID"
gh secret set AZURE_CLIENT_ID       --repo $REPO --body "$APP_ID"
gh secret set AZURE_SUBSCRIPTION_ID --repo $REPO --body "$SUBSCRIPTION_ID"
gh secret set TF_STATE_RG           --repo $REPO --body "$RG_NAME"
gh secret set TF_STATE_SA           --repo $REPO --body "$SA_NAME"
```

| Secret | Descrição |
|--------|-----------|
| `AZURE_TENANT_ID` | Tenant ID do Azure AD |
| `AZURE_CLIENT_ID` | Client ID da App Registration (OIDC) |
| `AZURE_SUBSCRIPTION_ID` | Subscription ID |
| `TF_STATE_RG` | Resource Group do Storage Account de tfstate |
| `TF_STATE_SA` | Nome do Storage Account de tfstate |

### 4. GitHub — Environments

Crie os environments (opcionalmente com protection rules):

```bash
REPO="<seu-usuario>/<seu-repo>"

# Criar environments
for ENV in prd nprd lzone; do
  gh api --method PUT repos/$REPO/environments/$ENV
done

# (Opcional — requer GitHub Team ou repo público)
# Adicionar required reviewers ao PRD:
# USER_ID=$(gh api users/<seu-usuario> --jq '.id')
# printf '{"reviewers":[{"type":"User","id":%s}]}' $USER_ID | \
#   gh api repos/$REPO/environments/prd --method PUT --input -
```

> **Nota**: Required reviewers em repos privados exigem plano **GitHub Team** (org, $4/user/mês). Em repos pessoais no plano Free/Pro, o gate de aprovação é feito manualmente via dispatch com `apply=true`.

---

## Como usar

### Fluxo de Plan (automático)

O plan roda automaticamente em duas situações:

1. **Push** em `terraform/<env>/**` na branch `main`
2. **Workflow dispatch** manual com `apply = false` (padrão)

O plan gera:
- Resultado do `terraform plan` no **Job Summary**
- Relatório de segurança do **Trivy** no Summary
- **Artifacts** com o plan binário, plan texto e resultados do Trivy

### Fluxo de Apply (manual)

1. Acesse **Actions** no GitHub
2. Selecione o caller do ambiente desejado (ex: `Deploy — NPRD`)
3. Clique em **Run workflow**
4. Marque `apply = true`
5. Clique em **Run workflow**

Se o environment tiver required reviewers configurados, a aprovação será solicitada antes do apply.

### Adicionando um novo ambiente

1. **Crie o diretório Terraform** em `terraform/<novo-env>/` com `main.tf`, `providers.tf`, `variables.tf` e `outputs.tf`

2. **Crie o caller** em `.github/workflows/deploy-<novo-env>.yml`:

```yaml
name: "Deploy — <NOVO-ENV>"

on:
  push:
    paths: ["terraform/<novo-env>/**"]
    branches: [main]
  workflow_dispatch:
    inputs:
      apply:
        description: "Run terraform apply after plan?"
        required: true
        type: boolean
        default: false

permissions:
  id-token: write
  contents: read
  pull-requests: write

jobs:
  deploy:
    uses: ./.github/workflows/terraform-deploy.yml
    with:
      environment: <novo-env>
      terraform_dir: terraform/<novo-env>
      apply: ${{ github.event.inputs.apply == 'true' || false }}
    secrets: inherit
```

3. **Crie a Federated Credential** no Azure:

```bash
az ad app federated-credential create --id $APP_ID --parameters "{
  \"name\": \"github-env-<novo-env>\",
  \"issuer\": \"https://token.actions.githubusercontent.com\",
  \"subject\": \"repo:<seu-usuario>/<seu-repo>:environment:<novo-env>\",
  \"audiences\": [\"api://AzureADTokenExchange\"]
}"
```

4. **Crie o environment** no GitHub:

```bash
gh api --method PUT repos/<seu-usuario>/<seu-repo>/environments/<novo-env>
```

---

## Estratégia de Aprovação e Code Review

### Visão ideal (com GitHub Team ou repo público)

A arquitetura foi desenhada para funcionar com **environment protection rules** do GitHub, onde cada ambiente tem seus aprovadores:

| Ambiente | Aprovadores | Regra |
|----------|-------------|-------|
| **prd** | `jpvieirah` + `Francinilo` | Ambos precisam aprovar para o apply executar |
| **nprd** | `jpvieirah` | Apenas o owner aprova |
| **lzone** | `jpvieirah` | Apenas o owner aprova |

Nesse cenário, o fluxo seria:

1. Dev faz push com alterações no Terraform
2. Pipeline roda automaticamente o **plan** (init → fmt → validate → trivy → plan)
3. Resultados ficam visíveis no **Job Summary** e **Artifacts**
4. Dev dispara o apply via `workflow_dispatch` com `apply=true`
5. O GitHub **pausa o job de apply** e solicita aprovação dos reviewers configurados no environment
6. Aprovadores revisam o plan no Summary, aprovam ou rejeitam
7. Só após aprovação, o apply executa

Isso garante que **nenhuma mudança de infra vai para produção sem revisão**, mesmo que alguém tenha permissão de dispatch.

### Implementação atual (POC — conta pessoal)

Como esta POC usa um repo **privado em conta pessoal** (GitHub Free/Pro), o GitHub não suporta environment protection rules. Por isso, a governança é feita de forma manual:

1. **Push** ou **dispatch com `apply=false`** → roda apenas o plan
2. O responsável revisa o plan no Summary (output do Terraform + findings do Trivy)
3. Se estiver ok, **dispara manualmente** com `apply=true` → aí roda plan + apply

O gate de segurança é **quem tem permissão de dispatch no repo**. Como o repo é privado, apenas collaborators podem disparar.

### Por que separar plan e apply em dispatch?

A separação existe porque:

- **Plan é seguro** — não altera nada, apenas mostra o que será feito
- **Apply é destrutivo** — altera infra real e deve ser uma ação consciente
- O **boolean `apply`** no dispatch força o usuário a deliberadamente optar por aplicar
- Em ambiente corporativo com GitHub Team, esse dispatch com `apply=true` é o **gatilho** que aciona os environment protection rules (required reviewers)

### Migração para ambiente corporativo

Para usar essa pipeline em uma organização com aprovação real:

1. Mova o repo para uma **org com plano GitHub Team** ($4/user/mês)
2. Configure **required reviewers** em cada environment:
   ```bash
   # Exemplo: PRD com 2 aprovadores
   printf '{"reviewers":[{"type":"User","id":ID_USER_1},{"type":"User","id":ID_USER_2}]}' | \
     gh api repos/ORG/REPO/environments/prd --method PUT --input -
   ```
3. O workflow **não precisa mudar** — o job de apply já tem `environment: ${{ inputs.environment }}`, que automaticamente aciona as protection rules
4. Atualize as **federated credentials** no Azure para o novo repo/org

---

## Pipeline — Detalhamento

### Job: Plan

| Step | Descrição | Falha bloqueia? |
|------|-----------|------------------|
| Checkout | Clona o repo | Sim |
| Setup Terraform | Instala a versão configurada | Sim |
| Azure Login (OIDC) | Autentica via federated credential | Sim |
| Terraform Init | Inicializa backend remoto (Azure Storage) | Sim |
| Terraform Format Check | Verifica formatação (`terraform fmt`) | Não (warning) |
| Terraform Validate | Valida a configuração | Sim |
| **Trivy — IaC Security Scan** | Scan de segurança no código Terraform | Não (warning) |
| **Parse Trivy Results** | Extrai contagem de HIGH/CRITICAL | — |
| Terraform Plan | Gera o plano de execução | Não (continue-on-error) |
| Publish Job Summary | Publica resultados no Summary do GitHub | — |
| Upload Artifacts | Salva tfplan + plan.txt + trivy-results.json | — |

### Job: Apply

Só executa quando `apply=true` via workflow dispatch.

| Step | Descrição |
|------|----------|
| Checkout | Clona o repo |
| Setup Terraform | Instala a versão configurada |
| Azure Login (OIDC) | Autentica via federated credential |
| Terraform Init | Inicializa backend remoto |
| Download Plan Artifact | Baixa o plan do job anterior |
| Terraform Apply | Aplica as mudanças |
| Post Apply Summary | Publica confirmação no Summary |

---

## Versões

| Tool | Versão |
|------|--------|
| Terraform CLI | 1.14.7 |
| AzureRM Provider | ~> 4.64 |
| Trivy Action | 0.34.2 |
| `actions/checkout` | v4 |
| `hashicorp/setup-terraform` | v3 |
| `azure/login` | v2 |
| `actions/upload-artifact` | v4 |
| `actions/download-artifact` | v4 |

---

## Estrutura do Repositório

```
.
├── .github/
│   └── workflows/
│       ├── terraform-deploy.yml   # Reusable workflow (genérico)
│       ├── deploy-prd.yml         # Caller PRD
│       ├── deploy-nprd.yml        # Caller NPRD
│       └── deploy-lzone.yml       # Caller Landing Zone
├── terraform/
│   ├── prd/
│   │   ├── main.tf               # Resource Group + VNet
│   │   ├── providers.tf          # AzureRM 4.64 + backend
│   │   ├── variables.tf          # environment, location, project
│   │   └── outputs.tf            # RG name/id, VNet name/id
│   ├── nprd/
│   │   └── (mesma estrutura)
│   └── lzone/
│       └── (mesma estrutura)
├── .gitignore
└── README.md
```
