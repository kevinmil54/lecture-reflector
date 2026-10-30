#!/bin/bash
# Build watcher for Lecture Reflector.
# Start it once in Terminal (./autobuild.sh) and leave the window open.
# Whenever a file named .build-request appears in this folder, it runs a
# Release build, writes the full log to build-output/build.log and the
# result (SUCCEEDED or FAILED) to build-output/status, then deletes the
# request. A file named .install-request runs ./install.sh instead (build,
# then replace /Applications/LectureReflector.app), logging to
# build-output/install.log. Nothing else is run. Stop it with Control-C.

cd "$(dirname "$0")" || exit 1
mkdir -p build-output
echo "Watching for build requests in $(pwd). Press Control-C to stop."

while true; do
    if [ -f .build-request ]; then
        rm -f .build-request
        echo "RUNNING $(date '+%Y-%m-%d %H:%M:%S')" > build-output/status
        echo "$(date '+%H:%M:%S')  Building..."
        if ./build.sh build Release > build-output/build.log 2>&1; then
            result="SUCCEEDED"
        else
            result="FAILED"
        fi
        echo "$result $(date '+%Y-%m-%d %H:%M:%S')" > build-output/status
        grep -E "error:|warning:" build-output/build.log | grep -v "^ld: warning" | sort -u > build-output/issues.txt
        echo "$(date '+%H:%M:%S')  $result ($(grep -c 'error:' build-output/issues.txt) errors)"
    fi
    if [ -f .install-request ]; then
        rm -f .install-request
        echo "RUNNING install $(date '+%Y-%m-%d %H:%M:%S')" > build-output/status
        echo "$(date '+%H:%M:%S')  Building and installing into /Applications..."
        if ./install.sh > build-output/install.log 2>&1; then
            result="INSTALLED"
        else
            result="INSTALL FAILED"
        fi
        echo "$result $(date '+%Y-%m-%d %H:%M:%S')" > build-output/status
        echo "$(date '+%H:%M:%S')  $result"
    fi
    sleep 2
done
