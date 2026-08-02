<#
.SYNOPSIS
  Builds the whole environment in AWS: infrastructure, cluster add-ons, and the
  application.

.DESCRIPTION
  Expect roughly 20 minutes, dominated by the EKS control plane. Run down.ps1
  when finished for the day; nothing here survives that.

  Cluster add-ons are installed with helm from this script rather than through
  Terraform's helm provider. Configuring a provider from resources created in
  the same apply is a well-known bootstrapping trap that fails on first run, and
  keeping the ordering explicit here also makes teardown ordering obvious.

.PARAMETER SkipInfra
  Reuse existing infrastructure and only redeploy the application.

.PARAMETER SkipBuild
  Do not rebuild or push images; deploy whatever tag is already in ECR.

.EXAMPLE
  .\scripts\up.ps1
  .\scripts\up.ps1 -SkipInfra          # app-only redeploy
#>
[CmdletBinding()]
param(
  [switch]$SkipInfra,
  [switch]$SkipBuild,
  [string]$Tag
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = git rev-parse --show-toplevel
Set-Location $repoRoot

$persistentDir = Join-Path $repoRoot 'infra/persistent'
$ephemeralDir = Join-Path $repoRoot 'infra/ephemeral'
$chartDir = Join-Path $repoRoot 'helm/web-store'

function Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Info($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }
function Ok($msg) { Write-Host "    $msg" -ForegroundColor Green }

$started = Get-Date

# ---------------------------------------------------------------------------
Step 'Checking prerequisites'
foreach ($tool in 'terraform', 'aws', 'kubectl', 'helm', 'docker') {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
    throw "$tool is not on PATH."
  }
}
$identity = aws sts get-caller-identity --output json | ConvertFrom-Json
if (-not $?) { throw 'AWS credentials are not configured. Run: aws configure --profile terraform-deployer' }
Ok "Authenticated as $($identity.Arn)"

# ---------------------------------------------------------------------------
Step 'Persistent stack (state bucket + ECR)'
Push-Location $persistentDir
try {
  # Backend config is derived rather than committed: the bucket name embeds the
  # account id, and this repository is public.
  terraform init -input=false -reconfigure `
    -backend-config="bucket=web-store-tfstate-$($identity.Account)" `
    -backend-config="key=persistent/terraform.tfstate" `
    -backend-config="region=us-east-1" `
    -backend-config="encrypt=true" `
    -backend-config="use_lockfile=true" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'persistent terraform init failed' }

  terraform apply -auto-approve -input=false | Out-Null
  $stateBucket = terraform output -raw state_bucket
  $registry = terraform output -raw ecr_registry
  $region = terraform output -raw region
  $repos = terraform output -json ecr_repository_urls | ConvertFrom-Json
  $ciRoleArn = terraform output -raw github_actions_role_arn
  Ok "State bucket: $stateBucket"
} finally { Pop-Location }

# ---------------------------------------------------------------------------
Step 'Ephemeral stack (VPC, EKS, RDS)'
Info 'This is the slow part - the EKS control plane alone takes ~10 minutes.'
Push-Location $ephemeralDir
try {
  # The backend is configured on the command line rather than committed,
  # because the bucket name embeds the account id.
  terraform init -input=false -reconfigure `
    -backend-config="bucket=$stateBucket" `
    -backend-config="key=ephemeral/terraform.tfstate" `
    -backend-config="region=$region" `
    -backend-config="encrypt=true" `
    -backend-config="use_lockfile=true" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'terraform init failed' }

  # Grant the CI role cluster access. IAM permissions alone give it nothing
  # inside Kubernetes; without this access entry, GitHub Actions authenticates
  # to AWS successfully and is then refused by the cluster.
  # Passed as TF_VAR_ rather than -var to avoid quoting a JSON list through
  # PowerShell's argument parser.
  $env:TF_VAR_cluster_admin_principals = (ConvertTo-Json @($ciRoleArn) -Compress)

  if (-not $SkipInfra) {
    terraform apply -auto-approve -input=false
    if ($LASTEXITCODE -ne 0) { throw 'terraform apply failed' }
  } else {
    Info 'Skipped (using existing infrastructure)'
  }

  $tf = @{}
  foreach ($k in 'cluster_name', 'region', 'namespace', 'alb_controller_role_arn',
    'csi_driver_role_arn', 'app_role_arn', 'database_secret_name',
    'app_secret_name', 'vpc_id') {
    $tf[$k] = terraform output -raw $k
  }
  $cost = terraform output -raw estimated_hourly_usd
} finally { Pop-Location }

Ok "Cluster: $($tf.cluster_name)"
Info "Cost while running: $cost"

# ---------------------------------------------------------------------------
Step 'Configuring kubectl'
aws eks update-kubeconfig --name $tf.cluster_name --region $tf.region | Out-Null
kubectl get nodes --no-headers | ForEach-Object { Info $_ }

# ---------------------------------------------------------------------------
Step 'Cluster add-ons'

Info 'AWS Load Balancer Controller...'
helm repo add eks https://aws.github.io/eks-charts 2>&1 | Out-Null
helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts 2>&1 | Out-Null
helm repo add aws-secrets-manager https://aws.github.io/secrets-store-csi-driver-provider-aws 2>&1 | Out-Null
helm repo update 2>&1 | Out-Null

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller `
  --namespace kube-system `
  --set clusterName=$($tf.cluster_name) `
  --set serviceAccount.create=true `
  --set serviceAccount.name=aws-load-balancer-controller `
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$($tf.alb_controller_role_arn)" `
  --set region=$($tf.region) `
  --set vpcId=$($tf.vpc_id) `
  --wait --timeout 5m | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'ALB controller install failed' }
Ok 'ALB controller ready'

Info 'Secrets Store CSI driver...'
# syncSecret disabled and only the file mount enabled: values must never be
# copied into Kubernetes Secrets, or they would land in etcd.
helm upgrade --install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver `
  --namespace kube-system `
  --set syncSecret.enabled=false `
  --set enableSecretRotation=false `
  --wait --timeout 5m | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'CSI driver install failed' }

helm upgrade --install secrets-provider-aws aws-secrets-manager/secrets-store-csi-driver-provider-aws `
  --namespace kube-system `
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$($tf.csi_driver_role_arn)" `
  --wait --timeout 5m | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'CSI AWS provider install failed' }
Ok 'Secrets Store CSI driver ready'

# ---------------------------------------------------------------------------
Step 'Building and pushing images'
if (-not $Tag) { $Tag = (git rev-parse --short HEAD) }
Info "Tag: $Tag"

if (-not $SkipBuild) {
  aws ecr get-login-password --region $tf.region | docker login --username AWS --password-stdin $registry | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'ECR login failed' }

  docker build -t "$($repos.backend):$Tag" --target runtime ./backend
  docker build -t "$($repos.migrator):$Tag" --target migrator ./backend
  docker build -t "$($repos.frontend):$Tag" ./frontend
  foreach ($r in $repos.backend, $repos.migrator, $repos.frontend) {
    docker push "${r}:$Tag" | Out-Null
    Ok "pushed $(($r -split '/')[-1]):$Tag"
  }
} else {
  Info 'Skipped'
}

# ---------------------------------------------------------------------------
Step 'Deploying the application'
kubectl create namespace $tf.namespace --dry-run=client -o yaml | kubectl apply -f - | Out-Null

helm upgrade --install web-store $chartDir `
  --namespace $tf.namespace `
  -f "$chartDir/values-dev.yaml" `
  --set backend.image.repository=$($repos.backend) --set backend.image.tag=$Tag `
  --set frontend.image.repository=$($repos.frontend) --set frontend.image.tag=$Tag `
  --set migration.image.repository=$($repos.migrator) --set migration.image.tag=$Tag `
  --set secrets.region=$($tf.region) `
  --set secrets.databaseSecretName=$($tf.database_secret_name) `
  --set secrets.appSecretName=$($tf.app_secret_name) `
  --set serviceAccount.roleArn=$($tf.app_role_arn) `
  --wait --timeout 10m
if ($LASTEXITCODE -ne 0) {
  Write-Host "`nDeploy failed. Migration job logs:" -ForegroundColor Yellow
  kubectl logs -n $tf.namespace -l app.kubernetes.io/component=migrate --tail=50
  throw 'helm upgrade failed'
}

# ---------------------------------------------------------------------------
Step 'Waiting for the load balancer'
Info 'The controller provisions the ALB out of band; this usually takes 2-3 minutes.'
$address = ''
for ($i = 0; $i -lt 60; $i++) {
  $address = kubectl get ingress web-store -n $tf.namespace -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>$null
  if ($address) { break }
  Start-Sleep -Seconds 5
}
if (-not $address) { throw 'ALB did not appear. Check: kubectl describe ingress web-store -n ' + $tf.namespace }

Info "Address: $address"
Info 'Waiting for the ALB target group to pass health checks...'
for ($i = 0; $i -lt 60; $i++) {
  try {
    $r = Invoke-WebRequest "http://$address/healthz" -UseBasicParsing -TimeoutSec 5
    if ($r.StatusCode -eq 200) { break }
  } catch { Start-Sleep -Seconds 5 }
}

$elapsed = [math]::Round(((Get-Date) - $started).TotalMinutes, 1)

Write-Host ""
Write-Host "  Store is live:  http://$address" -ForegroundColor Green
Write-Host ""
Write-Host "  Brought up in $elapsed minutes. Cost while running: $cost" -ForegroundColor DarkGray
Write-Host "  Sign-in details are in Secrets Manager, not printed here:" -ForegroundColor DarkGray
Write-Host "    aws secretsmanager get-secret-value --secret-id $($tf.app_secret_name) --query SecretString --output text" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  When you are done for the day:  .\scripts\down.ps1" -ForegroundColor Yellow
Write-Host ""
