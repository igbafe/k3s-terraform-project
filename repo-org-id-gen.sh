#!/bin/bash

read -rsp "Enter your GitHub PAT: " GH_TOKEN
echo
export GH_TOKEN

ORG="igbafe"
REPO="final-project-docker"

# Get Organization ID
ORG_RESPONSE=$(curl -fsSL \
  -H "Authorization: Bearer $GH_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/users/$ORG")

ORG_ID=$(echo "$ORG_RESPONSE" | grep -m 1 '"id":' | sed 's/[^0-9]//g')

# Get Repository ID
REPO_RESPONSE=$(curl -fsSL \
  -H "Authorization: Bearer $GH_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$ORG/$REPO")

REPO_ID=$(echo "$REPO_RESPONSE" | grep -m 1 '"id":' | sed 's/[^0-9]//g')

echo
echo "========================================"
echo "GitHub OIDC Configuration Details"
echo "========================================"
echo "Organization:    $ORG"
echo "Organization ID: $ORG_ID"
echo "Repository:      $REPO"
echo "Repository ID:   $REPO_ID"
echo "========================================"

unset GH_TOKEN