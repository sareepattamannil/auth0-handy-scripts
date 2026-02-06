#!/bin/bash

# ==============================================================================
# 🔍 BUMP-FINDER: Locate the PR for a version bump and run Layer0 trace.
#
# CONFIGURATION:
#   To change which files are scanned, modify the "REPO MAPPING" section below.
# ==============================================================================

# --- USER CONFIG ---
OPEN_PR=false    # Set to true to auto-open the PR in your browser
RUN_TRACE=true   # Set to true to automatically run layer0 service trace

# --- COLORS ---
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# --- USAGE HELP ---
if [[ -z "$1" || -z "$2" || -z "$3" ]]; then
    echo -e "${BLUE}🔍 Bump-Finder Usage Guide${NC}"
    echo -e "Usage:  ./find-bump.sh ${YELLOW}<repo_nick|path> <package> <version>${NC}"
    echo -e "\nSupported Nicks: server, api2, manhattan"
    exit 1
fi

# --- PRE-FLIGHT CHECKS ---
check_dependency() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}❌ Error: '$1' is not installed.${NC}"
        echo "Please install it via: brew install $2"
        exit 1
    fi
}
check_dependency "gh" "gh"
check_dependency "jq" "jq"

if ! gh api user --jq '.login' &> /dev/null; then
    echo -e "${RED}❌ Error: Not authenticated with GitHub CLI.${NC}"
    echo "Please run: gh auth login"
    exit 1
fi

# --- REPO MAPPING (MODIFY FILE PATHS HERE) ---
case $1 in
  server)    
    REPO_PATH="/Users/safder.areepattamannil/dev/okta/auth0-server"
    MAIN_FILE="packages/server/package.json" ;;
  api2)      
    REPO_PATH="/Users/safder.areepattamannil/dev/okta/api2" 
    MAIN_FILE="packages/main-api/package.json" ;;
  manhattan) 
    REPO_PATH="/Users/safder.areepattamannil/dev/okta/manhattan" 
    MAIN_FILE="package.json" ;;
  *)         
    REPO_PATH=$1 
    MAIN_FILE="package.json" ;;
esac

PACKAGE_NAME=$2
TARGET_VERSION=$3

# --- VALIDATION ---
if [ ! -d "$REPO_PATH" ]; then
    echo -e "${RED}❌ Error: Repository path not found: $REPO_PATH${NC}"
    exit 1
fi

if [ ! -f "$REPO_PATH/$MAIN_FILE" ]; then
    echo -e "${YELLOW}⚠️  $MAIN_FILE not found, falling back to root package.json${NC}"
    MAIN_FILE="package.json"
fi

echo -e "${BLUE}🔄 Syncing origin/master...${NC}"
git -C "$REPO_PATH" fetch origin master --quiet

# --- VERSION LOGIC ---
version_ge() {
    [ "$1" = "$2" ] && return 0
    local IFS=.
    local i t1=($1) t2=($2)
    for ((i=${#t1[@]}; i<${#t2[@]}; i++)); do t1[i]=0; done
    for ((i=0; i<${#t1[@]}; i++)); do
        if [[ -z ${t2[i]} ]]; then t2[i]=0; fi
        if ((10#${t1[i]} > 10#${t2[i]})); then return 0; fi
        if ((10#${t1[i]} < 10#${t2[i]})); then return 1; fi
    done
    return 0
}

get_version_at_commit() {
    git -C "$REPO_PATH" show "$1:$2" 2>/dev/null | jq -r "
        (.dependencies[\"$PACKAGE_NAME\"] // .devDependencies[\"$PACKAGE_NAME\"] // empty)
    " | sed 's/[^0-9.]//g'
}

# --- SCANNING ---
echo -e "${BLUE}🔍 Searching $MAIN_FILE for $PACKAGE_NAME >= $TARGET_VERSION...${NC}"

PREV_HASH=""
PREV_VER=""
FINAL_OLD_VER=""

for HASH in $(git -C "$REPO_PATH" log origin/master -n 150 --pretty=format:"%H" -- "$MAIN_FILE"); do
    CURRENT_VAL=$(get_version_at_commit "$HASH" "$MAIN_FILE")

    if [ -n "$CURRENT_VAL" ]; then
        if version_ge "$CURRENT_VAL" "$TARGET_VERSION"; then
            echo -e "  ${GREEN}✔${NC} ${HASH:0:7} is $CURRENT_VAL"
            PREV_HASH=$HASH
            PREV_VER=$CURRENT_VAL
        else
            echo -e "  ${YELLOW}⬇${NC} ${HASH:0:7} dropped to $CURRENT_VAL"
            FINAL_OLD_VER=$CURRENT_VAL
            break
        fi
    fi
done

if [ -z "$PREV_HASH" ]; then
    echo -e "${YELLOW}❌ No version matching $TARGET_VERSION found in $MAIN_FILE history.${NC}"
    exit 1
fi

# --- OUTPUT & PR RESOLUTION ---
REMOTE_URL=$(git -C "$REPO_PATH" remote get-url origin)
REPO_IDENTIFIER=$(echo "$REMOTE_URL" | sed -E 's/.*[:\/]([^\/]+\/[^\/]+)(\.git)?$/\1/' | sed 's/\.git$//')

echo -e "\n${BLUE}🎯 Identifying PR for transition commit ${PREV_HASH:0:7}...${NC}"
PR_JSON=$(GH_PAGER=cat gh api "repos/$REPO_IDENTIFIER/commits/$PREV_HASH/pulls" --jq '.[0] | select(. != null)')

echo "--------------------------------------------------------"
if [ -n "$PR_JSON" ]; then
    PR_URL=$(echo "$PR_JSON" | jq -r '.html_url')
    echo -e "${GREEN}SUCCESS!${NC}"
    echo -e "Version Bump in $MAIN_FILE: ${YELLOW}${FINAL_OLD_VER:-None}${NC} ➔ ${GREEN}${PREV_VER}${NC}"
    echo "--------------------------------------------------------"
    echo "$PR_JSON" | jq -r '"PR #\(.number): \(.title)\nAuthor: \(.user.login)\nMerged: \(.merged_at)\nLink:   \(.html_url)"'
    
    if [ "$RUN_TRACE" = true ]; then
        echo -e "\n${BLUE}🚀 Running Layer0 Service Trace...${NC}"
        echo -e "${YELLOW}Command:${NC} layer0 service trace $PR_URL --prod\n"
        layer0 service trace "$PR_URL" --prod
    fi

    if [ "$OPEN_PR" = true ]; then open "$PR_URL"; fi
else
    COMMIT_URL="https://github.com/$REPO_IDENTIFIER/commit/$PREV_HASH"
    echo -e "${YELLOW}No linked PR found for commit $PREV_HASH.${NC}"
    echo "Link: $COMMIT_URL"
    
    if [ "$RUN_TRACE" = true ]; then
        echo -e "\n${YELLOW}⚠️  Cannot run trace: No PR link found for this commit.${NC}"
    fi

    if [ "$OPEN_PR" = true ]; then open "$COMMIT_URL"; fi
fi
echo "--------------------------------------------------------"