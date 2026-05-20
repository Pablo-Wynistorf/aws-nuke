#!/usr/bin/env bash
# aws-nuke-self-destruct
#
# One command + one typed confirmation -> the entire AWS account is wiped
# across every enabled region. The CloudFormation stack self-destructs at the
# end so nothing is left behind.
#
#   curl -sSL https://raw.githubusercontent.com/Pablo-Wynistorf/aws-nuke/main/aws-nuke.sh | bash
#
# Hard requirements:
#   - Must run inside AWS CloudShell (AWS_EXECUTION_ENV=CloudShell).
#     The active credentials can be CloudShell's own role or any role you've
#     assumed inside CloudShell — whatever the active credentials point at is
#     the account that gets nuked.
#
# The single confirmation is your AWS account ID — TYPED, not pasted.
# Pastes are detected by total elapsed input time and rejected.
#
# Env vars:
#   STACK_NAME         CloudFormation stack name (default: aws-nuke)
#   AWS_NUKE_VERSION   ekristen/aws-nuke version (default: 3.49.0)
#   FORCE=1            Bypass alias prod-check
#   TAIL_LOGS=0        Skip log tailing (still waits for stack delete)
#   TEMPLATE_URL       Override the template source (file:// for local testing)
#   PASTE_GUARD=0      Disable the anti-paste timing check (not recommended)

set -euo pipefail

STACK_NAME="${STACK_NAME:-aws-nuke}"
AWS_NUKE_VERSION="${AWS_NUKE_VERSION:-3.49.0}"
TAIL_LOGS="${TAIL_LOGS:-1}"
FORCE="${FORCE:-0}"
PASTE_GUARD="${PASTE_GUARD:-1}"

TEMPLATE_URL="${TEMPLATE_URL:-https://raw.githubusercontent.com/Pablo-Wynistorf/aws-nuke/main/cloudformation.yaml}"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
die()    { red "ERROR: $*"; exit 1; }

command -v aws  >/dev/null || die "aws CLI not found. Run from CloudShell or any host with aws CLI."
command -v curl >/dev/null || die "curl not found."

# --- Hard requirement: must be running inside AWS CloudShell ---
# CloudShell sets AWS_EXECUTION_ENV=CloudShell. Refuse otherwise.
if [[ "${AWS_EXECUTION_ENV:-}" != "CloudShell" ]]; then
  die "This script only runs inside AWS CloudShell (got AWS_EXECUTION_ENV='${AWS_EXECUTION_ENV:-<unset>}')."
fi

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || true)}}"
[[ -z "${REGION}" ]] && die "No region configured. Set AWS_REGION or run 'aws configure'."

bold "── aws-nuke-self-destruct ──"
echo "Region:        ${REGION}"
echo "Stack name:    ${STACK_NAME}"
echo "Nuke version:  ${AWS_NUKE_VERSION}"
echo "Template URL:  ${TEMPLATE_URL}"
echo

bold "Caller identity"
aws sts get-caller-identity --output table

# Snapshot the account ID NOW. Every subsequent step references this snapshot
# so a mid-run AWS_PROFILE change or sts-assume-role can't redirect the nuke
# at a different account.
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
[[ -z "${ACCOUNT_ID}" ]] && die "Could not determine account id."

ALIAS="$(aws iam list-account-aliases --query 'AccountAliases[0]' --output text 2>/dev/null || echo None)"
[[ "${ALIAS}" == "None" ]] && ALIAS=""

echo
bold "Account: ${ACCOUNT_ID}  Alias: ${ALIAS:-<none>}"

# --- Safety: refuse on prod-looking aliases ---
if [[ "${FORCE}" != "1" ]]; then
  if [[ -n "${ALIAS}" ]] && echo "${ALIAS}" | grep -Eqi 'prod|prd|live'; then
    red "Refusing: account alias '${ALIAS}' looks like production."
    red "Re-run with FORCE=1 if you really mean it."
    exit 2
  fi
fi

# --- Anti-paste typed confirmation ---
# Reads the account id with a normal line-mode read, then rejects the input
# if the total elapsed time is too short to be human typing. Pastes deliver
# all bytes within milliseconds; typing a 12-digit account id takes seconds.
prompt_typed_account_id() {
  local target="$1"
  local per_char_ms=80          # min ms per character for "real typing"
  local entered start_ns end_ns elapsed_ms min_ms

  # Re-attach stdin to the terminal so this works under 'curl | bash'.
  if [[ ! -t 0 ]] && [[ -e /dev/tty ]]; then
    exec </dev/tty
  fi
  if [[ ! -t 0 ]]; then
    die "No terminal available for confirmation. Run with a TTY attached."
  fi

  red    "WARNING: this will WIPE EVERYTHING in account ${ACCOUNT_ID}"
  red    "across every enabled region. There is no undo."
  echo
  yellow "Type the account ID by hand. Pastes will be REJECTED."
  yellow "Press Enter when finished."
  echo
  printf '> '

  start_ns="$(date +%s%N 2>/dev/null || echo 0)"
  IFS= read -r entered || die "Input closed."
  end_ns="$(date +%s%N 2>/dev/null || echo 0)"

  if [[ "${entered}" != "${target}" ]]; then
    die "Account id mismatch. Aborting."
  fi

  if [[ "${PASTE_GUARD}" == "1" && "${start_ns}" != "0" && "${end_ns}" != "0" ]]; then
    elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
    min_ms=$(( ${#target} * per_char_ms ))
    if (( elapsed_ms < min_ms )); then
      red "Input completed in ${elapsed_ms}ms (expected at least ${min_ms}ms)."
      die "That looks pasted. You must TYPE the account id."
    fi
  fi
}

prompt_typed_account_id "${ACCOUNT_ID}"
green "Confirmed."

# --- Fetch and validate template ---
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
TEMPLATE_FILE="${TMP}/cloudformation.yaml"

if [[ "${TEMPLATE_URL}" == file://* ]]; then
  cp "${TEMPLATE_URL#file://}" "${TEMPLATE_FILE}"
else
  echo "Downloading template..."
  curl -sSL --fail -o "${TEMPLATE_FILE}" "${TEMPLATE_URL}" \
    || die "Failed to fetch ${TEMPLATE_URL}"
fi

aws cloudformation validate-template \
  --template-body "file://${TEMPLATE_FILE}" \
  --region "${REGION}" >/dev/null \
  || die "Template failed validation."
green "Template validated."

# --- Deploy ---
echo
bold "Deploying CloudFormation stack (this usually takes 30-90s)..."
# Run deploy in the background so we can show progress dots.
DEPLOY_LOG="$(mktemp)"
(
  aws cloudformation deploy \
    --stack-name "${STACK_NAME}" \
    --template-file "${TEMPLATE_FILE}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --region "${REGION}" \
    --no-fail-on-empty-changeset \
    --parameter-overrides "AwsNukeVersion=${AWS_NUKE_VERSION}" \
    >"${DEPLOY_LOG}" 2>&1
  echo "$?" >"${DEPLOY_LOG}.rc"
) &
DEPLOY_PID=$!
while kill -0 "${DEPLOY_PID}" 2>/dev/null; do
  printf '.'
  sleep 5
done
wait "${DEPLOY_PID}" 2>/dev/null || true
echo
DEPLOY_RC="$(cat "${DEPLOY_LOG}.rc" 2>/dev/null || echo 1)"
if [[ "${DEPLOY_RC}" != "0" ]]; then
  red "CloudFormation deploy failed:"
  cat "${DEPLOY_LOG}"
  rm -f "${DEPLOY_LOG}" "${DEPLOY_LOG}.rc"
  exit 1
fi
cat "${DEPLOY_LOG}"
rm -f "${DEPLOY_LOG}" "${DEPLOY_LOG}.rc"
green "Stack deployed."

get_output() {
  aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --region "${REGION}" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text
}

PROJECT_NAME="$(get_output CodeBuildProjectName)"
LOG_GROUP="$(get_output CodeBuildLogGroupName)"

echo "CodeBuild project: ${PROJECT_NAME}"
echo "Log group:         ${LOG_GROUP}"

# --- Fire the nuke ---
echo
bold "Starting CodeBuild nuke job..."
BUILD_ID="$(aws codebuild start-build \
  --project-name "${PROJECT_NAME}" \
  --region "${REGION}" \
  --query 'build.id' --output text)"
green "Build started: ${BUILD_ID}"

# --- Tail logs while the build runs ---
if [[ "${TAIL_LOGS}" == "1" ]]; then
  echo
  bold "Waiting for the build to start producing logs..."
  # Wait up to ~3 minutes for the log group to have at least one stream.
  for _ in $(seq 1 36); do
    STREAMS="$(aws logs describe-log-streams \
      --log-group-name "${LOG_GROUP}" \
      --region "${REGION}" \
      --max-items 1 \
      --query 'length(logStreams)' \
      --output text 2>/dev/null || echo 0)"
    if [[ "${STREAMS}" =~ ^[0-9]+$ ]] && (( STREAMS > 0 )); then
      break
    fi
    printf '.'
    sleep 5
  done
  echo
  green "Logs ready. Tailing (Ctrl-C stops tailing only — the build keeps running):"
  echo
  aws logs tail "${LOG_GROUP}" --region "${REGION}" --follow --format short || true
fi

# --- Wait for the build to finish ---
echo
bold "Waiting for build ${BUILD_ID} to finish..."
while :; do
  STATUS="$(aws codebuild batch-get-builds \
    --ids "${BUILD_ID}" \
    --region "${REGION}" \
    --query 'builds[0].buildStatus' \
    --output text 2>/dev/null || echo UNKNOWN)"
  case "${STATUS}" in
    IN_PROGRESS) sleep 15 ;;
    SUCCEEDED)   green "Build SUCCEEDED."; break ;;
    FAILED|STOPPED|TIMED_OUT|FAULT)
      red "Build ended with status: ${STATUS}"
      yellow "The stack self-destruct still runs in post_build. Inspect logs with:"
      echo "  aws logs tail ${LOG_GROUP} --region ${REGION}"
      break
      ;;
    *) sleep 15 ;;
  esac
done

# --- Wait for the stack to fully self-destruct ---
echo
bold "Waiting for CloudFormation stack to finish self-destructing..."
yellow "(CFN removes the role, log group, project — usually under a minute.)"

while :; do
  STATUS="$(aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --region "${REGION}" \
    --query 'Stacks[0].StackStatus' \
    --output text 2>/dev/null || echo GONE)"
  case "${STATUS}" in
    GONE)
      green "Stack ${STACK_NAME} is gone."
      break
      ;;
    DELETE_IN_PROGRESS)
      printf '.'
      sleep 15
      ;;
    DELETE_FAILED)
      red "Stack delete failed. Manual cleanup:"
      echo "  aws cloudformation delete-stack --stack-name ${STACK_NAME} --region ${REGION}"
      echo "  aws cloudformation describe-stack-events --stack-name ${STACK_NAME} --region ${REGION}"
      exit 3
      ;;
    *) sleep 15 ;;
  esac
done

echo
green "Done. Account ${ACCOUNT_ID} has been nuked and the stack has self-destructed."
