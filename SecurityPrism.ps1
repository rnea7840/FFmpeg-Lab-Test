$SERVER=$args[0]
$API_KEY=$args[1]
$PROJECT=$args[2]
$BRANCH=$args[3]
$REPORT_FILE=$args[4]

$PROJECT_NAME="$PROJECT-$BRANCH"
$URL="$SERVER/openapi/v1/admin/project"
$HEADER=@{ Authorization="$API_KEY" }


# -------------------------------------------------------------------------
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

if (-not $PROJECT_ID)
{
  throw "SP project not found: $PROJECT_NAME"

  # Or create new SP project using: PUT admin/project
}


# -------------------------------------------------------------------------
# Start SecurityPrism analysis

Write-Output "Analyzing (ID=$PROJECT_ID)..."
$JOBS =
  (Invoke-RestMethod `
    -Method Get `
    -Uri $URL/$PROJECT_ID/run `
    -ContentType application/json `
    -Headers $HEADER).list


# -------------------------------------------------------------------------
# Two jobs are invoked - collection and analysis.
# Wait for both jobs to finish.

foreach ($JOB in $JOBS)
{
  $JOB_ID = $JOB.target_id
  $JOB_NAME = $JOB.gubun_name
  if ($JOB.status -ne "000")
  {
    throw "Failed to start: $JOB_NAME (ID=$JOB_ID)"
  }

  Write-Output "Waiting for $JOB_NAME to finish (ID=$JOB_ID)..."

  $JOB_PATH = if ($JOB.gubun_code -eq 1) { "collect" } else { "analyze" }
  while ($true)
  {
    $STATUS =
      (Invoke-RestMethod `
        -Method Get `
        -Uri $URL/$PROJECT_ID/$JOB_PATH/$JOB_ID/check `
        -ContentType application/json `
        -Headers $HEADER).list[0].job_status_code
    if ($STATUS -eq "2000")
    {
      Write-Output "Succeed. (ID=$JOB_ID)"
      break
    }
    elseif ($STAUTS -eq "4000")
    {
      throw "Cancelled. (ID=$JOB_ID)"
    }
    elseif ($STATUS -eq "9000")
    {
      throw "Failed. (ID=$JOB_ID)"
    }
    else
    {
      Start-Sleep -Seconds 2
    }
  }
}


# -------------------------------------------------------------------------
# Collect the detected violations and produce JSON report.
# The report can be aggregated by Warnings plugin in Jenkins CI.

$VIOLATIONS =
  (Invoke-RestMethod `
    -Method Get `
    -Uri $URL/$PROJECT_ID/rule-violation `
    -ContentType application/json `
    -Headers $HEADER).list

@{
  issues = $VIOLATIONS.ForEach({
    # See: https://github.com/jenkinsci/analysis-model/blob/main/src/main/java/edu/hm/hafner/analysis/Issue.java
    @{
      # 'spath' starts with '/'.
      fileName = $_.spath.SubString(1) + $_.sname;
      lineStart = $_.line_num;
      lineEnd = $_.line_num;
      type = $_.rule_name;
      message = $_.rule_name;
      severity = switch ($_.priority_code)
      {
        1 { 'High' }    # In SP, Critical
        2 { 'High' }    # In SP, Rec. -High
        3 { 'Normal' }  # In SP, Rec. -Medium
        4 { 'Normal' }  # In SP, Rec. -Low
        5 { 'Low' }     # In SP, Info.
      };
      fingerprint = $_.defect_key;
      origin = "sp";
      originName = "SecurityPrism";
    }
  })
} | ConvertTo-Json | Out-File -Encoding utf8 -FilePath $REPORT_FILE
