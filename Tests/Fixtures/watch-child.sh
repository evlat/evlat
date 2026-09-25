#!/bin/sh
# The command `WatchTests` wraps with `Evlat watch` (`012/phase-4`). Run as
# `sh watch-child.sh MODE [ARG]`, so the checkout need not keep an exec bit.
#
#   exit N    exits with N
#   bytes     writes fixed bytes to stdout and stderr (colour codes, UTF-8, a
#             control byte, no final newline) and exits 0
#   die SIG   kills itself with SIG — as a child killed by Ctrl-C ends
#   sleep     sleeps 30 s in place of itself; a signal is expected to end it

case "$1" in
    exit) exit "$2" ;;
    bytes)
        printf 'out \033[31mred\033[0m \303\244\n\001tail'
        printf 'err line\nno newline' >&2
        exit 0 ;;
    die)
        kill -"$2" $$
        # Only reached if the signal was ignored: the trap the wrapper's
        # reset exists for (an inherited SIG_IGN).
        exit 99 ;;
    sleep) exec sleep 30 ;;
    *) echo "unknown mode: $1" >&2; exit 64 ;;
esac
