param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath,
    
    [string]$TemplatePath,
    [string]$ReportOutputDir,
    [switch]$Prod,
    [switch]$Preprod
)

if ($Prod -and $Preprod) {
    throw "Use only one mode: -Prod or -Preprod"
}

if (-not ($Prod -or $Preprod)) {
    $Preprod = $true
}

# Resolve base path from the script location
$BasePath = if ($PSScriptRoot) { $PSScriptRoot } else { Get-Location }

if (-not $TemplatePath) {
    $TemplatePath = Join-Path $BasePath "Terraform-Drift-Template.html"
} elseif (-not [System.IO.Path]::IsPathRooted($TemplatePath)) {
    $TemplatePath = Join-Path $BasePath $TemplatePath
}

if (-not $ReportOutputDir) {
    $ReportOutputDir = Join-Path $BasePath "Reports"
} elseif (-not [System.IO.Path]::IsPathRooted($ReportOutputDir)) {
    $ReportOutputDir = Join-Path $BasePath $ReportOutputDir
}

# ==================== VALIDATION FUNCTIONS ====================

function Test-Prerequisites {
    param(
        [string]$TemplatePath,
        [string]$ReportOutputDir,
        [string]$RootPath
    )
    
    try {
        if (-not (Test-Path $TemplatePath)) {
            throw "Template file not found: $TemplatePath"
        }
        
        if (-not (Test-Path $ReportOutputDir)) {
            New-Item -ItemType Directory -Path $ReportOutputDir -Force | Out-Null
        }
        
        if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
            throw "Terraform CLI not found"
        }
        
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            throw "Git CLI not found"
        }
    }
    catch {
        throw $_
    }
}

function Assert-MainBranch {
    param([string]$RootPath)
    
    try {
        Push-Location $RootPath
        
        # Get current branch
        $currentBranch = git rev-parse --abbrev-ref HEAD 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to get current git branch"
        }
        
        $currentBranch = $currentBranch.Trim()
        
        if ($currentBranch -ne "main") {
            Write-Host "Not on main branch (current: $currentBranch). Switching to main..." -ForegroundColor Yellow
            git checkout main 2>&1 | Out-Null
            
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to switch to main branch"
            }
            
            Write-Host "Successfully switched to main branch" -ForegroundColor Green
        }
        else {
            Write-Host "Already on main branch" -ForegroundColor Green
        }
        
        Pop-Location
    }
    catch {
        Pop-Location
        throw $_
    }
}

# ==================== UTILITY FUNCTIONS ====================

function Get-AppName {
    param([string]$RootPath)
    
    try {
        # Handle both Windows and Unix-style paths
        $separator = if ($IsWindows -or -not $IsLinux) { '\' } else { '/' }
        $kitsapp = $RootPath.Split($separator) | Select-String "kits"
        if (-not $kitsapp) {
            throw "Could not extract app name from path"
        }
        return ($kitsapp.ToString().Split('-')[1]).ToUpper()
    }
    catch {
        throw $_
    }
}

function Get-EnvironmentFolders {
    param(
        [string]$RootPath,
        [switch]$Prod
    )
    
    try {
        $folders = Get-ChildItem -Path $RootPath -Directory -ErrorAction Stop

        if ($Prod) {
            return $folders | Where-Object { $_.Name -like "*Production*" -or $_.Name -like "*prod*" }
        }

        return $folders | Where-Object { $_.Name -notlike "*Production*" -and $_.Name -notlike "*prod*" }
    }
    catch {
        throw $_
    }
}

# ==================== TERRAFORM FUNCTIONS ====================

function Invoke-TerraformPlan {
    param([string]$FolderPath)
    
    try {
        Push-Location $FolderPath
        $planOutput = terraform plan -detailed-exitcode -no-color 2>&1
        $exitCode = $LASTEXITCODE
        Pop-Location
        
        return @{
            Output   = $planOutput
            ExitCode = $exitCode
        }
    }
    catch {
        Pop-Location
        throw $_
    }
}

function Test-TerraformConfiguration {
    param([string]$FolderPath)
    
    try {
        $mainTf = Join-Path $FolderPath "main.tf"
        return (Test-Path $mainTf)
    }
    catch {
        throw $_
    }
}

# ==================== PLAN ANALYSIS FUNCTIONS ====================

function Extract-PlanSummary {
    param([string[]]$PlanOutput)
    
    try {
        return ($PlanOutput -split "`n" | Where-Object { $_ -match "Plan:" }).Trim()
    }
    catch {
        throw $_
    }
}

function Parse-PlanMetrics {
    param([string]$SummaryLine)
    
    try {
        $metrics = @{ Adds = 0; Changes = 0; Destroys = 0 }
        
        if ($SummaryLine -match 'Plan:\s+(\d+)\s+to add,\s+(\d+)\s+to change,\s+(\d+)\s+to destroy') {
            $metrics.Adds = [int]$Matches[1]
            $metrics.Changes = [int]$Matches[2]
            $metrics.Destroys = [int]$Matches[3]
        }
        
        return $metrics
    }
    catch {
        throw $_
    }
}

function Get-ImpactLevel {
    param(
        [int]$Destroys,
        [int]$Changes,
        [int]$Adds
    )
    
    try {
        if ($Destroys -gt 0) { return "High" }
        if ($Changes -gt 0) { return "Medium" }
        if ($Adds -gt 0) { return "Low" }
        return "None"
    }
    catch {
        throw $_
    }
}

function Extract-PlanDetails {
    param([string[]]$PlanOutput)
    
    try {
        $startMatch = $PlanOutput | Select-String -Pattern '^Terraform will perform the following actions:' | Select-Object -First 1
        $endMatch = $PlanOutput | Select-String -Pattern '^Plan: .* to add, .* to change, .* to destroy\.' | Select-Object -First 1
        
        if (-not $startMatch -or -not $endMatch) {
            return ""
        }
        
        $startIndex = $startMatch.LineNumber - 1
        $endIndex = $endMatch.LineNumber - 1
        
        $cleanPlanOutput = $PlanOutput[$startIndex..$endIndex] |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Where-Object { $_ -notmatch '# \(\d+ unchanged.*hidden\)' }
        
        return ($cleanPlanOutput -join "`n")
    }
    catch {
        throw $_
    }
}

# ==================== HTML GENERATION FUNCTIONS ====================

function New-SummaryTableRow {
    param(
        [string]$FolderName,
        [string]$Summary,
        [string]$Impact
    )
    
    try {
        return @"
<tr>
    <td>$([System.Web.HttpUtility]::HtmlEncode($FolderName))</td>
    <td>$([System.Web.HttpUtility]::HtmlEncode($Summary))</td>
    <td>$([System.Web.HttpUtility]::HtmlEncode($Impact))</td>
</tr>
"@
    }
    catch {
        throw $_
    }
}

function New-ErrorTableRow {
    param(
        [string]$FolderName,
        [string]$ErrorMessage
    )
    
    try {
        return @"
<tr>
    <td>$([System.Web.HttpUtility]::HtmlEncode($FolderName))</td>
    <td>$([System.Web.HttpUtility]::HtmlEncode($ErrorMessage))</td>
    <td>High</td>
</tr>
"@
    }
    catch {
        throw $_
    }
}

function New-PlanDetailsSection {
    param(
        [string]$FolderName,
        [string]$PlanDetails
    )
    
    try {
        $encodedPlan = [System.Web.HttpUtility]::HtmlEncode($PlanDetails)
        return @"
<h3>$([System.Web.HttpUtility]::HtmlEncode($FolderName)):</h3>
<pre>$encodedPlan</pre>
"@
    }
    catch {
        throw $_
    }
}

# ==================== REPORT GENERATION FUNCTIONS ====================

function Get-TemplateContent {
    param([string]$TemplatePath)
    
    try {
        return Get-Content $TemplatePath -Raw -ErrorAction Stop
    }
    catch {
        throw $_
    }
}

function Merge-ReportData {
    param(
        [string]$Template,
        [string]$AppName,
        [string]$SummaryRows,
        [string]$PlanDetails
    )
    
    try {
        $report = $Template -replace "{{APPNAME}}", [System.Web.HttpUtility]::HtmlEncode($AppName)
        $report = $report -replace "{{GENERATED}}", (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        $report = $report -replace "{{SUMMARY_ROWS}}", $SummaryRows
        $report = $report -replace "{{PLAN_DETAILS}}", $PlanDetails
        
        return $report
    }
    catch {
        throw $_
    }
}

function Save-Report {
    param(
        [string]$ReportPath,
        [string]$Content
    )
    
    try {
        $Content | Out-File -FilePath $ReportPath -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        throw $_
    }
}

# ==================== MAIN EXECUTION ====================

function Invoke-DriftAnalysis {
    param(
        [string]$RootPath,
        [string]$TemplatePath,
        [string]$ReportOutputDir
    )
    
    try {
        # Validate prerequisites
        Test-Prerequisites -TemplatePath $TemplatePath -ReportOutputDir $ReportOutputDir -RootPath $RootPath
        
        # Check and switch to main branch
        Assert-MainBranch -RootPath $RootPath
        
        # Extract app name
        $appName = Get-AppName -RootPath $RootPath
        $modeName = if ($Prod) { 'prod' } else { 'preprod' }
        
        # Load template
        $template = Get-TemplateContent -TemplatePath $TemplatePath
        
        # Initialize HTML content
        $summaryRows = ""
        $planDetails = ""
        
        # Process each environment folder
        $folders = Get-EnvironmentFolders -RootPath $RootPath -Prod:$Prod
        
        foreach ($folder in $folders) {
            # Check if Terraform config exists
            if (-not (Test-TerraformConfiguration -FolderPath $folder.FullName)) {
                continue
            }
            
            # Execute Terraform plan
            $planResult = Invoke-TerraformPlan -FolderPath $folder.FullName
            $exitCode = $planResult.ExitCode
            $planOutput = $planResult.Output
            
            # Process results based on exit code
            if ($exitCode -eq 0) {
                # No drift
                continue
            }
            elseif ($exitCode -eq 1) {
                # Terraform error
                $summaryRows += New-ErrorTableRow -FolderName $folder.Name -ErrorMessage "Terraform execution failed"
                continue
            }
            elseif ($exitCode -eq 2) {
                # Drift detected
                $summary = Extract-PlanSummary -PlanOutput $planOutput
                $metrics = Parse-PlanMetrics -SummaryLine $summary
                $impact = Get-ImpactLevel -Destroys $metrics.Destroys -Changes $metrics.Changes -Adds $metrics.Adds
                
                # Generate HTML rows
                $summaryRows += New-SummaryTableRow -FolderName $folder.Name -Summary $summary -Impact $impact
                
                # Extract and add plan details
                $details = Extract-PlanDetails -PlanOutput $planOutput
                if ($details) {
                    $planDetails += New-PlanDetailsSection -FolderName $folder.Name -PlanDetails $details
                }
            }
        }
        
        # Generate final report
        $reportContent = Merge-ReportData -Template $template -AppName $appName -SummaryRows $summaryRows -PlanDetails $planDetails
        
        # Save report
        $reportFile = Join-Path $ReportOutputDir "Terraform-Drift-Report-$appName-$modeName.html"
        Save-Report -ReportPath $reportFile -Content $reportContent
        
        Write-Host "Report generated: $reportFile"
        return $reportFile
    }
    catch {
        Write-Host "Error: $_" -ForegroundColor Red
        throw
    }
}

# ==================== SCRIPT ENTRY POINT ====================

try {
    Invoke-DriftAnalysis -RootPath $RootPath -TemplatePath $TemplatePath -ReportOutputDir $ReportOutputDir
    exit 0
}
catch {
    exit 1
}
