#!/usr/bin/env bash
#
# Mastering LLM Deployment — Day 2 configuration
#
# Save this as ~/day2-config.sh on your workstation, fill in the values your
# instructor gives you, then run this at the start of EVERY lab:
#
#     source ~/day2-config.sh
#
# Re-run it after any reconnect. A new Session Manager shell does not inherit
# variables from an old one, and almost every "command not found" or
# "repository does not exist" error on Day 2 traces back to a shell that never
# sourced this file.

# ---------------------------------------------------------------- identity
# Your participant ID, exactly as it appears on your credential slip.
# Everything you create is named after this so twenty people can share one
# account without colliding.
export PAX="pax01"                       # <-- CHANGE THIS

# ---------------------------------------------------------------- account
export AWS_REGION="us-east-1"
export AWS_DEFAULT_REGION="$AWS_REGION"
export ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

# ---------------------------------------------------------------- provided by your instructor
export PROJECT="llm-deploy-day2"
export CLUSTER="${PROJECT}-cluster"
export ARTIFACT_BUCKET=""                # <-- FILL IN
export SERVICE_SG=""                     # <-- FILL IN  (sg-...)
export SUBNET_ID=""                      # <-- FILL IN  (subnet-...)
export EXEC_ROLE_ARN=""                  # <-- FILL IN  (arn:aws:iam::...:role/...)

# ---------------------------------------------------------------- derived
export ECR_HOST="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
export SERVING_REPO="${ECR_HOST}/day2/tf-serving"
export API_REPO="${ECR_HOST}/day2/flask-api"

# Your images are distinguished by TAG, not by repository. Everyone pushes to
# the same two repos; your tag is your participant ID.
export IMAGE_TAG="$PAX"

export TASK_FAMILY="${PAX}-inference"
export SERVICE_NAME="${PAX}-api"
export LOG_GROUP="/ecs/${PROJECT}"

# TF Serving base image. Start with 'latest'; Lab 6 asks you to pin this once
# you have confirmed which tag loads your SavedModel.
export SERVING_TAG="${SERVING_TAG:-latest}"

# ---------------------------------------------------------------- sanity check
day2_check () {
  local missing=0
  for v in PAX ARTIFACT_BUCKET SERVICE_SG SUBNET_ID EXEC_ROLE_ARN; do
    if [[ -z "${!v}" ]]; then
      echo "  MISSING: $v"
      missing=1
    fi
  done
  if [[ "$PAX" == "pax01" ]]; then
    echo "  WARNING: PAX is still the default 'pax01' — is that really you?"
  fi
  if [[ $missing -eq 1 ]]; then
    echo "Fill in the blanks in ~/day2-config.sh, then source it again."
    return 1
  fi
  echo "  identity : $PAX"
  echo "  account  : $ACCOUNT_ID in $AWS_REGION"
  echo "  registry : $ECR_HOST"
  echo "  cluster  : $CLUSTER"
  echo "OK"
}

echo "Day 2 config loaded. Run 'day2_check' to verify."
