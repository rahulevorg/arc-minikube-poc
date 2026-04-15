$ErrorActionPreference = 'Stop'

Write-Host "Starting ARC POC Deployment..." -ForegroundColor Green

# 1. Source .env file (assuming it sits at root or parent of poc script)
$envFilePath = Join-Path (Get-Location) "..\.env"
if (Test-Path $envFilePath) {
    Write-Host "Sourcing .env file..."
    Get-Content $envFilePath | ForEach-Object {
        if ($_ -match '^(.*?)=(.*)$') {
            $name = $matches[1].Trim()
            $value = $matches[2].Trim()
            if ($value -match '^"(.*)"$') { $value = $matches[1] }
            Set-Item -Path "env:\$name" -Value $value
        }
    }
} else {
    Write-Host "WARNING: .env file not found. Ensure required env vars are set." -ForegroundColor Yellow
}

$GITHUB_ORG = "rahulevorg"
$GITHUB_REPO = "arc-minikube-poc"

# 2. Check if gh CLI is installed to create the repo
if (Get-Command "gh" -ErrorAction SilentlyContinue) {
    Write-Host "Ensuring the repository $GITHUB_ORG/$GITHUB_REPO exists..." -ForegroundColor Cyan
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    gh repo view "$GITHUB_ORG/$GITHUB_REPO" 2>$null
    $ErrorActionPreference = $previousPreference
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Creating repository $GITHUB_ORG/$GITHUB_REPO..."
        gh repo create "$GITHUB_ORG/$GITHUB_REPO" --public
        
        # Git Init & Push inside the POC folder so the Workflows are tracked
        git init
        git add .
        git commit -m "Initial POC setup"
        git branch -M main
        git remote add origin "https://github.com/$GITHUB_ORG/$GITHUB_REPO.git"
        git push -u origin main
    } else {
        Write-Host "Repository already exists"
    }
} else {
    Write-Host "WARNING: GitHub CLI (gh) not found! Please create $GITHUB_ORG/$GITHUB_REPO manually." -ForegroundColor Yellow
}

# 3. Start Minikube
Write-Host "Starting Minikube (Hyper-V)..." -ForegroundColor Cyan
# minikube start --driver=hyperv --cpus=4 --memory=8g --disk-size=30g

# 4. Namespaces & Privilege Labels
Write-Host "Configuring Kubernetes namespaces..." -ForegroundColor Cyan
kubectl create namespace arc-systems --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace arc-runners --dry-run=client -o yaml | kubectl apply -f -

kubectl label --overwrite ns arc-systems pod-security.kubernetes.io/enforce=privileged
kubectl label --overwrite ns arc-runners pod-security.kubernetes.io/enforce=privileged

# 5. Add Helm Repo
Write-Host "Installing ARC Controller..." -ForegroundColor Cyan
helm upgrade --install arc `
  --namespace arc-systems `
  -f .\values\arc-controller-values.yaml `
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller

# 6. Create Secrets
Write-Host "Creating Authentication Secrets..." -ForegroundColor Cyan
if ($env:GITHUB_APP_ID -and $env:GITHUB_APP_INSTALLATION_ID) {
    kubectl delete secret arc-github-auth -n arc-runners --ignore-not-found
    
    if ($env:GITHUB_APP_PRIVATE_KEY_PATH) {
        kubectl -n arc-runners create secret generic arc-github-auth `
          --from-literal=github_app_id="$env:GITHUB_APP_ID" `
          --from-literal=github_app_installation_id="$env:GITHUB_APP_INSTALLATION_ID" `
          --from-file=github_app_private_key="$env:GITHUB_APP_PRIVATE_KEY_PATH"
    } else {
        kubectl -n arc-runners create secret generic arc-github-auth `
          --from-literal=github_app_id="$env:GITHUB_APP_ID" `
          --from-literal=github_app_installation_id="$env:GITHUB_APP_INSTALLATION_ID" `
          --from-literal=github_app_private_key="$env:GITHUB_APP_PRIVATE_KEY"
    }
} else {
    Write-Host "Did not find complete GitHub App configuration in environment, trying PAT fallback." -ForegroundColor Yellow
    if ($env:GITHUB_PAT) {
        kubectl delete secret arc-github-auth -n arc-runners --ignore-not-found
        kubectl -n arc-runners create secret generic arc-github-auth `
          --from-literal=github_token="$env:GITHUB_PAT"
    } else {
         Write-Host "ERROR: No authentication provided (No App ID or PAT found)." -ForegroundColor Red
         exit 1
    }
}

if ($env:REGISTRY_USERNAME -and $env:REGISTRY_PASSWORD) {
    kubectl delete secret regcred -n arc-runners --ignore-not-found
    kubectl -n arc-runners create secret docker-registry regcred `
      --docker-server="ghcr.io" `
      --docker-username="$env:REGISTRY_USERNAME" `
      --docker-password="$env:REGISTRY_PASSWORD"
} else {
    Write-Host "WARNING: Registry credentials not set. BuildKit image pushing may fail." -ForegroundColor Yellow
}

# 7. Install Kubernetes Mode Scale Set (BuildKit)
Write-Host "Deploying Kubernetes Mode Scale Set (BuildKit)..." -ForegroundColor Cyan
kubectl apply -f .\manifests\hooks-rbac.yaml
kubectl apply -f .\manifests\hook-extension-buildkit.yaml
kubectl apply -f .\manifests\buildkitd.yaml

helm upgrade --install minikube-k8s `
  --namespace arc-runners `
  --set githubConfigUrl="https://github.com/$GITHUB_ORG/$GITHUB_REPO" `
  --set githubConfigSecret="arc-github-auth" `
  -f .\values\runner-k8s-values.yaml `
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set

Write-Host "Deployment complete! You can watch runners spinning up with 'kubectl get pods -n arc-runners -w'" -ForegroundColor Green
