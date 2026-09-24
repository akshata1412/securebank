# 🏦 SecureBank

**A cloud-native banking platform with automated disaster recovery and CI/CD pipeline**

Built as part of the Cloud Computing course (CB3203B) at VIT Pune.

---

## 📖 Overview

SecureBank is a mini banking web application deployed on AWS that demonstrates how modern cloud infrastructure enables high availability, automated disaster recovery, and continuous deployment — the same principles used by production-grade fintech systems.

Users can log in, view balance, transfer money, and view transaction history. Every transaction is automatically backed up across multiple regions, and the system recovers from failures without human intervention.

---

## 🎯 Objectives

1. Deploy a banking application on AWS EC2 within a secure VPC
2. Containerize the app with Docker and orchestrate with Kubernetes
3. Implement automated backups using RDS snapshots and S3 cross-region replication
4. Configure Route 53 for automatic regional failover
5. Build a CI/CD pipeline using GitHub Actions
6. Enforce IAM role-based access with MFA, KMS encryption, and CloudTrail auditing

---

## 🏗️ Architecture
Users → Route 53 → Load Balancer → EC2 (Kubernetes) → RDS Primary
↓
S3 Backup (Mumbai)
↓ (cross-region)
RDS Read Replica ← S3 (Singapore)


**Two AWS regions:**
- **Mumbai (Primary):** All live traffic
- **Singapore (Disaster Recovery):** Standby for automatic failover

---

## 🛠️ Tech Stack

| Layer | Technology |
|-------|-----------|
| Cloud Provider | AWS (Free Tier) |
| Compute | EC2, Docker, Kubernetes |
| Database | Amazon RDS (MySQL) |
| Storage | Amazon S3 + Cross-Region Replication |
| Networking | VPC, Route 53, Load Balancer |
| Security | IAM, MFA, KMS, CloudTrail |
| DevOps | GitHub Actions, Docker |
| Monitoring | CloudWatch, Lambda, SNS |
| Application | Python (Flask), HTML/CSS |

---

## 📁 Project Structure
securebank/
├── app/ # Banking web application (Flask)
├── infrastructure/ # AWS setup scripts and configs
├── ci-cd/ # GitHub Actions workflows
├── docs/ # Architecture diagrams and documentation
├── .gitignore
└── README.md


---

## 🚀 Project Status

**Current Phase:** Foundation (Phase 1 of 4)

- ✅ AWS Free Tier account configured
- ✅ VPC with public and private subnets
- ✅ System architecture finalized
- ✅ Technology stack selected
- ✅ GitHub repository initialized
- 🔄 Banking application in development
- 🔄 RDS + S3 backup pipeline
- 🔄 CI/CD pipeline setup
- ⏳ Cross-region DR configuration
- ⏳ Monitoring dashboard

---

## 👥 Team

- **Akshata Deshpande** — [Role e.g. Cloud Infrastructure & DevOps]
- **[Teammate Name]** — [Role e.g. Application & Disaster Recovery]

**Guide:** Prof. [Guide Name]

---

## 📚 Course

**CB3203B — Cloud Computing**
Vishwakarma Institute of Technology, Pune
Semester V, 2025-26
