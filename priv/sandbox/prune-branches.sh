# Deletes the task branches of a project's clone in the VM that nothing
# needs any more, and says, one line each, what became of every task
# branch. MWT runs it (MWTClient.Sandbox.Slots.prune/4) when a slot is
# freed or taken and when a handoff lands or is closed; you run it from the
# Projects page or with mwt worktree prune.
#
#   sh prune-branches.sh [--dry-run] [--slot PATH]... [--handoff BRANCH COMMIT]...
#                        [--ended BRANCH COMMIT] CLONE
#
# A task branch is one `mwt worktree new` started: git config has
# branch.NAME.mwt-base. Other branches (the clone's own, ones made with
# git) are never touched. A task branch is deleted when nothing would be
# lost and nothing needs it:
#
#   * lost: its tip is the commit of its latest handoff (--handoff), kept
#     in MWT's store, which mwt worktree resume makes the branch again at;
#     or every commit on it is on another branch, a host-origin or
#     remote-origin branch, or a tag;
#   * needed: a worktree has it checked out, or another task is based on
#     it (branch.OTHER.mwt-base refs/heads/NAME).
#
# A slot (--slot) on a branch is always the slot's to keep, except for the
# --ended branch, whose handoff just landed or was closed at COMMIT: a slot
# still at COMMIT, with nothing uncommitted, goes on no branch, at that same
# commit, and the branch is deleted. So a sweep never takes a branch from
# under the thread working on it.
#
# The answer, one line per task branch:
#
#   deleted BRANCH [SLOT]       deleted; SLOT, if any, is on no branch now
#   deletable BRANCH [SLOT]     what --dry-run would delete
#   kept BRANCH slot PATH       the slot PATH has it checked out
#   kept BRANCH since           the --ended branch has commits since COMMIT
#   kept BRANCH uncommitted PATH
#   kept BRANCH other PATH      a worktree that isn't a slot has it
#   kept BRANCH missing PATH    the worktree that has it is gone
#   kept BRANCH base TASK       the task TASK is based on it
#   kept BRANCH commits N       N commits on it are on nothing else
#   kept BRANCH moved           it moved while it was being deleted
#
# The deletion only happens while the branch is still where it was read
# (git update-ref -d BRANCH OLD), so a commit made meanwhile keeps it. Its
# commits stay in the clone's object store, unlisted, until git prunes
# them, weeks later.

dry=no slots= handoffs= ended= ended_at= m=
nl='
'

while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) dry=yes; shift ;;
    --slot) slots=$slots$2$nl; shift 2 ;;
    --handoff) handoffs=$handoffs$2' '$3$nl; shift 3 ;;
    # Its handoff's commit before any --handoff for the same branch.
    --ended) ended=$2 ended_at=$3 handoffs=$2' '$3$nl$handoffs; shift 3 ;;
    -*) echo "prune-branches: unknown option $1" >&2; exit 2 ;;
    *) m=$1; shift ;;
  esac
done

[ -n "$m" ] || { echo "prune-branches: name the clone" >&2; exit 2; }
git -C "$m" rev-parse --git-dir >/dev/null || exit 1

# The latest handoff's commit of the branch $1, or nothing.
handoff_of() {
  printf '%s' "$handoffs" | awk -v b="$1" '$1 == b { print $2; exit }'
}

# Whether $1 is one of the slots.
slot() {
  case $nl$slots in *"$nl$1$nl"*) return 0 ;; esac
  return 1
}

worktrees=$(git -C "$m" worktree list --porcelain) || exit 1
bases=$(git -C "$m" config --get-regexp '^branch[.].*[.]mwt-base$' 2>/dev/null || true)

# The folder of the worktree that has the ref $1 checked out, or nothing.
worktree_of() {
  printf '%s\n' "$worktrees" | while IFS= read -r line; do
    case $line in
      "worktree "*) p=${line#worktree } ;;
      "branch $1") printf '%s\n' "$p"; break ;;
    esac
  done
}

# The first task based on the ref $1, or nothing.
based_on() {
  printf '%s\n' "$bases" | while read -r key base; do
    [ "$base" = "$1" ] || continue
    t=${key#branch.}
    printf '%s\n' "${t%.mwt-base}"
    break
  done
}

tasks=$(printf '%s\n' "$bases" | while read -r key _base; do
  [ -n "$key" ] || continue
  t=${key#branch.}
  printf '%s\n' "${t%.mwt-base}"
done)
if [ -n "$ended" ]; then tasks=$tasks$nl$ended; fi

printf '%s\n' "$tasks" | sort -u | while IFS= read -r b; do
  [ -n "$b" ] || continue
  ref=refs/heads/$b
  tip=$(git -C "$m" rev-parse -q --verify "$ref^{commit}") || continue

  tree=$(worktree_of "$ref")
  if [ -n "$tree" ]; then
    slot "$tree" || { echo "kept $b other $tree"; continue; }
    [ -d "$tree" ] || { echo "kept $b missing $tree"; continue; }
    [ "$b" = "$ended" ] || { echo "kept $b slot $tree"; continue; }
    [ "$tip" = "$ended_at" ] || { echo "kept $b since"; continue; }
    if [ -n "$(git -C "$tree" status --porcelain | head -n 1)" ]; then
      echo "kept $b uncommitted $tree"
      continue
    fi
  fi

  task=$(based_on "$ref")
  [ -z "$task" ] || { echo "kept $b base $task"; continue; }

  if [ "$tip" != "$(handoff_of "$b")" ]; then
    n=$(git -C "$m" for-each-ref --format='%(refname) %(objectname)' refs/heads refs/remotes refs/tags |
      awk -v r="$ref" '$1 != r { print "^" $2 }' |
      git -C "$m" rev-list --count --stdin "$tip")
    [ "$n" = 0 ] || { echo "kept $b commits $n"; continue; }
  fi

  if [ "$dry" = yes ]; then
    echo "deletable $b${tree:+ $tree}"
    continue
  fi
  if [ -n "$tree" ] && ! git -C "$tree" switch -q --detach; then
    echo "kept $b slot $tree"
    continue
  fi
  if git -C "$m" update-ref -d "$ref" "$tip"; then
    git -C "$m" config --remove-section "branch.$b" 2>/dev/null || true
    echo "deleted $b${tree:+ $tree}"
  else
    echo "kept $b moved"
  fi
done
