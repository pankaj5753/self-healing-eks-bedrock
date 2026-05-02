# CLAUDE.md — Project Context for AI Assistants

This file gives any Claude instance (on any machine) full context to continue working on this project without needing to re-explain everything.

---

## What This Project Is

**Self-Healing EKS Cluster with AWS Bedrock** — an agentic AI system that automatically detects and remediates failing Kubernetes pods (CrashLoopBackOff, OOMKilled) using a Bedrock Agent (Claude 3.5 Sonnet) + RAG knowledge base, all provisioned via Terraform.

GitHub repo: https://github.com/pankaj5753/self-healing-eks-bedrock

### Key Files

| File | Purpose |
|---|---|
| `main.tf` | All Terraform — EKS, Bedrock Agent, KB, Lambda, SNS, OpenSearch (~743 lines) |
| `lambda/orchestrator.py` | SNS → Bedrock Agent invocation with trace streaming |
| `lambda/executor.py` | Action Group handler — runs kubectl via IAM auth |
| `runbooks/crashloop-backoff.md` | RAG source: CrashLoopBackOff diagnosis |
| `runbooks/oom-killed.md` | RAG source: OOMKilled memory remediation |
| `demo/failing-pod.yaml` | Intentionally broken K8s manifests for triggering the agent |
| `README.md` | Full documentation (keep this updated — it is the source of truth) |

---

## Owner

- **GitHub user:** pankaj5753
- **Email:** pk.pankajkumaar@gmail.com
- **Use case:** YouTube channel demo + open source showcase

---

## Current Status (as of 2026-05-02)

- [x] Initial project committed and pushed to GitHub
- [x] README updated with full cost breakdown (1-day ~$13, 7-day ~$92, 30-day ~$393)
- [x] README updated with Production Alternative section (pgvector on RDS, ~$36/month)
- [x] README updated with YouTube Demo Guide (video structure, script, talking points)
- [ ] YouTube video not yet recorded — dry run recommended before recording day
- [ ] Video link not yet added to README

---

## What Has Been Discussed and Decided

### Cost Breakdown (from Claude chat analysis)

| Service | 1 Day | 7 Days | 30 Days |
|---|---|---|---|
| OpenSearch Serverless | $11.52 | $80.64 | $345.00 |
| NAT Gateway | $1.08 | $7.56 | $32.40 |
| EKS Control Plane | $0.24 | $1.68 | $7.20 |
| EC2 Worker Nodes (2x t3.medium) | $0.19 | $1.34 | $5.76 |
| Bedrock Agent + RAG | ~$0.10 | ~$0.50 | ~$2.00 |
| Lambda + SNS + CloudWatch | ~$0.01 | ~$0.05 | ~$0.20 |
| S3 (runbooks) | ~$0.00 | ~$0.01 | ~$0.05 |
| **Total** | **~$13** | **~$92** | **~$393** |

**Key insight:** OpenSearch Serverless is 87% of the bill — 2 OCU minimum at $0.24/OCU/hr, running 24/7 regardless of traffic.

### Production Alternative: pgvector on RDS

Decided to recommend **pgvector on RDS PostgreSQL** as the production-path alternative because:
- Cost: ~$15/month vs $345/month for OpenSearch Serverless
- PostgreSQL is universally known — good for YouTube audience
- pgvector is trending in AI/ML — good for search traffic
- Same embedding model (Amazon Titan Embed) — same search quality
- Total production cost: ~$36/month (vs ~$393 demo) — 10x reduction

The two other optimisations discussed:
- Replace Bedrock Agent with direct Bedrock Runtime API + custom ReAct loop in Lambda
- Replace NAT Gateway with VPC Endpoints (~$15/month vs $32/month)

### YouTube Demo Strategy

**Decision:** Use the full OpenSearch Serverless setup for the live demo (best AWS Console visuals — Bedrock Agent shows the ReAct trace beautifully), then pivot to the pgvector production alternative as a segment at the end.

**Suggested video structure:**
- 0:00–1:00 Problem statement
- 1:00–3:00 Architecture walkthrough
- 3:00–4:00 Deploy failing pod
- 4:00–6:30 Trigger the agent via SNS
- 6:30–8:00 Watch the ReAct trace in CloudWatch
- 8:00–8:30 Pod recovery (the "wow moment")
- 8:30–10:30 Production alternative + cost comparison
- 10:30–11:30 pgvector code walkthrough
- 11:30–12:00 `terraform destroy` live + call to action

**Important:** Do a dry run the day before recording. The Bedrock Agent alias (Step 5 in README) and KB sync are the two steps most likely to have timing issues on first deploy.

---

## How to Continue Working on This Project

### On a new machine, start by:

```bash
git clone https://github.com/pankaj5753/self-healing-eks-bedrock.git
cd self-healing-eks-bedrock
```

Then read this file and the README to get full context before making any changes.

### Pending work / next steps

1. **Record the YouTube video** — follow the guide in README under "YouTube Demo Guide"
2. **Add the YouTube video link** to README once uploaded (update the "link coming soon" line)
3. **Optionally implement pgvector branch** — create a `production/pgvector` branch with the Terraform changes for pgvector on RDS + direct Bedrock Runtime ReAct loop, so viewers can reference it after watching the video

### Things to be careful about

- **Always run `terraform destroy` after demo/recording** — leaving it up costs ~$13/day ($345+/month)
- **Do not commit AWS credentials** — use IAM roles or environment variables
- **The Bedrock Agent alias** must be created manually after `terraform apply` (Step 5 in README) — this is a known gap in the Terraform config
- **KB sync** must also be triggered manually after uploading runbooks to S3 (Step 4)

---

## Coding Conventions

- Terraform in a single `main.tf` (intentional — keeps the demo simple to walk through on screen)
- Lambda functions in Python 3.12
- No test files (demo project — not production code)
- README is the primary documentation — keep it accurate and up to date after any changes
