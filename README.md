<div align="center">

# 🧠 Self-Healing EKS Cluster with AWS Bedrock

[![Terraform](https://img.shields.io/badge/Terraform-1.5%2B-7B42BC?logo=terraform&logoColor=white)](https://terraform.io)
[![AWS EKS](https://img.shields.io/badge/AWS-EKS-FF9900?logo=amazon-aws&logoColor=white)](https://aws.amazon.com/eks)
[![AWS Bedrock](https://img.shields.io/badge/AWS-Bedrock-FF9900?logo=amazon-aws&logoColor=white)](https://aws.amazon.com/bedrock)
[![Python](https://img.shields.io/badge/Python-3.12-3776AB?logo=python&logoColor=white)](https://python.org)
[![Claude](https://img.shields.io/badge/Powered%20by-Claude%203.5%20Sonnet-D4A017)](https://anthropic.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

**An agentic AI system that automatically diagnoses and remediates failing Kubernetes pods — no human intervention required.**

*"Don't just monitor. Automate."*

[Architecture](#architecture) • [How It Works](#how-it-works) • [Prerequisites](#prerequisites) • [Cost Estimation](#cost-estimation) • [Production Alternative](#-production-alternative-10x-cheaper) • [Setup](#setup) • [Demo](#demo) • [YouTube Demo Guide](#-youtube-demo-guide) • [Video Walkthrough](#video-walkthrough)

</div>

---

## 🎯 What This Project Does

When a Kubernetes pod enters `CrashLoopBackOff` or gets `OOMKilled`, the traditional response is a 2 AM page, a panicked Slack thread, and 45 minutes of log-diving.

This project replaces that with an **AI Agent** that:

1. Detects the failure via a CloudWatch alarm
2. Fetches pod logs and event history automatically
3. **Retrieves the relevant runbook** from a vector knowledge base (RAG)
4. Reasons step-by-step through the root cause
5. Executes the appropriate fix (`kubectl delete pod`, `patch deployment`, `scale`)
6. Verifies the pod recovers — and reports what it did

Everything is provisioned with **Terraform** in a single `terraform apply`.

---

## 🏗 Architecture

```
Failing Pod (CrashLoopBackOff / OOMKilled)
        │
        ▼
CloudWatch Alarm ──► SNS Topic
                          │
                          ▼
                   Lambda Orchestrator
                   (orchestrator.py)
                          │
                          ▼
              ┌─── Bedrock Agent ────────────────┐
              │   Claude 3.5 Sonnet              │
              │                                  │
              │  ┌─────────────────────────┐     │
              │  │  Knowledge Base (RAG)   │     │
              │  │  Runbooks in S3         │◄────┤
              │  │  OpenSearch Serverless  │     │
              │  └─────────────────────────┘     │
              │                                  │
              │  Action Group (OpenAPI)           │
              │  - get_pod_logs                  │
              │  - restart_pod                   │
              │  - scale_deployment              │
              │  - update_resource_limits        │
              └──────────────┬───────────────────┘
                             │
                             ▼
                   Lambda Executor
                   (executor.py)
                   kubectl via IAM Auth
                             │
                             ▼
                   ✅ Pod Healed & Verified
```

### Tech Stack

| Component | Technology |
|-----------|------------|
| Container Orchestration | AWS EKS 1.29 |
| AI Agent | AWS Bedrock (Claude 3.5 Sonnet) |
| RAG / Knowledge Base | Bedrock KB + OpenSearch Serverless |
| Runbook Storage | Amazon S3 |
| Alerting | CloudWatch Alarms → SNS |
| Orchestration | AWS Lambda (Python 3.12) |
| IaC | Terraform ~> 5.0 |
| Networking | VPC with private/public subnets, NAT |

---

## 🧠 How It Works

### The Agentic RAG Loop

The Bedrock Agent uses a **ReAct (Reasoning + Acting)** loop:

```
THINKING  → "Received alert: CrashLoopBackOff on pod demo-app-7d4c9"
ACTION    → getPodLogs(namespace=default, pod_name=demo-app-7d4c9)
OBSERVE   → "Exit code 137. OOMKilled. Memory limit was 8Mi"
RETRIEVE  → knowledge_base.search("OOMKilled exit 137 memory limit")
THINKING  → "Runbook match: OOMKilled. Action: increase memory, restart pod"
ACTION    → updateResourceLimits(deployment=demo-app, memory_limit=512Mi)
ACTION    → restartPod(namespace=default, pod_name=demo-app-7d4c9)
VERIFY    → getPodStatus() → "Running. Uptime 42s. ✅"
REPORT    → { RootCause: OOMKilled, ActionTaken: memory+restart, Outcome: Healed }
```

### Why RAG Makes It Smarter Than a Script

Traditional scripts react to fixed conditions. This agent **reads your team's actual runbooks** at inference time — so it applies your organization's specific remediation logic, not generic StackOverflow advice. Update the Markdown files in S3, re-sync the knowledge base, and the agent's behavior updates without a single code change.

### Agent Instruction Design

The agent is prompted to follow a **least-disruptive-first** escalation policy:

1. Restart the specific pod
2. Scale the deployment horizontally
3. Increase resource limits and redeploy
4. Escalate to human via SNS (if confidence < 80%)

---

## ✅ Prerequisites

- AWS account with the following services enabled:
  - Amazon EKS
  - Amazon Bedrock (Claude 3.5 Sonnet model access — request via AWS console)
  - AWS Lambda
  - Amazon OpenSearch Serverless
  - CloudWatch, SNS, S3
- [Terraform](https://terraform.io/downloads) >= 1.5.0
- [AWS CLI](https://aws.amazon.com/cli/) configured with sufficient IAM permissions
- [kubectl](https://kubernetes.io/docs/tasks/tools/) installed locally
- Python 3.12+ (for local Lambda testing only)

### Required IAM Permissions

Your Terraform user/role needs permissions to create: EKS clusters, Lambda functions, Bedrock agents, OpenSearch Serverless collections, IAM roles, S3 buckets, CloudWatch alarms, and SNS topics. An `AdministratorAccess` policy works for a demo environment.

---

## 💰 Cost Estimation

> **Heads up:** This setup uses real AWS services that incur charges even at idle. Destroy the infrastructure with `terraform destroy` when you're done recording or testing.

The table below shows estimated costs based on the default configuration (2x t3.medium EC2 worker nodes, us-east-1 region).

| Service | 1 Day | 7 Days | 30 Days |
|---------|------:|-------:|--------:|
| OpenSearch Serverless | $11.52 | $80.64 | $345.00 |
| NAT Gateway | $1.08 | $7.56 | $32.40 |
| EKS Control Plane | $0.24 | $1.68 | $7.20 |
| EC2 Worker Nodes (2x t3.medium) | $0.19 | $1.34 | $5.76 |
| Bedrock Agent + RAG | ~$0.10 | ~$0.50 | ~$2.00 |
| Lambda + SNS + CloudWatch | ~$0.01 | ~$0.05 | ~$0.20 |
| S3 (runbooks) | ~$0.00 | ~$0.01 | ~$0.05 |
| **Total estimate** | **~$13** | **~$92** | **~$393** |

### ⚠️ The OpenSearch Serverless Surprise

**OpenSearch Serverless is ~87% of your bill.** It charges a minimum of 2 OCUs at $0.24/OCU/hour regardless of traffic — that's ~$11.52/day even if you run zero queries. This is the biggest cost surprise for demos.

**Tips to reduce costs:**
- Run `terraform destroy` immediately after finishing your demo or recording session
- For development/testing, consider mocking the Knowledge Base and skipping OpenSearch Serverless entirely
- OpenSearch Serverless does not have a free tier or a "pause" option — the meter runs continuously while the collection exists

---

## 🏭 Production Alternative (10x Cheaper)

The demo uses **OpenSearch Serverless** because it requires zero configuration — ideal for a quick deploy. But at ~$345/month just for the vector store, it is not viable for production. The recommended production swap is **pgvector on Amazon RDS PostgreSQL**.

### Architecture Comparison

```
DEMO SETUP (YouTube recording)          PRODUCTION SETUP (real workloads)
──────────────────────────────          ──────────────────────────────────

Failing Pod                             Failing Pod
     │                                       │
     ▼                                       ▼
CloudWatch → SNS → Lambda               CloudWatch → SNS → Lambda
                       │                                       │
                       ▼                                       ▼
              Bedrock Agent                       Lambda (custom ReAct loop)
              (managed, visual)                   (direct Bedrock Runtime API)
                       │                                       │
              ┌────────┴────────┐                    ┌─────────┴──────────┐
              │ Bedrock KB      │                    │ pgvector on RDS    │
              │ OpenSearch      │                    │ PostgreSQL t3.micro │
              │ Serverless      │                    │ (same embeddings)  │
              └─────────────────┘                    └────────────────────┘
                       │                                       │
              Lambda Executor (kubectl)         Lambda Executor (kubectl)
                       │                                       │
                  Pod Healed                            Pod Healed
```

### Cost Comparison

| Component | Demo (OpenSearch) | Production (pgvector) | Monthly Saving |
|---|---|---|---|
| Vector Store | OpenSearch Serverless ~$345 | RDS t3.micro + pgvector ~$15 | **$330** |
| RAG Layer | Bedrock Knowledge Base ~$5 | Custom Lambda query ~$0.50 | **$4.50** |
| Networking | NAT Gateway ~$32 | VPC Endpoints ~$15 | **$17** |
| EKS + EC2 | ~$13 (already in prod) | ~$13 (already in prod) | — |
| Bedrock (Claude) | ~$2 | ~$2 | — |
| Lambda / SNS / CW | ~$0.20 | ~$0.20 | — |
| **Monthly Total** | **~$393** | **~$36** | **~$357 saved** |

> **~10x cost reduction** by swapping the vector store and removing the NAT Gateway.

### What Changes in the Code

Only two components need updating — everything else stays identical:

**1. Replace OpenSearch Serverless with pgvector on RDS**

```hcl
# REMOVE from main.tf:
resource "aws_opensearchserverless_collection" "kb" { ... }
resource "aws_bedrockagent_knowledge_base" "runbooks" { ... }

# ADD to main.tf:
resource "aws_db_instance" "pgvector" {
  identifier        = "self-healing-kb"
  engine            = "postgres"
  engine_version    = "15.4"
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  db_name           = "runbooks"
  username          = "healing_agent"
  password          = var.db_password
  # pgvector extension enabled via RDS parameter group
}
```

**2. Replace Bedrock Agent with a direct ReAct loop in Lambda**

```python
# orchestrator.py — swap invoke_agent() for a direct loop
import boto3, json

bedrock = boto3.client("bedrock-runtime")
db      = boto3.client("rds-data")

def react_loop(alert_context):
    messages = [{"role": "user", "content": build_prompt(alert_context)}]
    for _ in range(10):                         # max 10 reasoning steps
        response = bedrock.invoke_model(
            modelId="anthropic.claude-3-5-sonnet-20241022-v2:0",
            body=json.dumps({"messages": messages, "tools": KUBECTL_TOOLS})
        )
        result = json.loads(response["body"].read())
        if result["stop_reason"] == "end_turn":
            return result                       # agent finished
        messages = handle_tool_use(messages, result)   # run kubectl, loop
```

**3. Replace NAT Gateway with VPC Endpoints**

```hcl
# Add endpoints for each AWS service Lambda calls — no NAT needed
resource "aws_vpc_endpoint" "bedrock"     { service_name = "com.amazonaws.us-east-1.bedrock-runtime" }
resource "aws_vpc_endpoint" "s3"          { service_name = "com.amazonaws.us-east-1.s3" }
resource "aws_vpc_endpoint" "cloudwatch"  { service_name = "com.amazonaws.us-east-1.logs" }
```

### Why pgvector is Production-Ready

| Concern | Answer |
|---|---|
| Scale | Handles millions of embeddings with IVFFlat / HNSW indexes |
| Ops | RDS Multi-AZ gives 99.95% uptime SLA, automated backups |
| Familiarity | Any engineer who knows PostgreSQL can query, inspect, and tune it |
| Migration | Same Titan Embed model — re-embed runbooks once, import to pg |
| Search quality | Cosine similarity on 1536-dim vectors matches OpenSearch quality |

---

## 🚀 Setup

### 1. Clone and configure

```bash
git clone https://github.com/YOUR_USERNAME/self-healing-eks-bedrock.git
cd self-healing-eks-bedrock
```

### 2. Enable Claude 3.5 Sonnet in Bedrock

In the AWS Console → Amazon Bedrock → Model access → Request access to:
- `anthropic.claude-3-5-sonnet-20241022-v2:0`
- `amazon.titan-embed-text-v2:0`

### 3. Deploy infrastructure

```bash
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

This creates ~25 AWS resources. Typical apply time: 15-20 minutes (EKS dominates).

### 4. Upload runbooks and sync the Knowledge Base

```bash
# Get the S3 bucket name from Terraform output
BUCKET=$(terraform output -raw runbook_bucket)

# Upload runbooks
aws s3 cp runbooks/ s3://$BUCKET/runbooks/ --recursive

# Sync the Knowledge Base (get KB ID from output)
KB_ID=$(terraform output -raw bedrock_knowledge_base_id 2>/dev/null || echo "see console")
aws bedrock-agent start-ingestion-job \
  --knowledge-base-id $KB_ID \
  --data-source-id $(aws bedrock-agent list-data-sources --knowledge-base-id $KB_ID --query 'dataSourceSummaries[0].dataSourceId' --output text)
```

### 5. Create a Bedrock Agent Alias

```bash
AGENT_ID=$(terraform output -raw bedrock_agent_id)

aws bedrock-agent create-agent-alias \
  --agent-id $AGENT_ID \
  --agent-alias-name "production"
```

Update the Lambda environment variable `BEDROCK_AGENT_ALIAS` with the returned alias ID.

### 6. Configure kubectl

```bash
CLUSTER=$(terraform output -raw eks_cluster_endpoint | cut -d/ -f3 | cut -d. -f1)
aws eks update-kubeconfig --name self-healing-demo --region us-east-1
kubectl get nodes  # verify connectivity
```

---

## 🎬 Demo

Deploy the intentionally-broken pods to trigger the agent:

```bash
# Deploy failing pods (OOMKilled + CrashLoopBackOff)
kubectl apply -f demo/failing-pod.yaml

# Watch the pods fail
kubectl get pods -w

# Manually trigger the Bedrock agent (simulates the CloudWatch alarm)
SNS_ARN=$(terraform output -raw sns_trigger_arn)
aws sns publish \
  --topic-arn $SNS_ARN \
  --message '{"AlarmName":"self-healing-demo-pod-crashloop","AlarmDescription":"Pod CrashLoopBackOff","Trigger":{"Dimensions":[{"name":"ClusterName","value":"self-healing-demo"}]}}'

# Watch the agent's thought trace in CloudWatch Logs
aws logs tail /aws/lambda/self-healing-demo-bedrock-orchestrator --follow
```

---

## 📁 Project Structure

```
self-healing-eks-bedrock/
├── main.tf                    # All Terraform — EKS, Bedrock Agent, KB, Lambda, SNS
├── lambda/
│   ├── orchestrator.py        # SNS → Bedrock Agent invocation with trace streaming
│   └── executor.py            # Action Group handler — runs kubectl via IAM auth
├── runbooks/
│   ├── crashloop-backoff.md   # RAG source: CrashLoopBackOff diagnosis & fix
│   └── oom-killed.md          # RAG source: OOMKilled memory remediation
└── demo/
    └── failing-pod.yaml       # Intentionally broken K8s manifests for demo
```

---

## 🔒 Security Notes

- All Lambda functions use least-privilege IAM roles
- EKS cluster uses private subnets; only the API endpoint is public
- Bedrock Agent is scoped to a single cluster ARN
- OpenSearch Serverless access is restricted to the KB and Agent IAM roles
- **Do not commit AWS credentials** — use IAM roles or environment variables

---

## 💡 Extending This Project

| Idea | How |
|------|-----|
| Slack notifications | Add SNS → Slack Lambda after remediation |
| Human-approval gate | Add a step function with a manual approval task |
| Multi-cluster support | Pass cluster name dynamically in the SNS payload |
| More runbooks | Add `.md` files to S3 and re-sync the KB — no code changes |
| Cost alerting | Add a Lambda that checks AWS Cost Explorer before scaling |

---

## 🎥 YouTube Demo Guide

This section is a script reference for the live YouTube walkthrough. The demo uses the full OpenSearch Serverless setup (best visuals), then pivots to the production alternative for the final segment.

### Pre-Recording Checklist

- [ ] Do a **dry run the day before** — the Bedrock Agent alias (Step 5) and KB sync are the two steps most likely to have timing issues on first deploy
- [ ] Run `terraform apply` and verify `kubectl get nodes` returns 2 Ready nodes
- [ ] Deploy `demo/failing-pod.yaml` once to confirm CrashLoopBackOff triggers correctly
- [ ] Open these tabs in advance: AWS Console (Bedrock Agent, CloudWatch Logs, EKS), terminal with `kubectl get pods -w` ready
- [ ] Run `terraform destroy` after recording — leaving it up costs ~$13/day

### Suggested Video Structure (~12 minutes)

| Timestamp | Segment | What to Show |
|---|---|---|
| 0:00 – 1:00 | Problem statement | "2 AM page, CrashLoopBackOff, 45 min of log-diving" |
| 1:00 – 3:00 | Architecture walkthrough | Draw the diagram, tour the AWS Console resources |
| 3:00 – 4:00 | Deploy failing pod | `kubectl apply -f demo/failing-pod.yaml` + `kubectl get pods -w` |
| 4:00 – 6:30 | Trigger the agent | Publish SNS message, switch to CloudWatch Logs |
| 6:30 – 8:00 | Watch the ReAct trace | Show THINKING → ACTION → OBSERVE → VERIFY in logs |
| 8:00 – 8:30 | Pod recovery | `kubectl get pods` shows Running — the "wow moment" |
| 8:30 – 10:30 | Production alternative | Side-by-side architecture diagram, cost comparison table |
| 10:30 – 11:30 | pgvector code walkthrough | Show the Terraform diff and orchestrator.py ReAct loop |
| 11:30 – 12:00 | `terraform destroy` + CTA | Destroy live on screen, mention GitHub link |

### Key Talking Points

**On the demo setup:**
> *"We're using OpenSearch Serverless here because it deploys in one `terraform apply` with zero config. That's perfect for a demo. But in production, you'd swap it out — and that swap cuts your monthly bill from $393 to about $36."*

**On the ReAct trace (CloudWatch Logs segment):**
> *"This is what makes this different from a script. Watch the agent reason — it doesn't just blindly restart the pod. It fetches the logs, reads the runbook, thinks about the root cause, then picks the least-disruptive action. If it's not confident enough, it escalates to a human instead of guessing."*

**On the production alternative:**
> *"OpenSearch Serverless is 87% of the bill — $345 a month — because it charges for 2 compute units 24/7 whether you have traffic or not. pgvector on RDS runs on a $15/month t3.micro and gives you the exact same vector similarity search. Same embeddings, same search quality, a tenth of the cost."*

---

## 📺 Video Walkthrough

Full 12-minute technical demo on YouTube: *[link coming soon]*

Covers: live demo of a pod healing, Terraform walkthrough, agent thought trace explanation, RAG architecture, and the production cost-optimised alternative.

---

## 📄 License

MIT License — see [LICENSE](LICENSE) for details.

---

<div align="center">

Built with ☁️ AWS Bedrock, 🤖 Claude 3.5 Sonnet, and ⚡ Terraform

*Star ⭐ the repo if this helped you — it keeps the content coming!*

</div>
