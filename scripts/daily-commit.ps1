# scripts\daily-commit.ps1  
```

**Add this content:**  
```powershell  
# daily-commit.ps1  
# Script for daily Git workflow

param(  
    [Parameter(Mandatory=$true)]  
    [string]$CommitMessage  
)

Write-Host "Starting daily Git workflow..." -ForegroundColor Yellow

# Check status  
Write-Host "`nCurrent status:" -ForegroundColor Cyan  
git status

# Add all changes  
Write-Host "`nAdding changes to staging..." -ForegroundColor Cyan  
git add .

# Commit changes  
Write-Host "`nCommitting changes..." -ForegroundColor Cyan  
git commit -m "$CommitMessage"

# Show commit history  
Write-Host "`nRecent commits:" -ForegroundColor Green  
git log --oneline -5

Write-Host "`nDaily commit completed!" -ForegroundColor Green  
```