# 🏦 SecureBank

**A cloud-native banking app on AWS with high availability, disaster recovery, Kubernetes and a CI/CD pipeline.**

Built for the Cloud Computing course (CB3203B) at Vishwakarma Institute of Technology, Pune.

Customers sign in, check their balance, send money and read their passbook. SecureBank is a **three-tier
architecture**: web apps (tier 1), backend microservices in Docker containers (tier 2) and a private database
(tier 3). Each tier talks only to the tier below it, every tier has its own firewall, and only the microservices can
reach the database. The database is replicated to a second Availability Zone and to a second region.

---

## 🏗️ Architecture

```
            Mobile app · iPad app · Laptop browser · Desktop · Smartwatch
                                     │ HTTPS
                     Route 53  (health-checked DNS, /health/deep)
             Sydney ──fails──► Mumbai ──fails──► S3 static page "We'll be back soon"
                     │
 ┌──── Sydney · ap-southeast-2 (primary) ─────────────────────────┐   ┌── Mumbai · ap-south-1 (standby, 2nd account) ──┐
 │  AWS WAF ─► Public load balancer                                │   │  Public load balancer                          │
 │  Tier 1  Web app · AZ a        Web app · AZ b    [web SG]       │   │  Web · AZ a          Web · AZ b                │
 │              └──► Internal load balancer ◄──┘                  │   │  Internal load balancer                        │
 │           /users    /accounts    /passbook                      │   │  user · account · passbook                     │
 │  Tier 2  user-mgmt  account-mgmt passbook-mgmt  ×2 AZ [API SG]  │   │                                                │
 │  Tier 3  RDS MySQL primary · AZ a ═sync═ standby · AZ b         │──►│  MySQL 8.4 replica (async, TLS)                │
 │          private data subnets   [DB SG + network ACL]           │   │  promoted when Sydney is down for 60 s         │
 └─────────────────────────────────────────────────────────────────┘   └────────────────────────────────────────────────┘
```

**Firewalls**

| Layer | Firewall | Allows |
|---|---|---|
| Edge | AWS WAF (managed rules + rate limit) | clean HTTP requests only |
| Public load balancer | security group | HTTP from the internet |
| Tier 1 web | security group | port 80 from the public load balancer only |
| Internal load balancer | security group | port 80 from the web tier only |
| Tier 2 microservices | security group | ports 5001-5003 from the internal load balancer only |
| Tier 3 database | **separate** security group + network ACL on the data subnets | port 3306 from the microservices only |

The one documented exception: a replication relay on the NAT instance's Elastic IP forwards MySQL (TLS) to RDS, and
only the Mumbai standby's IP may connect to it. Secrets (database password, tokens) live in SSM Parameter Store, and
every EC2 deploy goes through AWS Systems Manager, so no SSH port is open on the web or API tiers.

**Disaster recovery**

| Failure | What takes over |
|---|---|
| A web app or microservice container | the load balancer skips it within ~10 s |
| An Availability Zone | the AZ b copies keep serving; RDS Multi-AZ fails over to its standby |
| The whole Sydney region | Route 53 sends customers to Mumbai; the replica is promoted to primary |
| Both regions | Route 53 shows the S3 static page |
| A bad delete (copied by replication) | S3 transaction backups and nightly RDS snapshots |

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
web/            Tier 1: Flask web app (pages only, calls the APIs, no database access)
services/       Tier 2: users, accounts, passbook microservices + shared code, one Docker image each
docker-compose.yml  The whole three-tier stack on one machine
k8s/            Kubernetes: web + 3 microservices + NetworkPolicy
infra/          AWS CLI scripts (run in CloudShell): VPC, tiers, firewalls, replication, failover
tests/          Unit tests for the web tier and the microservices
.github/        CI/CD: lint, tests, compose integration test, 4 images to GHCR
practical6/     Ubuntu + Apache2 Dockerfile
```

---

## ▶️ Running

**Locally (all three tiers)**
```bash
docker compose up --build      # then open http://localhost:8080  (akshata / demo123)
```

**On Kubernetes**
```bash
kubectl create secret generic securebank-db --from-literal=DB_PASSWORD=... --from-literal=SECRET_KEY=... --from-literal=INTERNAL_TOKEN=...
kubectl apply -f k8s/securebank.yaml
```

**Build the AWS infrastructure (CloudShell, in order)**
```bash
bash infra/09-three-tier.sh secrets|network|ilb|api|web|rds|multiaz|nacl|waf|lockdown
bash infra/10-replication-source.sh binlog; bash infra/10-replication-source.sh relay <mumbai-ip>
# on the Mumbai standby (Systems Manager Run Command): 11-mumbai-standby.sh eip | replica | stack
bash infra/12-route53-three-level.sh <mumbai-public-lb-dns>
```

**Deploy the latest image (CloudShell)**
```bash
bash infra/deploy.sh        # pulls the 4 images onto api-a/b, web-1/2 and k3s (through Systems Manager)
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

**Measured in the region-failure drill on the three-tier stack (15 Nov 2026):**

| Step | Result |
|---|---|
| Replication lag Sydney → Mumbai | a new transfer was already in Mumbai on the first check (under 1 s, 0 s behind) |
| Both Sydney web servers stopped → Route 53 sends customers to Mumbai | **39 s** |
| Balance seen in Mumbai | Rs 29,524, identical to Sydney (no data lost) |
| Watcher promotes the Mumbai replica (Sydney down 60 s) | automatic; a Rs 250 transfer then succeeded in Mumbai |
| Sydney back, Route 53 returns customers | **69 s** after recovery started |

Replication is one way (Sydney → Mumbai), so transfers made in Mumbai during an outage are not copied back; after
failback the Mumbai replica is re-seeded from Sydney (`11-mumbai-standby.sh replica`).

The app's **`/dr`** page (Disaster recovery room) compares RDS with the DR bucket on every refresh, shows the
recovery point (replication lag) and the recovery time measured in the last drill, and lists every drill event.
During a full outage it stays reachable through the Kubernetes copy of the app (NodePort 30081).
The **`/infra`** page shows which server or pod served the request, load balancer and Route 53 health,
the database, backups and CloudTrail, all read live from AWS.

**Second region (Mumbai standby)**
```bash
# Sydney CloudShell
bash infra/10-replication-source.sh binlog                 # binary logs + TLS-only replication user
bash infra/10-replication-source.sh relay <mumbai-ip>      # relay on the NAT instance, open only to Mumbai
# Mumbai standby (Systems Manager Run Command, second account)
bash 11-mumbai-standby.sh replica <relay-ip> <repl-password>   # MySQL 8.4 replica, read-only
bash 11-mumbai-standby.sh stack <sydney-alb-dns>               # ALBs, 2 servers, microservices, promotion watcher
# Sydney CloudShell
bash infra/12-route53-three-level.sh                        # Sydney → Mumbai → S3 static page
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
