#!/usr/bin/env bash

# Copyright (c) 2023 StreamNative, Inc.. All Rights Reserved.
# cherry pick one or more <pr> onto <remote branch> and proposing a pull request

set -o errexit
set -o nounset
set -o pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
declare -r REPO_ROOT
cd "${REPO_ROOT}"

STARTINGBRANCH=$(git symbolic-ref --short HEAD)
declare -r STARTINGBRANCH
declare -r REBASEMAGIC="${REPO_ROOT}/.git/rebase-apply"
DRY_RUN=${DRY_RUN:-""}
UPSTREAM_REMOTE=${UPSTREAM_REMOTE:-origin}
REPO_ORG=${REPO_ORG:-$(git remote get-url "$UPSTREAM_REMOTE" | awk '{gsub(/http[s]:\/\/|git@/,"")}1' | awk -F'[@:./]' 'NR==1{print $3}')}
REPO_NAME=${REPO_NAME:-$(git remote get-url "$UPSTREAM_REMOTE" | awk '{gsub(/http[s]:\/\/|git@/,"")}1' | awk -F'[@:./]' 'NR==1{print $4}')}

if ! command -v gh > /dev/null; then
  echo "Can't find 'gh' tool in PATH, please install from https://github.com/cli/cli"
  exit 1
fi

if [[ "$#" -lt 2 ]]; then
  echo "cherry pick one or more <pr> onto <remote branch> and proposing a pull request"
  echo 
  echo "USAGE"
  echo "  ${0} <remote branch> <pr-number>..."
  echo
  echo "EXAMPLES"
  echo "  # Cherry-picks PR 12345, then 56789 and proposes the combination as a single PR."
  echo "  $0 release/v2.0 12345 56789"
  echo
  echo "CONFIG"
  echo "  UPSTREAM_REMOTE: Set to override the default remote names to what you have locally. Default to origin."
  echo
  exit 2
fi

gh auth status
git status

if git_status=$(git status --porcelain --untracked=no 2>/dev/null) && [[ -n "${git_status}" ]]; then
  echo "!!! Dirty tree. Clean up and try again."
  exit 1
fi

if [[ -e "${REBASEMAGIC}" ]]; then
  echo "!!! 'git rebase' or 'git am' in progress. Clean up and try again."
  exit 1
fi

declare -r BRANCH_NAME=$1
declare -r BRANCH="${UPSTREAM_REMOTE}/${BRANCH_NAME}"
shift 1
declare -r PULLS=( "$@" )

function join { local IFS="$1"; shift; echo "$*"; }
PULLDASH=$(join - "${PULLS[@]/#/#}") # Generates something like "#12345-#56789"
declare -r PULLDASH
PULLSUBJ=$(join " " "${PULLS[@]/#/#}") # Generates something like "#12345 #56789"
declare -r PULLSUBJ

echo "+++ Updating remotes..."
git remote update "${UPSTREAM_REMOTE}"

if ! git log -n1 --format=%H "${BRANCH}" >/dev/null 2>&1; then
  echo "!!! '${BRANCH}' not found. The first argument should be something like release/v2.0."
  echo "    (In particular, it needs to be a valid, existing remote branch that I can 'git checkout'.)"
  exit 1
fi

NEWBRANCH="$(echo "cp-${PULLDASH}-to-${BRANCH_NAME}" | sed 's/\//-/g')"
declare -r NEWBRANCH
NEWBRANCHUNIQ="${NEWBRANCH}-$(date +%s)"
declare -r NEWBRANCHUNIQ
echo "+++ Creating local branch ${NEWBRANCHUNIQ}"

cleanbranch=""
gitamcleanup=false
function post_run {
  if [[ "${gitamcleanup}" == "true" ]]; then
    echo
    echo "+++ Aborting in-progress git am."
    git am --abort >/dev/null 2>&1 || true
  fi

  # return to the starting branch and delete the PR text file
  if [[ -z "${DRY_RUN}" ]]; then
    echo
    echo "+++ Returning you to the ${STARTINGBRANCH} branch and cleaning up."
    git checkout -f "${STARTINGBRANCH}" >/dev/null 2>&1 || true
    if [[ -n "${cleanbranch}" ]]; then
      git branch -D "${cleanbranch}" >/dev/null 2>&1 || true
    fi
  fi
}
trap post_run EXIT

SUBJECTS=()
function create_pr() {
  echo
  echo "+++ Creating a pull request on GitHub at ${NEWBRANCH}"

  local numandtitle
  numandtitle=$(printf '%s\n' "${SUBJECTS[@]}")
  prtext=$(cat <<EOF
Cherry pick ${PULLSUBJ} onto ${BRANCH_NAME}:

${numandtitle}

EOF
)

  gh pr create --title="cp of ${numandtitle}" --body="${prtext}" --head "${NEWBRANCH}" --base "${BRANCH_NAME}" --repo="${REPO_ORG}/${REPO_NAME}"
}


function main() {
  git checkout -b "${NEWBRANCHUNIQ}" "${BRANCH}"
  cleanbranch="${NEWBRANCHUNIQ}"

  gitamcleanup=true
  for pull in "${PULLS[@]}"; do
    echo "+++ Downloading ${REPO_ORG}/${REPO_NAME}/pull/${pull}.patch to /tmp/${pull}.patch"

    gh pr diff ${pull} --patch > "/tmp/${pull}.patch"
    echo
    echo "+++ Attempting cherry pick of PR"
    echo
    git am -3 "/tmp/${pull}.patch" || {
      conflicts=false
      while unmerged=$(git status --porcelain | grep ^U) && [[ -n ${unmerged} ]] \
        || [[ -e "${REBASEMAGIC}" ]]; do
        conflicts=true # <-- We should have detected conflicts once
        echo
        echo "+++ Conflicts detected:"
        echo
        (git status --porcelain | grep ^U) || echo "!!! None. Did you git am --continue?"
        echo
        echo "+++ Please resolve the conflicts in another window (and remember to 'git add / git am --continue')"
        read -p "+++ Proceed (anything other than 'y' aborts the cherry-pick)? [y/n] " -r
        echo
        if ! [[ "${REPLY}" =~ ^[yY]$ ]]; then
          echo "Aborting." >&2
          exit 1
        fi
      done

      if [[ "${conflicts}" != "true" ]]; then
        echo "!!! git am failed, likely because of an in-progress 'git am' or 'git rebase'"
        exit 1
      fi
    }

    # set the subject
    subject=$(grep -m 1 "^Subject" "/tmp/${pull}.patch" | sed -e 's/Subject: \[PATCH//g' | sed 's/.*] //')
    SUBJECTS+=("#${pull}: ${subject}")

    # remove the patch file from /tmp
    rm -f "/tmp/${pull}.patch"
  done
  gitamcleanup=false

  if [[ -n "${DRY_RUN}" ]]; then
    echo "!!! Skipping git push and PR creation because you set DRY_RUN."
    echo "To return to the branch you were in when you invoked this script:"
    echo
    echo "  git checkout ${STARTINGBRANCH}"
    echo
    echo "To delete this branch:"
    echo
    echo "  git branch -D ${NEWBRANCHUNIQ}"
    exit 0
  fi

  echo
  echo "+++ Running git push ${UPSTREAM_REMOTE} ${NEWBRANCHUNIQ}:${NEWBRANCH}"
  echo

  git push "${UPSTREAM_REMOTE}" -f "${NEWBRANCHUNIQ}:${NEWBRANCH}"
  create_pr
}

main
