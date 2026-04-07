# This script diagnoses why changes are not being pushed to the remote repository.

# Function to display a step
function Show-Step {
    param (
        [string]$Message
    )
    Write-Host "`n[Step] $Message" -ForegroundColor Cyan
}

# Step 1: Check the current branch
Show-Step "Checking the current branch"
$currentBranch = git branch --show-current
Write-Host "Current branch: $currentBranch"

# Step 2: Check if the branch is tracking a remote branch
Show-Step "Checking if the branch is tracking a remote branch"
try {
    $trackingBranch = git rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2>$null
    Write-Host "Tracking branch: $trackingBranch"
} catch {
    Write-Host "No tracking branch" -ForegroundColor Yellow
}

# Step 3: Check for uncommitted changes
Show-Step "Checking for uncommitted changes"
$uncommittedChanges = git status --short
if ($uncommittedChanges) {
    Write-Host "Uncommitted changes:" -ForegroundColor Yellow
    Write-Host $uncommittedChanges
} else {
    Write-Host "No uncommitted changes."
}

# Step 4: Check for unpushed commits
Show-Step "Checking for unpushed commits"
try {
    $unpushedCommits = git log "@{u}..HEAD" --oneline 2>$null
    if ($unpushedCommits) {
        Write-Host "Unpushed commits:" -ForegroundColor Yellow
        Write-Host $unpushedCommits
    } else {
        Write-Host "No unpushed commits."
    }
} catch {
    Write-Host "Unable to determine unpushed commits." -ForegroundColor Red
}

# Step 5: Check remote configuration
Show-Step "Checking remote configuration"
$remoteConfig = git remote -v
Write-Host "Remote configuration:" -ForegroundColor Yellow
Write-Host $remoteConfig

# Step 6: Check authentication
Show-Step "Checking authentication"
$remoteUrl = git config --get remote.origin.url
Write-Host "Remote URL: $remoteUrl"
Write-Host "Attempting to connect to the remote repository..."
try {
    git ls-remote $remoteUrl >$null
    Write-Host "Authentication successful." -ForegroundColor Green
} catch {
    Write-Host "Authentication failed." -ForegroundColor Red
}

# Step 7: Check for merge conflicts
Show-Step "Checking for merge conflicts"
git fetch
$mergeStatus = git status | Select-String "have diverged" -Quiet
if ($mergeStatus) {
    Write-Host "Merge conflicts detected. Your branch and the remote branch have diverged." -ForegroundColor Red
} else {
    Write-Host "No merge conflicts detected."
}

# Final Step: Summary
Show-Step "Diagnosis complete"
Write-Host "Review the output above to identify any issues preventing a successful push." -ForegroundColor Green