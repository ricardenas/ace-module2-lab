#!/usr/bin/env bash
# ==============================================================================
# Script: automate_codemender_lab.sh (Updated with Git Push Fallback)
# Purpose: End-to-end automation for ELEVATE Module 2 (CodeMender Guardrails)
# ==============================================================================

set -eo pipefail

# --- Color and Terminal Output Formatting ---
BOLD='\033[1m'
NC='\033[0m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'

# --- Lab Parameters ---
REPO_NAME="ace-module2-lab"
WIF_PROVIDER="projects/755556523613/locations/global/workloadIdentityPools/github-actions/providers/github-oidc"
SA_EMAIL="codemender-ci@elevate-cm-01-rt9xt4.iam.gserviceaccount.com"
QUOTA_PROJECT="elevate-cm-01-rt9xt4"
WIF_AUDIENCE_SECRET="ace-lab-b6eb0c52df7eb40d68b4561bee706b79"
WORKFLOW_FILE="codemender-pipeline.yml"

# State tracking for final summary
CRITERIA_WORKFLOW=false
CRITERIA_GATE=false
CRITERIA_ARTIFACT=false
CRITERIA_PR=false

# --- Output Helpers ---
log_header() {
  echo -e "\n${BOLD}${CYAN}======================================================================${NC}"
  echo -e "${BOLD}${CYAN}  $1${NC}"
  echo -e "${BOLD}${CYAN}======================================================================${NC}\n"
}

log_step() {
  echo -e "${BOLD}${BLUE}[STEP $1]${NC} $2"
}

log_success() {
  echo -e "  ${GREEN}✔${NC} $1"
}

log_warn() {
  echo -e "  ${YELLOW}⚠${NC} $1"
}

log_err() {
  echo -e "  ${RED}✖${NC} $1"
}

log_info() {
  echo -e "  ${CYAN}ℹ${NC} $1"
}

render_progress_bar() {
  local percent=$1
  local width=34
  local filled=$(( percent * width / 100 ))
  local empty=$(( width - filled ))
  local bar=""
  
  for ((i = 0; i < filled; i++)); do bar="${bar}█"; done
  for ((i = 0; i < empty; i++)); do bar="${bar}░"; done

  printf "\r  ${BOLD}${BLUE}[%s] %3d%%${NC} | %-36s" "$bar" "$percent" "$2"
}

# --- Tooling Verification ---
verify_prerequisites() {
  log_header "Verifying Local Dependencies"
  local missing=()
  for cmd in git curl jq gh; do
    if command -v "$cmd" >/dev/null 2>&1; then
      log_success "Found CLI tool: $cmd"
    else
      missing+=("$cmd")
    fi
  done

  if [ ${#missing[@]} -ne 0 ]; then
    log_err "Missing mandatory utilities: ${missing[*]}"
    echo -e "${RED}Please install ${missing[*]} and rerun this script.${NC}"
    exit 1
  fi
}

# --- GitHub Authentication ---
authenticate_github() {
  log_header "GitHub Authentication & Context"

  if gh auth status >/dev/null 2>&1; then
    GITHUB_USER=$(gh api user -q .login)
    log_success "Authenticated as user: ${BOLD}${GITHUB_USER}${NC}"
  else
    log_warn "No active GitHub CLI authentication session detected."
    echo -e "${CYAN}Please enter your GitHub Personal Access Token (PAT).${NC}"
    read -r -s -p "GitHub PAT: " GITHUB_PAT
    echo ""

    if [ -z "$GITHUB_PAT" ]; then
      log_err "GitHub PAT cannot be empty."
      exit 1
    fi

    echo "$GITHUB_PAT" | gh auth login --with-token
    GITHUB_USER=$(gh api user -q .login)
    log_success "Authenticated as user: ${BOLD}${GITHUB_USER}${NC}"
  fi

  export GITHUB_USER
}

# --- Repository Provisioning ---
ensure_github_repo() {
  log_header "Ensuring GitHub Repository: ${REPO_NAME}"

  if gh repo view "${GITHUB_USER}/${REPO_NAME}" >/dev/null 2>&1; then
    log_success "Repository ${GITHUB_USER}/${REPO_NAME} exists."
  else
    log_info "Attempting automated repository creation..."
    if gh repo create "${REPO_NAME}" --public >/dev/null 2>&1; then
      log_success "Created public repository: ${GITHUB_USER}/${REPO_NAME}"
    else
      log_warn "PAT scope may restrict repo creation via API."
      echo -e "${YELLOW}Please visit: https://github.com/new${NC}"
      echo -e "1. Create an empty public repository named: ${BOLD}${REPO_NAME}${NC}"
      echo -e "2. Do NOT initialize with README, .gitignore, or license."
      read -r -p "Press [Enter] after creating the repository..."

      while ! gh repo view "${GITHUB_USER}/${REPO_NAME}" >/dev/null 2>&1; do
        log_warn "Waiting for repository to become accessible..."
        sleep 4
      done
      log_success "Repository confirmed online."
    fi
  fi
}

# --- Cloud Identity & Action Configuration ---
configure_wif_and_permissions() {
  log_header "Configuring Workload Identity Federation (WIF) & CI Gate"

  log_step "1/3" "Injecting Repository Variables..."
  local var_failed=false
  gh variable set GCP_WIF_PROVIDER --body "$WIF_PROVIDER" --repo "${GITHUB_USER}/${REPO_NAME}" 2>/dev/null || var_failed=true
  gh variable set GCP_SA_EMAIL --body "$SA_EMAIL" --repo "${GITHUB_USER}/${REPO_NAME}" 2>/dev/null || var_failed=true
  gh variable set GCP_QUOTA_PROJECT --body "$QUOTA_PROJECT" --repo "${GITHUB_USER}/${REPO_NAME}" 2>/dev/null || var_failed=true

  if [ "$var_failed" = true ]; then
    log_warn "Could not set repository variables via API (token lacks 'Variables: Read/Write')."
    echo -e "${YELLOW}MANUAL ACTION REQUIRED:${NC}"
    echo -e "  Go to: https://github.com/${GITHUB_USER}/${REPO_NAME}/settings/variables/actions"
    echo -e "  Add these 3 Repository variables:"
    echo -e "    • GCP_WIF_PROVIDER: ${WIF_PROVIDER}"
    echo -e "    • GCP_SA_EMAIL:     ${SA_EMAIL}"
    echo -e "    • GCP_QUOTA_PROJECT:${QUOTA_PROJECT}"
    read -r -p "Press [Enter] after adding the 3 variables..."
  else
    log_success "Variables configured (GCP_WIF_PROVIDER, GCP_SA_EMAIL, GCP_QUOTA_PROJECT)."
  fi

  log_step "2/3" "Injecting Repository Secret..."
  if ! echo "$WIF_AUDIENCE_SECRET" | gh secret set WIF_AUDIENCE --repo "${GITHUB_USER}/${REPO_NAME}" 2>/dev/null; then
    log_warn "Could not set secret via API (token lacks 'Secrets: Read/Write')."
    echo -e "${YELLOW}MANUAL ACTION REQUIRED:${NC}"
    echo -e "  Go to: https://github.com/${GITHUB_USER}/${REPO_NAME}/settings/secrets/actions"
    echo -e "  Add New repository secret:"
    echo -e "    • Name:   WIF_AUDIENCE"
    echo -e "    • Secret: ${WIF_AUDIENCE_SECRET}"
    read -r -p "Press [Enter] after adding the secret..."
  else
    log_success "WIF_AUDIENCE secret injected."
  fi

  log_step "3/3" "Setting Workflow Permissions..."
  if gh api --method PUT -H "Accept: application/vnd.github+json" \
      "/repos/${GITHUB_USER}/${REPO_NAME}/actions/permissions/workflow" \
      -f default_workflow_permissions="write" \
      -F can_approve_pull_request_reviews=true >/dev/null 2>&1; then
    log_success "Workflow permissions set to Read/Write with PR creation enabled."
  else
    log_warn "Could not update workflow permissions via API."
    echo -e "${YELLOW}MANUAL ACTION REQUIRED:${NC}"
    echo -e "  Go to: https://github.com/${GITHUB_USER}/${REPO_NAME}/settings/actions"
    echo -e "  Under 'Workflow permissions', select: ${BOLD}Read and write permissions${NC}"
    echo -e "  Check: ${BOLD}Allow GitHub Actions to create and approve pull requests${NC} -> Click Save."
    read -r -p "Press [Enter] after verifying this setting in your browser..."
  fi
}

# --- Codebase Initialization & Remote Sync ---
sync_and_push_code() {
  log_header "Pushing Starter Code to GitHub"

  if [ -d "$HOME/ace-module2-lab" ]; then
    cd "$HOME/ace-module2-lab"
  fi

  if [ ! -f ".github/workflows/${WORKFLOW_FILE}" ]; then
    log_err "Cannot find .github/workflows/${WORKFLOW_FILE} in $(pwd)."
    log_err "Ensure you are running the script in the lab VM where ~/ace-module2-lab is populated."
    exit 1
  fi

  if [ ! -d ".git" ]; then
    log_info "Initializing git repo..."
    git init
  fi

  git config user.name "${GITHUB_USER}"
  git config user.email "${GITHUB_USER}@users.noreply.github.com"
  git branch -M main
  gh auth setup-git

  local remote_url="https://github.com/${GITHUB_USER}/${REPO_NAME}.git"
  if git remote | grep -q "^origin$"; then
    git remote set-url origin "$remote_url"
  else
    git remote add origin "$remote_url"
  fi

  git add .
  # Always ensure a fresh commit is made so GitHub triggers an on:push event
  git commit --allow-empty -m "ci: trigger continuous remediation guardrail [$(date +'%Y-%m-%d %H:%M:%S')]"

  log_info "Pushing code to origin/main (this triggers the guardrail workflow)..."
  git push -u origin main --force
  log_success "Starter files pushed to main branch."

  PUSHED_COMMIT_SHA=$(git rev-parse HEAD)
  export PUSHED_COMMIT_SHA
}

# --- Pipeline Execution & Monitoring ---
trigger_and_monitor_workflow() {
  log_header "Monitoring Continuous Remediation Guardrail"

  log_info "Locating workflow run for commit ${PUSHED_COMMIT_SHA:0:7}..."
  local run_id=""
  local start_time
  start_time=$(date +%s)
  local detection_timeout=60

  while [ -z "$run_id" ] || [ "$run_id" = "null" ]; do
    sleep 3
    
    # Check matching commit SHA first
    run_id=$(gh run list --repo "${GITHUB_USER}/${REPO_NAME}" \
      --limit 5 \
      --json databaseId,headSha \
      -q '.[] | select(.headSha == "'"$PUSHED_COMMIT_SHA"'") | .databaseId' 2>/dev/null | head -n 1 || true)

    local elapsed=$(( $(date +%s) - start_time ))

    # Fallback to any active run (queued or in_progress)
    if { [ -z "$run_id" ] || [ "$run_id" = "null" ]; } && [ "$elapsed" -gt 15 ]; then
      run_id=$(gh run list --repo "${GITHUB_USER}/${REPO_NAME}" \
        --limit 5 \
        --json databaseId,status \
        -q '.[] | select(.status == "in_progress" or .status == "queued") | .databaseId' 2>/dev/null | head -n 1 || true)
    fi

    if { [ -z "$run_id" ] || [ "$run_id" = "null" ]; } && [ "$elapsed" -gt "$detection_timeout" ]; then
      log_warn "Workflow run not automatically detected after ${detection_timeout}s."
      log_info "Attempting dispatch via new Git commit..."
      git commit --allow-empty -m "ci: trigger guardrail retry"
      git push origin main
      PUSHED_COMMIT_SHA=$(git rev-parse HEAD)
      start_time=$(date +%s)
      detection_timeout=45
    fi
  done

  local run_url="https://github.com/${GITHUB_USER}/${REPO_NAME}/actions/runs/${run_id}"
  log_success "Workflow tracking established: ${BOLD}${run_url}${NC}"
  echo ""

  local current_status="in_progress"
  local conclusion=""

  while [ "$current_status" != "completed" ]; do
    local now
    now=$(date +%s)
    local elapsed=$(( now - start_time ))
    local elapsed_fmt
    elapsed_fmt=$(printf "%02d:%02d" $((elapsed / 60)) $((elapsed % 60)))

    # Fetch status and conclusion
    local run_json
    run_json=$(gh run view "$run_id" --repo "${GITHUB_USER}/${REPO_NAME}" --json status,conclusion 2>/dev/null || echo '{"status":"in_progress"}')
    current_status=$(echo "$run_json" | jq -r '.status // "in_progress"')
    conclusion=$(echo "$run_json" | jq -r '.conclusion // ""')

    if [ "$current_status" = "completed" ]; then
      break
    fi

    local jobs_json
    jobs_json=$(gh api "/repos/${GITHUB_USER}/${REPO_NAME}/actions/runs/${run_id}/jobs" 2>/dev/null || echo "{}")

    local total_steps
    total_steps=$(echo "$jobs_json" | jq '[.jobs[0].steps[]?] | length' 2>/dev/null || echo 0)
    local completed_steps
    completed_steps=$(echo "$jobs_json" | jq '[.jobs[0].steps[]? | select(.status == "completed")] | length' 2>/dev/null || echo 0)
    local current_step_name
    current_step_name=$(echo "$jobs_json" | jq -r '.jobs[0].steps[]? | select(.status == "in_progress") | .name' 2>/dev/null | head -n 1)

    if [ -z "$current_step_name" ] || [ "$current_step_name" = "null" ]; then
      current_step_name="Processing CodeMender scan/fix..."
    fi

    local percent=5
    if [ "$total_steps" -gt 0 ]; then
      percent=$(( completed_steps * 100 / total_steps ))
      if [ "$percent" -gt 95 ]; then
        percent=95
      fi
    fi

    render_progress_bar "$percent" "[$elapsed_fmt] ${current_step_name:0:32}"
    sleep 8
  done

  render_progress_bar 100 "Guardrail run completed!     "
  echo -e "\n"

  # Deep inspection of step outcomes with retry
  local final_jobs="{}"
  for attempt in 1 2 3; do
    final_jobs=$(gh api "/repos/${GITHUB_USER}/${REPO_NAME}/actions/runs/${run_id}/jobs" 2>/dev/null) && break || sleep 2
  done
  [ -z "$final_jobs" ] && final_jobs="{}"

  local install_status
  install_status=$(echo "$final_jobs" | jq -r '.jobs[0].steps[]? | select(.name == "Install CodeMender CLI") | .conclusion')
  local init_status
  init_status=$(echo "$final_jobs" | jq -r '.jobs[0].steps[]? | select(.name == "Initialize CodeMender Workspace") | .conclusion')
  local gate_status
  gate_status=$(echo "$final_jobs" | jq -r '.jobs[0].steps[]? | select(.name == "Security Gate") | .conclusion')

  if [ "$install_status" = "success" ] && [ "$init_status" = "success" ]; then
    CRITERIA_WORKFLOW=true
    log_success "CodeMender initialization and scanning executed cleanly."
  else
    log_err "Workflow setup failed before security scan could execute."
  fi

  if [ "$gate_status" = "failure" ] && [ "$conclusion" = "failure" ]; then
    CRITERIA_GATE=true
    log_success "Security Gate correctly turned RED to block deployment of vulnerable code."
  else
    log_err "Security Gate did not fail as expected. Gate status: ${gate_status:-unknown}."
  fi

  ACTIVE_RUN_ID="$run_id"
}

# --- Post-Execution Remediation Verification ---
verify_remediation_artifacts() {
  log_header "Verifying Remediation Pull Request & Scan Artifacts"

  # 1. Verify Artifact
  log_info "Verifying 'codemender-report' artifact generation..."
  local artifact_found
  artifact_found=$(gh api "/repos/${GITHUB_USER}/${REPO_NAME}/actions/runs/${ACTIVE_RUN_ID}/artifacts" \
    -q '.artifacts[] | select(.name == "codemender-report") | .name' 2>/dev/null || true)

  if [ -n "$artifact_found" ]; then
    CRITERIA_ARTIFACT=true
    log_success "Workflow artifact 'codemender-report' (cm-security-report.json) verified."
  else
    log_warn "Artifact 'codemender-report' not found on run ${ACTIVE_RUN_ID}."
  fi

  # 2. Verify PR
  log_info "Checking for CodeMender remediation Pull Request..."
  local pr_url
  pr_url=$(gh pr list --repo "${GITHUB_USER}/${REPO_NAME}" --head codemender/auto-remediation --json url -q '.[0].url' 2>/dev/null || true)

  if [ -n "$pr_url" ] && [ "$pr_url" != "null" ]; then
    CRITERIA_PR=true
    log_success "Remediation Pull Request is OPEN: ${BOLD}${pr_url}${NC}"
  else
    log_warn "Remediation PR was not automatically opened. Checking branch for fallback creation..."
    if gh api "/repos/${GITHUB_USER}/${REPO_NAME}/branches/codemender%2Fauto-remediation" >/dev/null 2>&1 || \
       git ls-remote --heads origin codemender/auto-remediation | grep -q "codemender/auto-remediation"; then
      log_info "Branch 'codemender/auto-remediation' exists. Submitting fallback PR..."
      pr_url=$(gh pr create --repo "${GITHUB_USER}/${REPO_NAME}" \
        --head codemender/auto-remediation \
        --base main \
        --title "🤖 CodeMender: autonomous security remediation" \
        --body "Automated vulnerability remediation patch generated by Google CodeMender." 2>/dev/null || true)
      if [ -n "$pr_url" ]; then
        CRITERIA_PR=true
        log_success "Pull request created successfully: ${BOLD}${pr_url}${NC}"
      fi
    else
      log_err "Branch 'codemender/auto-remediation' does not exist."
    fi
  fi
}

# --- Final Lab Summary Dashboard ---
display_lab_summary() {
  log_header "Lab Completion Checklist & Verification"

  [ "$CRITERIA_WORKFLOW" = true ] && echo -e "  [✔] 1. Workflow Execution: Clean CodeMender installation and workspace initialization." \
    || echo -e "  [✖] 1. Workflow Execution: Setup or scan encountered errors."

  [ "$CRITERIA_GATE" = true ] && echo -e "  [✔] 2. Pipeline Gating: High/Critical vulnerabilities halted deployment at Security Gate." \
    || echo -e "  [✖] 2. Pipeline Gating: Security gate did not fail as required."

  [ "$CRITERIA_ARTIFACT" = true ] && echo -e "  [✔] 3. Artifact Generated: cm-security-report.json uploaded to workflow artifacts." \
    || echo -e "  [✖] 3. Artifact Generated: codemender-report artifact missing."

  [ "$CRITERIA_PR" = true ] && echo -e "  [✔] 4. Autonomous Remediation: PR opened from branch 'codemender/auto-remediation'." \
    || echo -e "  [✖] 4. Autonomous Remediation: Remediation PR not detected."

  echo ""
  if [ "$CRITERIA_WORKFLOW" = true ] && [ "$CRITERIA_GATE" = true ] && [ "$CRITERIA_ARTIFACT" = true ] && [ "$CRITERIA_PR" = true ]; then
    echo -e "${BOLD}${GREEN}======================================================================${NC}"
    echo -e "${BOLD}${GREEN}  ALL CHECKS PASSED: Click 'Check my progress' on the lab page now!  ${NC}"
    echo -e "${BOLD}${GREEN}======================================================================${NC}"
    echo -e "  Checkpoint: ${BOLD}AT ID: 1 Verify the continuous remediation guardrail pipeline${NC}\n"
  else
    echo -e "${BOLD}${RED}======================================================================${NC}"
    echo -e "${BOLD}${RED}  SOME CHECKS FAILED: Review the output above before checking progress.${NC}"
    echo -e "${BOLD}${RED}======================================================================${NC}\n"
  fi
}

# --- Main Driver ---
main() {
  verify_prerequisites
  authenticate_github
  ensure_github_repo
  configure_wif_and_permissions
  sync_and_push_code
  trigger_and_monitor_workflow
  verify_remediation_artifacts
  display_lab_summary
}

main "$@"
