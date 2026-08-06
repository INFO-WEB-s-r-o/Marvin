#!/usr/bin/env bash
# =============================================================================
# Marvin — Disk Cleanup Automation
# =============================================================================
# Removes old logs, temp files, and caches to prevent disk exhaustion.
# Runs daily as part of morning-check or standalone.
#
# Cron: Called from morning-check.sh (06:00 UTC)
#       Can also run standalone: agent/disk-cleanup.sh
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"
trap marvin_error_trap ERR
marvin_parse_args "$@"

marvin_log "INFO" "Disk cleanup starting"

FREED_BYTES=0
ACTIONS=()

# Helper: track freed space
track_freed() {
    local desc="$1"
    local bytes="$2"
    if [[ "$bytes" -gt 0 ]]; then
        FREED_BYTES=$((FREED_BYTES + bytes))
        local human
        human=$(numfmt --to=iec "$bytes" 2>/dev/null || echo "${bytes}B")
        ACTIONS+=("${desc}: ${human}")
        marvin_log "INFO" "Cleaned ${human}: ${desc}"
    fi
}

# ─── 1. Old compressed system logs (>30 days) ───────────────────────────────

old_logs_size=0
while IFS= read -r -d '' f; do
    fsize=$(stat -c%s "$f" 2>/dev/null || echo 0)
    old_logs_size=$((old_logs_size + fsize))
    marvin_is_dry_run || rm -f "$f"
done < <(find /var/log -type f \( -name '*.gz' -o -name '*.xz' -o -name '*.bz2' -o -name '*.old' \) -mtime +30 -print0 2>/dev/null)
track_freed "Compressed system logs (>30d)" "$old_logs_size"

# ─── 2. APT cache cleanup ───────────────────────────────────────────────────

apt_before=$(du -sb /var/cache/apt/archives/ 2>/dev/null | awk '{print $1}' || echo 0)
marvin_is_dry_run || apt-get clean -y 2>/dev/null || true
apt_after=$(du -sb /var/cache/apt/archives/ 2>/dev/null | awk '{print $1}' || echo 0)
apt_freed=$((apt_before - apt_after))
[[ "$apt_freed" -lt 0 ]] && apt_freed=0
track_freed "APT package cache" "$apt_freed"

# ─── 3. Old Marvin run logs (>14 days) ──────────────────────────────────────
# data/logs/ contains per-run markdown logs that grow quickly.
# Keep 14 days, which is enough for debugging.

run_logs_size=0
while IFS= read -r -d '' f; do
    fsize=$(stat -c%s "$f" 2>/dev/null || echo 0)
    run_logs_size=$((run_logs_size + fsize))
    marvin_is_dry_run || rm -f "$f"
done < <(find "${LOGS_DIR}" -type f -name "*.md" -mtime +14 -print0 2>/dev/null)
track_freed "Marvin run logs (>14d)" "$run_logs_size"

# ─── 4. Old Marvin daily logs (>30 days) ────────────────────────────────────

daily_logs_size=0
while IFS= read -r -d '' f; do
    fsize=$(stat -c%s "$f" 2>/dev/null || echo 0)
    daily_logs_size=$((daily_logs_size + fsize))
    marvin_is_dry_run || rm -f "$f"
done < <(find "${LOGS_DIR}" -type f -name "????-??-??.log" -mtime +30 -print0 2>/dev/null)
track_freed "Marvin daily logs (>30d)" "$daily_logs_size"

# ─── 5. Compress time-series JSONL files (>30 days) ─────────────────────────
# Data retention policy: compress raw JSONL at 30 days, delete at 180 days.
# Covers every one-file-per-day JSONL family across METRICS_DIR and LOGS_DIR:
#   - ????-??-??.jsonl                  (raw 5-min metrics)
#   - claude-usage-????-??-??.jsonl     (per-Claude-run usage/latency)
#   - latency-????-??-??.jsonl          (network latency probes)
#   - ????-??-??-structured.jsonl       (structured JSON logs, in LOGS_DIR)
# Before 2026-06-16 only the bare ????-??-??.jsonl metrics family was covered;
# the other three grew unbounded one file/day (claude-usage back to 2026-03-07,
# 100+ files). All consumers read these by exact recent-date filename
# (perf-analytics 7d window, weekly-analytics ~14d, log-analysis today-only),
# so compressing files >30d old is safe — no consumer ever constructs a name
# for a date that far back, and a missing old date already degrades gracefully.
# Daily/hourly summary .json files are small, not .jsonl, and kept indefinitely.
_TS_JSONL_NAMES=(
    -name "????-??-??.jsonl"
    -o -name "claude-usage-????-??-??.jsonl"
    -o -name "latency-????-??-??.jsonl"
    -o -name "????-??-??-structured.jsonl"
)
# Same families, compressed — derived from _TS_JSONL_NAMES so the two can never
# drift: a fifth family is added in exactly one place (above) and its .gz variant
# follows automatically. Each "*.jsonl" pattern gains a ".gz" suffix; the -name/-o
# find operators pass through unchanged.
_TS_JSONL_GZ_NAMES=()
for _el in "${_TS_JSONL_NAMES[@]}"; do
    if [[ "${_el}" == *.jsonl ]]; then
        _TS_JSONL_GZ_NAMES+=("${_el}.gz")
    else
        _TS_JSONL_GZ_NAMES+=("${_el}")
    fi
done

# 5a. Compress uncompressed JSONL files older than 30 days
compressed_count=0
compressed_bytes=0
while IFS= read -r -d '' f; do
    if [[ ! -f "${f}.gz" ]]; then
        fsize=$(stat -c%s "$f" 2>/dev/null || echo 0)
        if marvin_is_dry_run; then
            compressed_bytes=$((compressed_bytes + fsize / 2))  # estimate 50% compression
            compressed_count=$((compressed_count + 1))
        elif gzip "$f" 2>/dev/null; then
            gz_size=$(stat -c%s "${f}.gz" 2>/dev/null || echo 0)
            saved=$((fsize - gz_size))
            [[ "$saved" -lt 0 ]] && saved=0
            compressed_bytes=$((compressed_bytes + saved))
            compressed_count=$((compressed_count + 1))
        fi
    fi
done < <(find "${METRICS_DIR}" "${LOGS_DIR}" -maxdepth 1 -type f \( "${_TS_JSONL_NAMES[@]}" \) -mtime +30 -print0 2>/dev/null)
if [[ "$compressed_count" -gt 0 ]]; then
    track_freed "Compressed ${compressed_count} time-series JSONL (>30d)" "$compressed_bytes"
fi

# 5b. Delete compressed JSONL files older than 180 days
metrics_size=0
while IFS= read -r -d '' f; do
    fsize=$(stat -c%s "$f" 2>/dev/null || echo 0)
    metrics_size=$((metrics_size + fsize))
    marvin_is_dry_run || rm -f "$f"
done < <(find "${METRICS_DIR}" "${LOGS_DIR}" -maxdepth 1 -type f \( "${_TS_JSONL_GZ_NAMES[@]}" \) -mtime +180 -print0 2>/dev/null)
track_freed "Old time-series JSONL.gz (>180d)" "$metrics_size"

# ─── 6a. Stale scratch directories in /tmp (#898) ───────────────────────────
# Section 6 below is `-type f`, so directories have never been candidates and
# every harness, worktree and fixture tree left in /tmp stays there forever —
# 47 of them accumulated in two days. Three things make this more than a
# one-character fix, and all three are why the sweep is written out longhand:
#
#   1. The obvious edit is the dangerous one. Every root-owned directory in
#      /tmp currently older than 7 days is live system infrastructure —
#      systemd-private-* service dirs and the .X11-unix/.ICE-unix/.XIM-unix/
#      .font-unix socket dirs. A bare `-type d -mtime +7 | rm -rf` deletes
#      exactly those and nothing else. Hence a *skip* list that is checked
#      first and errs wide (anything dot-prefixed is untouchable outright).
#
#   2. Section 6 resets the clock on its own targets. Unlinking a file bumps
#      the parent directory's mtime to now, so a directory empty since July
#      reports as modified today and `-mtime +7` on the directory itself would
#      miss it. Eligibility is therefore keyed on the newest mtime anywhere in
#      the subtree, and 6a deliberately runs BEFORE section 6 so that within a
#      single run the file sweep cannot destroy the evidence 6a reads.
#
#   3. A scratch directory in use by a running process looks identical to an
#      abandoned one if you only look at timestamps. The in-use set is read
#      from /proc first, and if that read fails the whole sweep is skipped —
#      "could not determine what is in use" must not resolve to "nothing is".
#      That guarantee was stated here before it was implemented (#908): the
#      check tested whether /proc had *any* processes, which this script's own
#      shell guarantees, rather than whether every entry it needed was actually
#      readable. See _tmp_paths_in_use below.
#
#      The /proc snapshot is taken once, up front, and the deletions happen
#      afterwards one directory at a time — so there is a TOCTOU window in
#      which a process could start using a directory this run has already
#      cleared. Accepted, not overlooked: nothing becomes a candidate until it
#      has been untouched for 7 days, this runs once daily, and a process that
#      adopts a week-dead scratch directory in the seconds between the scan and
#      the unlink is not a case worth holding a lock for. Re-checking each path
#      immediately before its rm would narrow the window without closing it,
#      which buys the appearance of a guarantee rather than one.
#
#      What keeps that window narrow rather than merely small is the sticky bit
#      on /tmp: without it any user can unlink a root-owned entry and put
#      something of their own at that name between the scan and the rm. That is
#      an OS default this section was silently inheriting, so it is now checked
#      out loud (#901 review) — an unsticky /tmp skips the sweep entirely, on
#      the same "a precondition that could not be confirmed is not satisfied"
#      rule as the /proc read above.
#
#      Stating the residual exposure precisely rather than implying it is zero:
#      even with the swap performed, `rm -rf -- /tmp/foo` on a symlink removes
#      the symlink and does not traverse it (verified, not assumed: GNU rm
#      leaves the target's contents intact when the operand itself is the
#      link). So the sticky bit is what makes the swap impossible, not the only
#      thing standing between this sweep and someone else's files.

# Paths under /tmp currently referenced by a live process (cwd, exe or an open
# fd). Prints one path per line. Returns non-zero when the scan could not be
# completed, which the caller treats as "do not delete anything".
#
# Issue #908. The first version returned non-zero only when the /proc/[0-9]*
# glob matched nothing at all, and this function's own shell is always in /proc
# while it runs — so the flag was set on the first iteration every time and the
# caller's skip branch was unreachable. The failure it was written for is the
# partial one: an individual readlink that fails, gets swallowed by `|| continue`
# and quietly removes that process's /tmp references from the answer. Nothing
# downstream can tell that from "this directory is genuinely unused", and the
# next statement in the caller is `rm -rf`.
#
# Treating every readlink failure as a failure would be worse than the bug: 88
# of this box's ~180 processes are kernel threads, whose /proc/N/exe is a
# dangling symlink by design, so the sweep would skip on every run forever and
# look exactly like a sweep that had nothing to collect. Failures are therefore
# classified by errno, via readlink -v's message under LC_ALL=C:
#
#   ENOENT  benign — a kernel thread's exe, or a process/fd that exited between
#           the glob and the readlink. Confirmed by re-testing that the process
#           still exists, so a race is never counted against the scan.
#   other   counted — EACCES, EPERM, or any errno not anticipated here. The test
#           allowlists the one benign case rather than denylisting known-bad
#           ones, so an unrecognised message (including a stderr this parser
#           fails to match at all) counts as a read that did not happen and
#           skips the sweep. Wrong in the direction that keeps files.
#
# The two failures are reported as two exit codes rather than one flag plus a
# count in a variable. The first draft of this fix used a global for the count,
# and the fixture test below caught it reading 0 in every branch: the caller
# invokes this in a command substitution, so the assignment happens in a
# subshell and the parent never sees it. That is the same defect as #908 itself
# — a signal that cannot reach the code deciding whether to delete — reproduced
# inside the fix for it. Exit status is the one channel that does cross `$( )`.
#
#   0  scan complete
#   1  no processes found at all (/proc absent, unmounted, or hidden)
#   2  one or more entries existed but could not be read
#
# Known and accepted gap: "in use" here means cwd, exe or an OPEN fd. A process
# that mmap()'d a file under one of these directories and then closed the fd
# holds no fd to find, and only /proc/N/maps would show it. Not read, because
# the consequence is mild and the cost is not: unlinking a mapped file does not
# disturb the mapping — the inode survives until the last reference drops, so
# the process keeps reading and writing the file it already has, and only a
# later open() by path fails. Reading maps for ~180 processes on every run to
# catch that is the wrong trade. Recorded so the next reader knows the omission
# was priced rather than missed.
#
# proc_root is an argument, not a constant, for the same reason _stale_tmp_dirs
# takes its root as one: the classification above is exercised against a fixture
# tree, as an unprivileged user so EACCES is reachable, rather than asserted.
# shellcheck disable=SC2120  # proc_root is deliberately optional: the sole in-script call takes the /proc default, the fixture harness passes a root (see #908)
_tmp_paths_in_use() {
    local proc_root="${1:-/proc}"
    local p t target err scanned=0 unreadable=0

    for p in "$proc_root"/[0-9]*; do
        [[ -d "$p" ]] || continue
        scanned=$((scanned + 1))

        # Checked before the loop below, because an unreadable fd/ directory
        # does not surface there as an error at all: the glob simply fails to
        # expand and `$t` becomes the literal pattern. readlink then fails with
        # ENOENT, which the failure path below deliberately does not count — so
        # every open file of that process goes unseen and the scan still reports
        # clean. This is the widest way a live /tmp path can hide from it.
        #
        # -r alone is the correct test here, and deliberately not `-r && -x`.
        # Listing a directory's names needs read; only resolving an entry needs
        # execute. So r-without-x still expands the glob, and each readlink then
        # fails EACCES — which the branch below *does* count, because it only
        # exempts ENOENT. Verified unprivileged (as root both bits are free and
        # the mode means nothing): r-without-x -> unreadable=1 via readlink,
        # full rx -> 0. Adding `! -x` here only double-counts the same process.
        if [[ ! -r "$p/fd" && -d "$p" ]]; then
            unreadable=$((unreadable + 1))
        fi

        for t in "$p/cwd" "$p/exe" "$p/fd"/*; do
            if target=$(readlink "$t" 2>/dev/null); then
                [[ "$target" == /tmp/* ]] && printf '%s\n' "$target"
                continue
            fi

            # Only on the failure path, so the common case still costs one
            # subshell per entry. readlink is silent without -v.
            #
            # The match below is coreutils' own ENOENT text, and LC_ALL=C is
            # what keeps it in English: with a coreutils .mo installed and the
            # pin removed, this compares against a translated string and never
            # matches. Defensive rather than load-bearing today — this box has
            # no coreutils translations at all — but `apt install locales-all`
            # or a language-pack would silently make it load-bearing, so treat
            # the pin and the literal as one unit and change neither alone.
            #
            # If it does break, it breaks safely: an unrecognised message is
            # counted (not excused), so the function returns 2 and the caller
            # skips the sweep. Measured by mutating the literal to one that
            # cannot match — rc 0 -> 2, sweep skipped, nothing deleted.
            err=$(LC_ALL=C readlink -v "$t" 2>&1 >/dev/null) || true
            if [[ "$err" != *"No such file or directory"* ]] && [[ -d "$p" ]]; then
                unreadable=$((unreadable + 1))
            fi
        done
    done

    # "Found no processes" keeps its original meaning: /proc absent, unmounted
    # or hidden. It stays a failure — it is simply no longer the only one.
    [[ "$scanned" -gt 0 ]] || return 1
    [[ "$unreadable" -eq 0 ]] || return 2
    return 0
}

# Prefixes for the two things this function reports that are not collectable
# paths. Neither can call marvin_log: that logs via `tee`, which writes to
# stdout, and stdout here is the path stream the caller feeds to `rm -rf`. A
# log line would arrive as a candidate for deletion. Every real line is an
# absolute path under <root>, so a leading `!` is unambiguous.
_STALE_TMP_UNREADABLE='!unreadable:'
_STALE_TMP_UNSAFE='!unsafe:'

# Directories directly under <root> that are safe to collect: root-owned, not
# on the skip list, not in use, and with nothing in the subtree newer than
# <age_days>. Takes the root as an argument rather than hardcoding /tmp so the
# selection can be exercised against a fixture tree without risking the real
# one. Prints one collectable path per line, plus a `!unreadable:<path>` line
# for any directory whose subtree could not be walked, and a `!unsafe:<path>`
# line for any name this line protocol cannot carry (both skipped, neither
# collected).
_stale_tmp_dirs() {
    local root="$1" age_days="$2" in_use="$3"
    local d base newest cutoff
    cutoff=$(( $(date +%s) - age_days * 86400 ))

    while IFS= read -r -d '' d; do
        base="${d##*/}"

        # Checked before the skip list, because this is not a policy question
        # about which directories deserve to survive — it is whether anything
        # downstream can trust the line at all. A newline in a /tmp directory
        # name is legal on Linux, arrives here intact (find -print0 into
        # `read -d ''`), and then breaks BOTH channels out of this function,
        # which are line-delimited (#901 review):
        #
        #   collect  — the caller reads with `read -r`, so it sees the
        #              fragments as separate candidates. Measured on a fixture
        #              holding a stale `<root>/a\nb` beside an unrelated and
        #              FRESH `<root>/a`: the caller reached
        #              `rm -rf -- <root>/a`, a directory that was never a
        #              candidate and had failed the staleness test, while the
        #              actual target survived. Not a missed collection — a
        #              delete aimed at the wrong path, running as root.
        #   in-use   — `in_use` is one path per line too, so a held path under
        #              such a directory arrives split and the `index()` test
        #              below can never match it. The protection fails OPEN,
        #              the exact direction the fixed-string matching was
        #              chosen to avoid.
        #
        # NUL-delimiting both channels is the tidier-looking fix and does not
        # work: `in_use` reaches this function through a command substitution,
        # and `$( )` strips NUL bytes outright — the producer's separators
        # would be gone before the consumer could see them. That leaves an
        # escaping protocol on a delete path, or refusing the input. Refusing
        # is the one that cannot be got subtly wrong.
        #
        # So such a directory is never collected, and it is said out loud
        # rather than dropped silently; the marker line carries the name
        # %q-escaped, which is single-line by construction. The cost is that a
        # scratch directory with a newline in its name is never swept and
        # accumulates — the same trade every other guard in this section
        # makes, wrong in the direction that keeps files.
        #
        # With this in place, every line either channel emits is newline-free
        # by construction, so the line protocol is sound rather than merely
        # lucky. The reverse case needs no guard: a newline inside an *in-use*
        # path splits into fragments that can only match extra candidates, and
        # over-protection deletes nothing.
        if [[ "$d" == *$'\n'* ]]; then
            printf '%s%q\n' "$_STALE_TMP_UNSAFE" "$d"
            continue
        fi

        # Skip list, checked before anything else. Grouped by why each entry is
        # here, because the groups are not equally load-bearing and a future
        # editor pruning "obviously dead" names needs to know which is which.
        case "$base" in
            # Hidden state: the X11/ICE/XIM/font socket directories and
            # anything else dot-prefixed.
            .*) continue ;;
            # LOAD-BEARING — do not drop. A PrivateTmp= unit gets a private
            # /tmp bind-mounted over this directory, so its processes' open
            # files resolve to paths inside the mount, never to this name. The
            # /proc in-use check below is structurally unable to see that it is
            # busy; this line is the only thing protecting it.
            systemd-private-*|snap-private-*) continue ;;
            # Session and desktop scratch owned by things still running. The
            # /proc check would normally catch these; belt-and-braces for the
            # window where a socket dir outlives its last open fd.
            snap.*|pulse-*|tmux-*|ssh-*|vscode-*|dbus-*) continue ;;
            # JVM and cross-platform toolchain scratch. Defensive padding —
            # nothing on this host is known to depend on these.
            Temp-*|hsperfdata_*) continue ;;
        esac

        # Refuse anything that is not a plain child of root — no traversal, no
        # deleting the root itself.
        #
        # The traversal term tests `..` as a whole path COMPONENT, not as a
        # substring. `find -mindepth 1 -maxdepth 1` cannot emit `.` or `..`,
        # and if it somehow did, the `.*)` arm above would already have taken
        # it — so the only thing this term can still catch is a caller passing
        # a root that is itself unnormalised (`/tmp/x/..`), which arrives here
        # as `/tmp/x/../y`. A substring test catches that case too, but it
        # also permanently refuses any legitimate scratch directory whose name
        # merely contains `..` (`pytest-of-root..1`), which would then
        # accumulate forever with nothing said. Wrong in the keeping-files
        # direction, as every guard here is — but this section reports the one
        # name it refuses to sweep (the newline marker above) instead of
        # dropping it quietly, and a blacklist nobody can see is not that.
        [[ "$d" == "$root"/* && "/$d/" != */../* && -n "$base" ]] || continue

        # In use by a live process? Match the directory itself or anything
        # beneath it, so an open fd on a file inside protects the parent.
        # Compared as fixed strings via awk's index(), not a grep pattern: a
        # /tmp name may legitimately contain regex metacharacters, and a path
        # that failed to match because it contained a `[` would fail OPEN — it
        # would read as "not in use" and the directory would be deleted.
        #
        # Passed through the ENVIRON array, NOT `awk -v`. POSIX requires a -v
        # assignment to undergo the same backslash-escape processing as a
        # string literal in the program text, so awk receives `foo\nbar` — a
        # legal 8-character directory name — as 7 characters with a real
        # newline in the middle. Every line of `in_use` is newline-free by
        # construction, so neither term can ever match and the protection
        # fails OPEN: the identical failure direction the index() choice above
        # was made to avoid, reached by a different route. ENVIRON entries are
        # not escape-processed, so the name arrives byte-for-byte. Confirmed
        # here on gawk 5.2.1; the semantics are POSIX and hold for mawk too.
        # (`log-watcher.sh` passes INTEREST_RE through the environment for the
        # same reason.) Shown failing first: with -v, a held `/tmp/…/foo\nbar`
        # was emitted as an `rm -rf` candidate while an ordinary held name
        # beside it was correctly protected. (#923)
        if D="$d" awk 'index($0, ENVIRON["D"] "/") == 1 || $0 == ENVIRON["D"] { found = 1; exit }
                       END { exit !found }' <<< "$in_use"; then
            continue
        fi

        # Newest mtime anywhere in the subtree, including the directory itself.
        # This is the point of the section: the directory's own mtime lies,
        # because section 6 keeps resetting it.
        #
        # Deliberately not `sort -rn | head -1`. head exits after one line, so
        # on a subtree big enough to push sort's output past the pipe buffer
        # (~6.5k files here) sort dies of SIGPIPE, 141. Under `pipefail` that
        # is the assignment's status, and `set -e` then kills this function --
        # which runs inside a process substitution, so the caller's read loop
        # just sees EOF. Every directory find had not yet reached is dropped,
        # and a truncated sweep is indistinguishable from a complete one that
        # found nothing. A big *ineligible* directory is enough to trigger it;
        # it is read before the staleness test that would have skipped it, so
        # one 20k-file tree anywhere in /tmp silences the whole section (#909).
        #
        # awk takes the max in a single pass and never exits early, so there is
        # no reader to close the pipe. No `cut` either: %T@ compares correctly
        # as a float, and %d truncates to whole seconds exactly as cut -d. did.
        #
        # find's own status is checked rather than discarded. A subtree it
        # could only partly walk yields a maximum that is too old, and on a
        # delete path "too old" means "collect it" -- the one direction this
        # must never fail in. Unreadable means skipped, and skipped is said
        # out loud, because silence here looks exactly like "not stale".
        if ! newest=$(find "$d" -printf '%T@\n' 2>/dev/null |
                          awk '{ if ($1 + 0 > m) m = $1 + 0 }
                               END { if (NR) printf "%d\n", m }'); then
            printf '%s%s\n' "$_STALE_TMP_UNREADABLE" "$d"
            continue
        fi
        [[ -n "$newest" ]] || continue
        [[ "$newest" -lt "$cutoff" ]] || continue

        printf '%s\n' "$d"
    done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -user root -print0 2>/dev/null)
}

tmpdir_size=0
tmpdir_count=0
if [[ ! -k /tmp ]]; then
    # Not a theoretical hardening: /tmp is world-writable, so the sticky bit is
    # the only thing preventing a non-root user from unlinking one of the
    # root-owned directories this sweep has already selected and leaving
    # something else at that path before the rm reaches it. Skipped rather than
    # risked — a week of scratch files is cheaper than a delete aimed by
    # somebody else.
    marvin_log "WARN" "/tmp is not sticky — the stale-directory sweep's TOCTOU window depends on that bit to keep other users from swapping a selected path, so section 6a is skipped rather than run without it (#898, #901 review)"
    ACTIONS+=("Stale /tmp scratch directories: SKIPPED (/tmp not sticky)")
elif _in_use=$(_tmp_paths_in_use); then
    tmpdir_unreadable=0
    tmpdir_unsafe=0
    while IFS= read -r d; do
        [[ -n "$d" ]] || continue

        # Not a candidate: a subtree whose age could not be established. Said
        # out loud, because a directory skipped for this reason looks exactly
        # like one that was examined and found fresh.
        if [[ "$d" == "${_STALE_TMP_UNREADABLE}"* ]]; then
            tmpdir_unreadable=$((tmpdir_unreadable + 1))
            marvin_log "WARN" "could not walk ${d#"${_STALE_TMP_UNREADABLE}"} to establish its newest mtime — skipped rather than assuming it is stale, since a partial walk reports an age that is too old and this is a delete path (#909)"
            continue
        fi

        # Not a candidate: a name this loop's line-delimited protocol cannot
        # carry. Reported %q-escaped, exactly as it arrived — un-escaping it
        # for a prettier log line would put the newline back into the log
        # stream, which is the class of problem being reported.
        if [[ "$d" == "${_STALE_TMP_UNSAFE}"* ]]; then
            tmpdir_unsafe=$((tmpdir_unsafe + 1))
            marvin_log "WARN" "/tmp directory ${d#"${_STALE_TMP_UNSAFE}"} has a newline in its name — never collected, because neither the in-use check nor this delete loop can carry it intact, and a split candidate would aim rm -rf at a path that was never examined (#901 review)"
            continue
        fi

        # Belt and braces: only ever delete an absolute path. If a future
        # marker is added and this loop is not taught about it, it must not
        # reach rm -rf.
        [[ "$d" == /* ]] || continue

        dsize=$(du -sb "$d" 2>/dev/null | cut -f1) || dsize=0
        [[ "$dsize" =~ ^[0-9]+$ ]] || dsize=0
        tmpdir_size=$((tmpdir_size + dsize))
        tmpdir_count=$((tmpdir_count + 1))
        marvin_is_dry_run || rm -rf -- "$d"
    done < <(_stale_tmp_dirs /tmp 7 "$_in_use")
    if [[ "$tmpdir_count" -gt 0 ]]; then
        track_freed "Stale /tmp scratch directories (>7d, ${tmpdir_count})" "$tmpdir_size"
    fi
    # Surfaced in the summary, not only in the log (#901 review). track_freed
    # cannot carry this — it is gated on bytes > 0, and a directory that was
    # skipped freed nothing by definition. A run that examined 60 directories
    # and could not read 12 of them is not the same run as one that examined
    # 60, and the report is where that difference has to be visible; otherwise
    # a sweep degrading toward "skips everything" reads as "found nothing",
    # which is #898 over again.
    if [[ "$tmpdir_unreadable" -gt 0 ]]; then
        ACTIONS+=("Stale /tmp scratch directories: ${tmpdir_unreadable} skipped, subtree unreadable")
    fi
    if [[ "$tmpdir_unsafe" -gt 0 ]]; then
        ACTIONS+=("Stale /tmp scratch directories: ${tmpdir_unsafe} skipped, newline in name")
    fi
else
    _in_use_rc=$?
    if [[ "$_in_use_rc" -eq 2 ]]; then
        marvin_log "WARN" "at least one /proc entry existed but could not be read while determining which /tmp directories are in use — a live process whose open files went unseen may be holding one, so the stale-directory sweep is skipped rather than guessing (#898, #908)"
    else
        marvin_log "WARN" "found no processes under /proc to determine which /tmp directories are in use — skipping the stale-directory sweep rather than guessing (#898)"
    fi
fi

# ─── 6. Temp files ──────────────────────────────────────────────────────────

tmp_size=0
while IFS= read -r -d '' f; do
    fsize=$(stat -c%s "$f" 2>/dev/null || echo 0)
    tmp_size=$((tmp_size + fsize))
    marvin_is_dry_run || rm -f "$f"
done < <(find /tmp -type f -user root -mtime +7 -print0 2>/dev/null)
track_freed "Old temp files (>7d)" "$tmp_size"

# ─── 6b. Orphaned Claude output temp files in LOGS_DIR ──────────────────────
# run_claude() (lib/claude.sh) captures Claude's response to a temp file
# created as ${LOGS_DIR}/claude-output-XXXXXX.tmp and removes it via a RETURN
# trap. A SIGKILL (OOM kill, reboot, or external timeout kill mid-run) bypasses
# that trap and leaks the temp file forever: sections 3/4 above only match *.md
# and the daily ????-??-??.log, and section 6 only sweeps /tmp — none of them
# ever match these. Every Claude run creates one, so this is the most likely
# orphan source on the box. Age-gate at >1 day (-mtime +0): no single
# `claude -p` invocation runs anywhere near that long, so anything older is
# definitively orphaned and an in-flight run's temp file is never at risk.
# -maxdepth 1 keeps the sweep to the files run_claude writes directly in LOGS_DIR.
claude_tmp_size=0
while IFS= read -r -d '' f; do
    fsize=$(stat -c%s "$f" 2>/dev/null || echo 0)
    claude_tmp_size=$((claude_tmp_size + fsize))
    marvin_is_dry_run || rm -f "$f"
done < <(find "${LOGS_DIR}" -maxdepth 1 -type f -name 'claude-output-*.tmp' -mtime +0 -print0 2>/dev/null)
track_freed "Orphaned Claude output temp files (>1d)" "$claude_tmp_size"

# ─── 6c. Orphaned scratch directories in /tmp ───────────────────────────────
# Section 6 above is -type f only, so it never sweeps directories. self-test.sh
# and ad hoc verification runs create scratch dirs (mktemp -d, or a plain
# mkdir for a named fixture like "negtest") that are normally rm -rf'd by the
# script itself, but leak — same root cause as 6b — when the run is killed
# (timeout, OOM) before its own cleanup executes. Nothing else ever sweeps
# them, so they accumulate indefinitely (34MB removed by hand on 2026-07-27).
# Root-owned + >7d mirrors section 6's file sweep; the name excludes protect
# the small fixed set of long-lived system directories that also live
# directly under /tmp (X11/ICE/XIM/font sockets, snap's private tmp, per-unit
# systemd-private dirs, and ssh-agent forwarding sockets) — all confirmed
# present and root-owned on this host, so an unqualified sweep would have
# deleted them.
tmp_dir_size=0
while IFS= read -r -d '' d; do
    dsize=$(du -sb "$d" 2>/dev/null | cut -f1)
    tmp_dir_size=$((tmp_dir_size + ${dsize:-0}))
    marvin_is_dry_run || rm -rf "$d"
done < <(find /tmp -mindepth 1 -maxdepth 1 -type d -user root -mtime +7 \
    ! -name '.X11-unix' ! -name '.ICE-unix' ! -name '.XIM-unix' ! -name '.font-unix' ! -name '.Test-unix' \
    ! -name 'snap-private-tmp' ! -name 'systemd-private-*' ! -name 'ssh-*' \
    -print0 2>/dev/null)
track_freed "Old scratch directories (>7d)" "$tmp_dir_size"

# ─── 6d. Orphaned log-watcher forensic artifacts in COMMS_DIR (>30 days) ────
# log-watcher.sh writes two forensic-only files when Claude is unavailable or
# its output won't parse: pending-log-review.txt (raw logs that went
# un-analyzed during an outage, since offsets advance regardless) and
# log-analysis-raw-<ts>.txt (one per parse failure). Neither is read back by
# any consumer, and COMMS_DIR is not swept by any section above. Stale records
# (>30d — the outage they captured is long over) are safe to remove. The live
# pending file self-caps at 512 KB in log-watcher.sh, so during an active
# outage it stays bounded AND fresh (mtime recent → not matched here); only
# records gone quiet for a month are cleaned. The per-day
# log-analysis-YYYY-MM-DD.json analysis files are handled separately by section
# 6e below (compress + long retain, not deleted here).
comms_forensic_size=0
while IFS= read -r -d '' f; do
    fsize=$(stat -c%s "$f" 2>/dev/null || echo 0)
    comms_forensic_size=$((comms_forensic_size + fsize))
    marvin_is_dry_run || rm -f "$f"
done < <(find "${COMMS_DIR}" -maxdepth 1 -type f \( -name 'log-analysis-raw-*.txt' -o -name 'pending-log-review.txt' \) -mtime +30 -print0 2>/dev/null)
track_freed "Stale log-watcher forensic records (>30d)" "$comms_forensic_size"

# ─── 6e. Per-day comms log-analysis JSON retention (compress >30d, del >180d) ─
# log-watcher.sh writes one ${COMMS_DIR}/log-analysis-YYYY-MM-DD.json per day —
# Claude's classification of that day's incoming signals / attack attempts.
# Every consumer (log-watcher, evening-report, update-website) reads ONLY
# ${TODAY}'s file by exact constructed name; nothing reads a historical date,
# /api/comms/ is deny-all (not dashboard- or export-served), and no retention
# section above matched them — so this family grew unbounded one file/day since
# 2026-02-28 (137 files / 13 MB by 2026-07-15). Mirror the section-5 policy:
# compress the forensic record at 30 days, delete the .gz at 180 days. This
# bounds growth while keeping a 180-day compressed history of AI-contact/attack
# classifications (never deleting logging data outright). The ????-??-??-anchored
# glob never matches today's live file, the log-analysis-raw-*.txt dumps swept
# by 6d, or any *-latest pointer.
comms_analysis_compressed=0
comms_analysis_bytes=0
while IFS= read -r -d '' f; do
    if [[ ! -f "${f}.gz" ]]; then
        fsize=$(stat -c%s "$f" 2>/dev/null || echo 0)
        if marvin_is_dry_run; then
            comms_analysis_bytes=$((comms_analysis_bytes + fsize / 2))  # estimate 50% compression
            comms_analysis_compressed=$((comms_analysis_compressed + 1))
        elif gzip "$f" 2>/dev/null; then
            gz_size=$(stat -c%s "${f}.gz" 2>/dev/null || echo 0)
            saved=$((fsize - gz_size))
            [[ "$saved" -lt 0 ]] && saved=0
            comms_analysis_bytes=$((comms_analysis_bytes + saved))
            comms_analysis_compressed=$((comms_analysis_compressed + 1))
        fi
    fi
done < <(find "${COMMS_DIR}" -maxdepth 1 -type f -name 'log-analysis-????-??-??.json' -mtime +30 -print0 2>/dev/null)
if [[ "$comms_analysis_compressed" -gt 0 ]]; then
    track_freed "Compressed ${comms_analysis_compressed} comms log-analysis JSON (>30d)" "$comms_analysis_bytes"
fi

comms_analysis_gz_size=0
while IFS= read -r -d '' f; do
    fsize=$(stat -c%s "$f" 2>/dev/null || echo 0)
    comms_analysis_gz_size=$((comms_analysis_gz_size + fsize))
    marvin_is_dry_run || rm -f "$f"
done < <(find "${COMMS_DIR}" -maxdepth 1 -type f -name 'log-analysis-????-??-??.json.gz' -mtime +180 -print0 2>/dev/null)
track_freed "Old comms log-analysis JSON.gz (>180d)" "$comms_analysis_gz_size"

# ─── 6f. Orphaned nginx request bodies in the negotiate inbox (>1 day) ──────
# ${COMMS_DIR}/negotiate-inbox is negotiate-handler.sh's input directory AND
# nginx's client_body_temp_path for /.well-known/ai-negotiate (see #854/#856).
# Every POST to that endpoint therefore deposits its raw body here — including
# the ones that never reach the handler — and nothing has ever swept them.
#
# These are NOT handler leftovers: negotiate-handler.sh removes its own file on
# every exit path. They are nginx's, written into a directory nginx was told to
# use, which is why reading the handler would never have found them. They are
# www-data-owned and extensionless (nginx names them by a monotonic counter),
# while the handler globs '*.json' — that extension mismatch is the only reason
# they are inert rather than an input path into the handler.
#
# Scope, deliberately narrow on both axes:
#   ! -name '*.json' — a .json file here is handler-owned. The handler leaves
#     one behind on purpose when it must skip a request (see its mid-loop skip
#     path) and will retry it on the next run; deleting those would silently
#     discard a pending peer negotiation. Only files no code path will ever
#     claim are removed.
#   -mtime +1 — nginx is still actively writing bodies into this directory, so
#     the age floor is what keeps an in-flight request body from being deleted
#     out from under a live POST. A day is far beyond any request's lifetime.
#     Note GNU find buckets -mtime by whole days, so a file first qualifies
#     somewhere between 24h and 48h old, not at a tight 24h. That slack only
#     ever errs toward keeping a file longer, which is the safe direction here
#     — but it means this is a growth bound, not a disk-reclaim SLA.
#
# #856 stops nginx creating these; this bounds the ones already here and any
# written before it deploys. Complementary, not a duplicate.
negotiate_inbox_size=0
while IFS= read -r -d '' f; do
    fsize=$(stat -c%s "$f" 2>/dev/null || echo 0)
    negotiate_inbox_size=$((negotiate_inbox_size + fsize))
    marvin_is_dry_run || rm -f "$f"
done < <(find "${COMMS_DIR}/negotiate-inbox" -maxdepth 1 -type f ! -name '*.json' -mtime +1 -print0 2>/dev/null)
track_freed "Orphaned negotiate request bodies (>1d)" "$negotiate_inbox_size"

# ─── 7. Systemd journal vacuum (keep 7 days) ────────────────────────────────

journal_before=$(journalctl --disk-usage 2>/dev/null | grep -oP '[\d.]+[KMGT]' || echo "0")
marvin_is_dry_run || journalctl --vacuum-time=7d --quiet 2>/dev/null || true
journal_after=$(journalctl --disk-usage 2>/dev/null | grep -oP '[\d.]+[KMGT]' || echo "0")
# Log it but don't try to parse the sizes precisely
if [[ "$journal_before" != "$journal_after" ]]; then
    ACTIONS+=("Journal vacuumed: ${journal_before} -> ${journal_after}")
    marvin_log "INFO" "Journal vacuumed: ${journal_before} -> ${journal_after}"
fi

# ─── Report ──────────────────────────────────────────────────────────────────

total_human=$(numfmt --to=iec "$FREED_BYTES" 2>/dev/null || echo "${FREED_BYTES}B")
disk_after=$(df -m / | awk 'NR==2{print $5}')
_prefix=""
marvin_is_dry_run && _prefix="[DRY-RUN] "

if [[ ${#ACTIONS[@]} -gt 0 ]]; then
    if marvin_is_dry_run; then
        marvin_log "INFO" "[DRY-RUN] Disk cleanup complete: would free ${total_human} total. Disk at ${disk_after}."
    else
        marvin_log "INFO" "Disk cleanup complete: freed ${total_human} total. Disk now at ${disk_after}."
    fi
    for action in "${ACTIONS[@]}"; do
        marvin_log "INFO" "  - ${action}"
    done
else
    marvin_log "INFO" "${_prefix}Disk cleanup complete: nothing to clean. Disk at ${disk_after}."
fi
