#!/usr/bin/env bash
# git-update.sh — stage everything, commit, and push via SSH
set -euo pipefail

# --- config / colors ---
GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; BLUE='\033[34m'; NC='\033[0m'

msg="${1:-}"                                   # optional: commit message via arg
ts="$(date -u +'%Y-%m-%d %H:%M:%SZ')"
default_msg="chore: update ${ts}"

# --- sanity checks ---
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo -e "${RED}✗ Not inside a git repo${NC}"; exit 1;
}

# show repo root and branch
root="$(git rev-parse --show-toplevel)"
cd "$root"
branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'HEAD')"

# identity check (warn only)
name="$(git config user.name || true)"
email="$(git config user.email || true)"
if [[ -z "${name}" || -z "${email}" ]]; then
  echo -e "${YELLOW}! git user.name/email not set. Run:${NC}"
  echo "  git config --global user.name  \"anthony\""
  echo "  git config --global user.email \"anthony@unixbox.net\""
fi

# remote check (warn if not SSH)
remote_url="$(git remote get-url origin 2>/dev/null || true)"
if [[ -z "${remote_url}" ]]; then
  echo -e "${RED}✗ No 'origin' remote. Add it, e.g.:${NC}"
  echo "  git remote add origin git@github.com:unixbox-net/linux-tools.git"
  exit 1
fi
if [[ "${remote_url}" != git@github.com:* ]]; then
  echo -e "${YELLOW}! origin is not SSH (${remote_url}). Consider:${NC}"
  echo "  git remote set-url origin git@github.com:unixbox-net/linux-tools.git"
fi

# --- add and commit ---
echo -e "${BLUE}• Staging all changes…${NC}"
git add -A

# nothing to commit?
if git diff --cached --quiet && git diff --quiet; then
  echo -e "${YELLOW}! No changes to commit.${NC}"
  exit 0
fi

commit_msg="${msg:-$default_msg}"
echo -e "${BLUE}• Committing: '${commit_msg}'${NC}"
git commit -m "${commit_msg}" || {
  echo -e "${YELLOW}! Nothing new to commit (maybe hooks blocked it).${NC}"
  exit 0
}

# detached HEAD? make a branch
if [[ "${branch}" == "HEAD" ]]; then
  branch="update-$(date +%Y%m%d-%H%M%S)"
  echo -e "${YELLOW}! Detached HEAD; creating branch ${branch}${NC}"
  git switch -c "${branch}"
else
  echo -e "${BLUE}• On branch ${branch}${NC}"
fi

# --- push (with upstream if needed) ---
echo -e "${BLUE}• Pushing to origin/${branch}…${NC}"
if ! git push -u origin "${branch}"; then
  # likely protected branch; fall back to a new one
  fb="update-$(date +%Y%m%d-%H%M%S)"
  echo -e "${YELLOW}! Push failed, creating ${fb} and pushing there${NC}"
  git switch -c "${fb}"
  git push -u origin "${fb}"
  echo -e "${GREEN}✓ Pushed to ${fb}.${NC}"
  echo "Open a PR from ${fb} → ${branch} in GitHub."
else
  echo -e "${GREEN}✓ Push complete.${NC}"
fi
