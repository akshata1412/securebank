# 🏦 SecureBank

**A cloud-native banking app on AWS with high availability, disaster recovery, Kubernetes and a CI/CD pipeline.**

Built for the Cloud Computing course (CB3203B) at Vishwakarma Institute of Technology, Pune.

Users log in, check their balance, transfer money and view their history. Data lives in Amazon RDS (MySQL), every transaction is backed up to S3 and replicated to a DR bucket, and the app runs on two servers in two Availability Zones behind a load balancer, with Route 53 health-checked failover.

---

## 🏗️ Architecture (as deployed, region ap-southeast-2 / Sydney)

```
                       Route 53  (securebank-akshata.com, health check on /health)
                       app.securebank-akshata.com
                         │ PRIMARY (Sydney)             │ SECONDARY (failover, Mumbai)
                         ▼                              ▼
              Application Load Balancer        Warm standby EC2, ap-south-1
                 (securebank-alb)              (second AWS account: SecureBank +
                                                MariaDB, refreshed every 30 s)
                  │              │
   ┌──────────────┼──────────────┼─────────────── securebank-vpc 10.0.0.0/16 ──┐
   │  public-a (2a)│   public-b (2b)│                                            │
   │  EC2 web-1  ◄─┘   EC2 web-2  ◄─┘        k3s cluster: master + 2 workers     │
   │  Docker: SecureBank  Docker: SecureBank  nginx ×3 (NodePort 30080)          │
   │                                          SecureBank ×3 (NodePort 30081)     │
   │  private-a (2a)    private-b (2b)   (reserved for DB / internal tier)       │
   └───────────────┬──────────────────────────────────────────────────────────┘
                   │ VPC peering
                   ▼
           RDS MySQL (securebank-db) ──► automated backups + snapshots
                   │
     app writes each transaction ──► S3 securebank-backups (versioned, SSE)
                                         ├─ replication ─► S3 securebank-dr-backup (Sydney)
                                         └─ pulled every 30 s ─► S3 securebank-dr-mumbai (Mumbai)
                                                                  └─► standby database in Mumbai

  Security & ops: IAM roles + least-privilege users + MFA · CloudTrail (KMS-encrypted logs)
                  CloudWatch alarm + dashboard · SNS email alerts · AWS Budgets
  DevOps:         GitHub Actions → lint + tests + Docker build → image to GHCR
```

> **Two regions:** the main AWS account's free plan only allows Sydney, so the second region runs in a
> second AWS account in Mumbai (ap-south-1). A bucket policy on the Sydney backup bucket lets the Mumbai
> account read it; the Mumbai standby pulls new transactions and customer balances every 30 seconds and
> rebuilds its own database from them. If the whole Sydney region goes down, Route 53 sends customers to
> Mumbai, which keeps serving the last copy it pulled.

---

## 🧪 Syllabus practicals inside the project

| # | Practical | Where it is in SecureBank |
|---|---|---|
| 1 | Account, billing alerts, regions/AZs | AWS Budget `SecureBank-ZeroSpend`, resources spread across AZs 2a/2b |
| 2 | VPC with public/private subnets, 2 VMs, load balancer | `securebank-vpc`, `securebank-web-1/2`, `securebank-alb` — [`infra/01-vpc.sh`](infra/01-vpc.sh), [`infra/02-web-tier-alb.sh`](infra/02-web-tier-alb.sh) |
| 3 | S3 bucket, upload, permissions | `securebank-backups-akshata-2026` (versioning, SSE-S3, replication, IAM role access) |
| 4 | Static website on S3 | `securebank-site-akshata-2026` (also the Route 53 failover target) |
| 5 | IAM users/roles, Admin vs Read-only, MFA | `SecureBank-EC2-S3-Role`, read-only user `securebank-auditor` with virtual MFA, policy-simulator proof |
| 6 | Dockerfile: Ubuntu + Apache2 auto-start | [`practical6/Dockerfile`](practical6/Dockerfile) |
| 7 | Kubernetes 3-node cluster, NGINX ×3, NodePort | k3s cluster — [`infra/04-k3s-cluster.sh`](infra/04-k3s-cluster.sh), [`k8s/nginx.yaml`](k8s/nginx.yaml) |
| 8 | Web server VM + storage + DB + DNS + load balancer | The whole stack: EC2 + S3 + RDS + Route 53 + ALB — [`infra/03-route53.sh`](infra/03-route53.sh) |
| Case study | RBAC with IAM + CloudTrail | IAM roles/users/MFA + CloudTrail `securebank-audit-trail` encrypted with KMS key `securebank-key` |

---

## 🛠️ Tech stack

| Layer | Technology |
|---|---|
| App | Python 3.11, Flask, Gunicorn |
| Database | Amazon RDS MySQL |
| Storage / DR | Amazon S3 (versioning, encryption, replication), RDS backups |
| Compute | Amazon EC2 (Docker), k3s Kubernetes |
| Networking | VPC, subnets, IGW, route tables, security groups, VPC peering, ALB, Route 53 |
| Security | IAM roles/policies, MFA, KMS, CloudTrail |
| Monitoring | CloudWatch alarms + dashboard, SNS, Route 53 health checks, AWS Budgets |
| CI/CD | GitHub Actions, GitHub Container Registry |

---

## 📁 Repository layout

```
app/            Flask application (config via environment variables)
tests/          Smoke tests run in CI
k8s/            Kubernetes manifests (nginx practical + SecureBank deployment)
practical6/     Ubuntu + Apache2 Dockerfile
infra/          AWS CLI scripts that built the infrastructure (run in CloudShell)
Dockerfile      SecureBank container image
.github/        CI/CD pipeline
```

---

## ▶️ Running

**Locally**
```bash
docker build -t securebank .
docker run -p 8080:80 -e DB_HOST=... -e DB_PASSWORD=... -e SECRET_KEY=... securebank
```

**On Kubernetes**
```bash
kubectl create secret generic securebank-db --from-literal=DB_PASSWORD=... --from-literal=SECRET_KEY=...
kubectl apply -f k8s/securebank.yaml
```

**Deploy the latest image (CloudShell)**
```bash
bash infra/deploy.sh        # pulls ghcr.io/akshata1412/securebank:latest onto both EC2 servers and k3s
```

**Disaster recovery demos (CloudShell, with the app's `/dr` page open beside it)**
```bash
bash infra/06-dr-setup.sh       # one time: backfill the DR vault, 10-second Route 53 health check, S3 status page

bash infra/demo.sh lb           # one server dies: the load balancer keeps the app up through the other
bash infra/demo.sh restore      # bring it back
bash infra/demo.sh pod          # a Kubernetes pod dies: it is recreated automatically
bash infra/demo.sh dr           # a transfer is backed up and replicated to the DR bucket
bash infra/demo.sh wipe         # disaster: the transaction ledger is wiped from RDS
bash infra/demo.sh recover      # the ledger is rebuilt from the DR bucket
bash infra/demo.sh outage       # disaster: Sydney goes dark, Route 53 fails over to the Mumbai standby
bash infra/demo.sh recover-site # servers come back, DNS returns to the load balancer, RTO is measured
```

The app's **`/dr`** page (Disaster recovery room) compares RDS with the DR bucket on every refresh, shows the
recovery point (replication lag) and the recovery time measured in the last drill, and lists every drill event.
During a full outage it stays reachable through the Kubernetes copy of the app (NodePort 30081).
The **`/infra`** page shows which server or pod served the request, load balancer and Route 53 health,
the database, backups and CloudTrail, all read live from AWS.

**Second region (Mumbai standby)**
```bash
# In the second account: launch an EC2 (Amazon Linux 2023, t3.micro) with infra/07-mumbai-standby-userdata.sh
# as user data and an instance role with S3 access. Then, in the Sydney account's CloudShell:
bash infra/08-route53-mumbai.sh <mumbai-public-dns>   # make Mumbai the Route 53 failover target
```

**Turn the AWS demo on/off (CloudShell)**
```bash
bash infra/sbctl.sh start   # or: stop | status
```

Demo accounts: `akshata`, `rahul`, `priya` — password `demo123`.

---

## 👥 Team

- **Akshata Deshpande**
- **[Teammate Name]**

---

## 📚 Course

**CB3203B — Cloud Computing** · Vishwakarma Institute of Technology, Pune · Semester V, 2026-27
