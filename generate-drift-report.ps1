param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath
)

# Path to HTML template file
$templatePath = "C:\gitdata\Work\Scripts\tfdrift\Terraform-Drift-Template.html"

# Extract app name
[string]$kitsapp = $RootPath.Split('\')|Select-String "kits"  
$appname = ($kitsapp.Split('-')[1]).ToUpper()

$reportFile   = "C:\gitdata\Work\Scripts\tfdrift\Reports\Terraform-Drift-Report-$appname.html"
# Load template
$html = Get-Content $templatePath -Raw

# Placeholders to replace later
$summaryRows  = ""
$planDetails  = ""

# Scan environments
$folders = Get-ChildItem -Path $RootPath -Directory -Exclude "Production"|where-object{$_.Name -notlike "PreProd-Base"}

foreach ($folder in $folders) {

    $mainTf = Join-Path $folder.FullName "main.tf"
    $tfvars = Join-Path $folder.FullName "terraform.tfvars"
#-or !(Test-Path $tfvars)
    if (!(Test-Path $mainTf)) {
        continue
    }

    Write-Host "Checking drift in: $($folder.Name)"

    Push-Location $folder.FullName
    $planOutput = terraform plan -detailed-exitcode -no-color
    $exit = $LASTEXITCODE
    Pop-Location

    if ($exit -eq 0) {
        Write-Host "No drift in $($folder.Name) — skipping"
        continue
    }
    elseif ($exit -eq 1) {
        Write-Host "Terraform plan Error in $($folder.Name)"
        # Build summary table row
    $summaryRows += @"
<tr>
    <td>$($folder.Name)</td>
    <td>$($Error)</td>
    <td>High</td>
</tr>
"@
    }
    else {

    Write-Host "Drift detected in $($folder.Name)"

    # Extract "Plan: X to add..." line
    [string]$summary = ($planOutput -split "`n" | Where-Object { $_ -match "Plan:" }).Trim()

    if ($summary -match 'Plan:\s+(\d+)\s+to add,\s+(\d+)\s+to change,\s+(\d+)\s+to destroy') {
    $adds     = [int]$Matches[1]
    $changes  = [int]$Matches[2]
    $destroys = [int]$Matches[3]
    }
   
    # Impact classification
    $impact = if ($destroys -gt 0) {
        "High"
    }
    elseif ($changes -gt 0) {
        "Medium"
    }
    elseif ($adds -gt 0) {
        "Low"
    }
    else {
        "None"
    }

    # Build summary table row
    $summaryRows += @"
<tr>
    <td>$($folder.Name)</td>
    <td>$summary</td>
    <td>$impact</td>
</tr>
"@
# cleanup the plan output
# Find start
$startIndex = ($planOutput | Select-String -Pattern '^Terraform will perform the following actions:' | Select-Object -First 1).LineNumber - 1
# Find end
$endIndex = ($planOutput | Select-String -Pattern '^Plan: .* to add, .* to change, .* to destroy\.' | Select-Object -First 1).LineNumber - 1

$cleanplanout   = $planOutput[$startIndex..$endIndex] | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Where-Object { $_ -notmatch '# \(\d+ unchanged.*hidden\)' }

# Join lines (preserve formatting)
$cleanplanoutText = $cleanplanout -join "`n"

# Escape Terraform diff characters safely
# $escapedDetails = $cleanplanoutText.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;")

# HTML encode
$escapedPlan = [System.Web.HttpUtility]::HtmlEncode($cleanplanoutText)

    $planDetails += @"
<h3>$($folder.Name):</h3>
<pre>$escapedPlan</pre>
"@
}
}
# Replace placeholders
$html = $html -replace "{{APPNAME}}", $appname
$html = $html -replace "{{GENERATED}}", (Get-Date)
$html = $html -replace "{{SUMMARY_ROWS}}", $summaryRows
$html = $html -replace "{{PLAN_DETAILS}}", $planDetails

# Save final report
$html | Out-File -FilePath $reportFile -Encoding UTF8

Write-Host "Drift report generated: $reportFile"
