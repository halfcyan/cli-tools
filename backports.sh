#!/usr/bin/bash

# Automatically merges backports (if found) for the given PR URL(s).
# Usage:    backports [--help | -h] [-y] [-w] [--exclude-branch=<branch>] <pr-url-1> [pr-url-2] ...
#           backports [-y] [-w] -A --user=<user> --time=<duration>
# NOTE:     Requires gh (authenticated) and jq

bot="raboneko"
poll=30
yes=0
wait_mode=0
all=0
author=""
window=""
search_repo="terrapkg/packages"
excludes=()
urls=()

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            echo "Automatically merges backports for the given PR URL(s)."
            echo "Usage:    backports [--help | -h] [-y] [-w] [--exclude-branch=<branch>] <pr-url> [pr-url-2] ..."
            echo "          backports [-y] [-w] -A --user=<user> --time=<duration>"
            echo "Options:"
            echo "  -y                         Skip the confirmation prompts"
            echo "  -w, --wait                 Wait for missing backports to be created without asking"
            echo "  -A, --all                  Merge backports for every PR by --user merged within --time"
            echo "  --user=<user>              GitHub username to look up PRs for (with -A)"
            echo "  --time=<duration>          How far back to look, e.g. 30m, 2h, 1d (with -A)"
            echo "  --repo=<owner/repo>        Repo to look up PRs in (with -A, default: $search_repo)"
            echo "  --exclude-branch=<branch>  Skip a backport, e.g. 45, f45, el10 (comma-separated or repeated)"
            echo "NOTE:     Requires gh (authenticated) and jq"
            exit 0
            ;;
        -y) yes=1 ;;
        -w|--wait) wait_mode=1 ;;
        -A|--all) all=1 ;;
        --user=*) author="${arg#*=}" ;;
        --time=*) window="${arg#*=}" ;;
        --repo=*) search_repo="${arg#*=}" ;;
        --exclude-branch=*) IFS=, read -ra list <<< "${arg#*=}"; excludes+=("${list[@]}") ;;
        -*) echo "Error: unknown option: $arg"; exit 1 ;;
        *) read -ra list <<< "${arg//[$'\n,']/ }"; urls+=("${list[@]}") ;;
    esac
done

if [[ "$all" == 1 ]]; then
    if [[ -z "$author" || ! "$window" =~ ^([0-9]+)([mhd])$ ]]; then
        echo "Error: -A requires --user=<user> and --time=<number><m|h|d> (e.g. --time=2h)"
        exit 1
    fi
    num="${BASH_REMATCH[1]}"
    case "${BASH_REMATCH[2]}" in m) unit=60 ;; h) unit=3600 ;; d) unit=86400 ;; esac
    since=$(date -u -d "@$(( $(date +%s) - 10#$num * unit ))" +"%Y-%m-%dT%H:%M:%SZ")

    mapfile -t found < <(gh pr list --repo "$search_repo" --author "$author" --state merged \
        --search "merged:>=$since" --limit 100 --json url --jq '.[].url')
    echo "Found ${#found[@]} PR(s) by $author merged in the last $window."
    [[ ${#found[@]} -gt 0 ]] && echo
    urls+=("${found[@]}")
fi

if [[ ${#urls[@]} -eq 0 ]]; then
    [[ "$all" == 1 ]] && exit 0
    printf "Usage:\tbackports [-y] [-w] <pr_url>...\n"
    exit 1
fi

is_excluded() {
    local b="${1,,}" e
    [[ -n "$b" ]] || return 1
    for e in "${excludes[@]}"; do
        e="${e,,}"
        [[ "$b" == "$e" || "$b" == "f$e" ]] && return 0
    done
    return 1
}

declare -A branch_of

fetch_backports() {
    local comments bodies line

    if [[ ! "$1" =~ ^(https?://)?(www\.)?github\.com/([^/]+)/([^/]+)/pull/([0-9]+)([/?#].*)?$ ]]; then
        echo "Error: invalid PR URL: $1"
        return 1
    fi

    owner="${BASH_REMATCH[3]}"
    repo="${BASH_REMATCH[4]}"
    pr="${BASH_REMATCH[5]}"

    comments=$(gh api "repos/$owner/$repo/issues/$pr/comments" --paginate 2>/dev/null) || {
        echo "Error: couldn't fetch $owner/$repo#$pr (check the URL and your gh login)"
        return 1
    }

    bodies=$(echo "$comments" | jq -r --arg user "$bot" '
        [.[] | select(.user.login | ascii_downcase == ($user | ascii_downcase)) | .body] | join("\n")
    ')

    links=$(echo "$bodies" \
        | grep -oE "https://github\.com/[^/[:space:])]+/[^/[:space:])]+/pull/[0-9]+" \
        | sort -u \
        | grep -v "/pull/$pr\$")

    [[ -n "$links" ]] || return 2

    while IFS= read -r line; do
        [[ "$line" =~ \|[^\|]*\|[[:space:]]*([A-Za-z0-9_.]+)[[:space:]]*\|.*\((https://github\.com/[^/]+/[^/]+/pull/[0-9]+)\) ]] || continue
        branch_of["${BASH_REMATCH[2]}"]="${BASH_REMATCH[1]}"
    done <<< "$bodies"
}

await_backports() {
    local s

    waited=0
    fetch_backports "$1"; s=$?
    [[ "$s" != 2 ]] && return "$s"

    waited=1
    echo "Waiting for backports for $owner/$repo#$pr..."
    while true; do
        sleep "$poll"
        fetch_backports "$1"; s=$?
        [[ "$s" != 2 ]] && return "$s"
    done
}

merge_links() {
    local link o r n branch tag state a m

    while read -r link; do
        [[ "$link" =~ github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]] || continue
        o="${BASH_REMATCH[1]}"; r="${BASH_REMATCH[2]}"; n="${BASH_REMATCH[3]}"
        branch="${branch_of[$link]:-}"
        tag=""; [[ -n "$branch" ]] && tag="[$branch] "

        if is_excluded "$branch"; then
            echo "${tag}${link} -> skipped (excluded)"
            continue
        fi

        state=$(gh pr view "$n" --repo "$o/$r" --json state --jq .state 2>/dev/null)
        if [[ "$state" == "MERGED" ]]; then
            echo "${tag}${link} -> already merged"
            continue
        fi

        gh pr review "$n" --repo "$o/$r" --approve >/dev/null 2>&1 && a="approved" || a="approve failed"
        gh pr merge "$n" --repo "$o/$r" --squash --auto >/dev/null 2>&1 && m="squash-merge enabled" || m="merge failed"

        echo "${tag}${link} -> $m, $a"
    done <<< "$1"
}

rc=0
waited=0

if [[ "$yes" == 1 ]]; then
    sep=0
    for url in "${urls[@]}"; do
        [[ "$sep" == 1 ]] && echo
        sep=1
        if [[ "$wait_mode" == 1 ]]; then await_backports "$url"; else fetch_backports "$url"; fi
        s=$?
        if [[ "$s" == 2 ]]; then
            echo "Backports haven't been created yet for $owner/$repo#$pr."
        elif [[ "$s" == 0 && "$waited" != 1 && ${#urls[@]} -gt 1 ]]; then
            echo "$owner/$repo#$pr"
        fi
        [[ "$s" == 0 ]] || { rc=1; continue; }
        merge_links "$links"
    done
    exit "$rc"
fi

ids=(); pr_urls=(); titles=(); metas=(); groups=(); has=()
for url in "${urls[@]}"; do
    fetch_backports "$url"; s=$?
    [[ "$s" == 1 ]] && { rc=1; continue; }
    pr_info=$(gh api "repos/$owner/$repo/pulls/$pr" 2>/dev/null) || {
        echo "Error: couldn't fetch $owner/$repo#$pr (check the URL and your gh login)"
        rc=1; continue
    }
    ids+=("$owner/$repo#$pr")
    pr_urls+=("$url")
    titles+=("$(echo "$pr_info" | jq -r .title)")
    metas+=("$(echo "$pr_info" | jq -r .user.login) - $(date -d "$(echo "$pr_info" | jq -r .created_at)" +"%b %d, %Y")")
    groups+=("$links")
    [[ "$s" == 0 ]] && has+=(1) || has+=(0)
done

total=${#ids[@]}
[[ "$total" -eq 0 ]] && exit "$rc"

[[ "$rc" != 0 ]] && echo
for i in "${!ids[@]}"; do
    echo "${titles[i]}"
    echo "${metas[i]}"
    if [[ "${has[i]}" != 1 ]]; then
        [[ "$wait_mode" == 1 ]] && echo "Backports not found (will wait)" || echo "Backports not found"
    fi
    echo ""
done

[[ "$total" -gt 1 ]] && declined="Skipped." || declined="Aborted."
ready=(); waiters=()
for i in "${!ids[@]}"; do
    prefix=""; [[ "$total" -gt 1 ]] && prefix="[$((i + 1))/$total] "
    if [[ "${has[i]}" == 1 || "$wait_mode" == 1 ]]; then
        [[ "$total" -gt 1 ]] && q="Merge backports for \"${titles[i]}\"?" || q="Are you sure you want to merge backports for this PR?"
    else
        [[ "$total" -gt 1 ]] && q="Backports not found for \"${titles[i]}\". Wait for them and merge?" || q="Backports not found. Wait for them and merge?"
    fi

    read -rp "$prefix$q [Y/n] " ans
    if [[ ! "${ans:-Y}" =~ ^[Yy] ]]; then
        echo "$declined"
    elif [[ "${has[i]}" == 1 ]]; then
        ready+=("$i")
    else
        waiters+=("$i")
    fi
done

[[ ${#ready[@]} -eq 0 && ${#waiters[@]} -eq 0 ]] && exit "$rc"
echo

sep=0
for i in "${ready[@]}"; do
    [[ "$sep" == 1 ]] && echo
    sep=1
    [[ "$total" -gt 1 ]] && echo "${ids[i]}"
    merge_links "${groups[i]}"
done

for i in "${waiters[@]}"; do
    [[ "$sep" == 1 ]] && echo
    sep=1
    await_backports "${pr_urls[i]}"
    s=$?
    [[ "$s" == 0 ]] || { rc=1; continue; }
    [[ "$waited" != 1 && "$total" -gt 1 ]] && echo "${ids[i]}"
    merge_links "$links"
done
exit "$rc"
