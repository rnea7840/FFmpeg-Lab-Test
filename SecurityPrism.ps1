$SERVER=$args[0]
$API_KEY=$args[1]
$PROJECT=$args[2]
$BRANCH=$args[3]
$BREAK_SEVERITIES=$args[4] -split ',' | Where-Object { $_ }  # Split and remove empty entries

$PROJECT_NAME="$PROJECT"
$URL="$SERVER/openapi/admin/project"
$HEADER=@{ Authorization="$API_KEY" }

# Find a dedicated SecurityPrism project for $BRANCH of $PROJECT.
Write-Output "Finding $PROJECT_NAME..."
$PROJECT_ID = (
  (Invoke-RestMethod `
    -Method Get `
    -Uri $URL `
    -ContentType application/json `
    -Headers $HEADER).list |
  Where-Object { $_.project_name -eq $PROJECT_NAME }
).project_id

if (-not $PROJECT_ID) {
  throw "SP project not found: $PROJECT_NAME"
}

# Start SecurityPrism analysis
Write-Output "Analyzing (ID=$PROJECT_ID)..."
$JOBS = (Invoke-RestMethod `
    -Method Get `
    -Uri $URL/$PROJECT_ID/run `
    -ContentType application/json `
    -Headers $HEADER).list

# Wait for both jobs to finish.
foreach ($JOB in $JOBS) {
  $JOB_ID = $JOB.target_id
  $JOB_NAME = $JOB.gubun_name
  if ($JOB.status -ne "000") {
    throw "Failed to start: $JOB_NAME (ID=$JOB_ID)"
  }

  Write-Output "Waiting for $JOB_NAME to finish (ID=$JOB_ID)..."

  $JOB_PATH = if ($JOB.gubun_code -eq 1) { "collect" } else { "analyze" }
  while ($true) {
    $STATUS = (Invoke-RestMethod `
        -Method Get `
        -Uri $URL/$PROJECT_ID/$JOB_PATH/$JOB_ID/check `
        -ContentType application/json `
        -Headers $HEADER).list[0].job_status_code
    if ($STATUS -eq "2000") {
      Write-Output "Succeed. (ID=$JOB_ID)"
      break
    } elseif ($STAUTS -eq "4000") {
      throw "Cancelled. (ID=$JOB_ID)"
    } elseif ($STATUS -eq "9000") {
      throw "Failed. (ID=$JOB_ID)"
    } else {
      Start-Sleep -Seconds 2
    }
  }
}

# Collect the detected violations and produce JSON report.
$VIOLATIONS = (Invoke-RestMethod `
    -Method Get `
    -Uri $SERVER/openapi/bizs/$PROJECT_ID/rule-violation `
    -ContentType application/json `
    -Headers $HEADER).list

# Count the number of violations for each severity level
$violationCounts = @{'High' = 0; 'Normal' = 0; 'Low' = 0}
$VIOLATIONS | ForEach-Object {
    $severity = switch ($_.priority_code) {
      1 { 'High' }    # In SP, Critical
      2 { 'High' }    # In SP, Rec. -High
      3 { 'Normal' }  # In SP, Rec. -Medium
      4 { 'Normal' }  # In SP, Rec. -Low
      5 { 'Low' }     # In SP, Info.
    }
    $violationCounts[$severity]++
}

# Output the counts
Write-Output "Violation Counts:"
$violationCounts.GetEnumerator() | ForEach-Object {
    Write-Output "$($_.Key): $($_.Value)"
}

if ($BREAK_SEVERITIES) {
  # Split the severities by comma and trim any whitespace
  $breakSeveritiesArray = $BREAK_SEVERITIES -split ',' | ForEach-Object { $_.Trim() }

  $breakBuild = $false
  $VIOLATIONS | ForEach-Object {
    $severity = switch ($_.priority_code) {
      1 { 'High' }    # In SP, Critical
      2 { 'High' }    # In SP, Rec. -High
      3 { 'Normal' }  # In SP, Rec. -Medium
      4 { 'Normal' }  # In SP, Rec. -Low
      5 { 'Low' }     # In SP, Info.
    }
    if ($severity -in $breakSeveritiesArray) {
      $breakBuild = $true
    }
  }

  if ($breakBuild) {
    Write-Output "Violations detected that meet the break criteria."
    exit 1  # Exit with non-zero status to indicate failure
  } else {
    Write-Output "No violations detected that meet the break criteria."
  }
} else {
  Write-Output "No break criteria specified. Continuing to the next step."
}

