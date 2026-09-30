# chkrootkit FILTER stage — collapses a Linux.Xor.DDoS WARNING back to
# "not found" when every listed path is inside this host's own /tmp test
# scratch dirs (the same benign class /etc/chkrootkit/chkrootkit.ignore's
# `^/tmp/[^.]` line already hides from the file list). Without this, the
# ignore file strips the file list but leaves the "WARNING" header and the
# "WARNING: Possible ... installed:" line behind, so chkrootkit-daily's
# diff-mode alerting fires on the header even though the body is empty.
# See issue #1147.
#
# Runs as part of $FILTER (before $IGNORE_FILE), so it must apply the same
# /tmp/[^.] test itself to decide whether any *real* hit remains.
#
# Any listed path outside that pattern is treated as real and passed through
# unfiltered — this only ever suppresses noise, never a genuine hit.

/^Searching for Linux\.Xor\.DDoS\.\.\./ {
    header = $0
    in_block = 1
    nbuf = 0
    delete buf
    next
}

in_block && /^Searching for / {
    real = 0
    for (i = 1; i <= nbuf; i++) {
        if (buf[i] !~ /^\/tmp\/[^.]/) real++
    }
    if (real == 0) {
        sub(/WARNING[ \t]*$/, "not found", header)
        print header
    } else {
        print header
        print ""
        print "WARNING: Possible Linux.Xor.DDoS installed:"
        for (i = 1; i <= nbuf; i++) {
            if (buf[i] !~ /^\/tmp\/[^.]/) print buf[i]
        }
    }
    in_block = 0
    print
    next
}

in_block {
    if ($0 ~ /^\//) buf[++nbuf] = $0
    next
}

{ print }

END {
    if (in_block) {
        real = 0
        for (i = 1; i <= nbuf; i++) {
            if (buf[i] !~ /^\/tmp\/[^.]/) real++
        }
        if (real == 0) {
            sub(/WARNING[ \t]*$/, "not found", header)
            print header
        } else {
            print header
            print ""
            print "WARNING: Possible Linux.Xor.DDoS installed:"
            for (i = 1; i <= nbuf; i++) {
                if (buf[i] !~ /^\/tmp\/[^.]/) print buf[i]
            }
        }
    }
}
