# web-store

A full-featured shopping cart / e-commerce web application, containerized and
deployed to Amazon EKS.

## Stack

- **Backend:** Node.js (Express)
- **Frontend:** React
- **Database:** PostgreSQL (RDS/Aurora in AWS)
- **Payments:** Mock/fake checkout (no live payment gateway)
- **Containerization:** Docker, docker-compose for local dev
- **Orchestration:** Amazon EKS
- **IaC:** Terraform (VPC, EKS, managed node groups, ALB, RDS/Aurora)
- **Secrets:** AWS Secrets Manager via Secrets Store CSI Driver
- **CI/CD:** GitHub Actions (build → ECR → deploy to EKS)

## Project Structure

```
web-store/
├── backend/          # Express API
├── frontend/         # React app
├── infra/            # Terraform
├── k8s/               # Kubernetes manifests / Helm chart
├── .github/
│   └── workflows/    # CI/CD pipelines
├── docker-compose.yml
└── README.md
```

*(Structure will fill in as the project is scaffolded.)*

## Local Development

```powershell
# clone and enter the repo
git clone https://github.com/danohlin/web-store.git
cd web-store

# start local dev environment
docker-compose up --build
```

Details on required environment variables and local setup will be added as
the backend and frontend are built out.

## Deployment

Infrastructure is provisioned via Terraform in `infra/`. The GitHub Actions
workflow in `.github/workflows/` builds the container images, pushes them to
ECR, and deploys to the EKS cluster on merge to `main`.

Deployment steps and prerequisites will be documented here as the pipeline
is built.

## Status

🚧 Early scaffolding — architecture and build plan in progress.
