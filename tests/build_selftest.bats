#!/usr/bin/env bats

# package_bundle moves the finished tarball into dist/ under its real release
# name BEFORE run_selftest runs against it, so a failed selftest must mark the
# tarball or it sits in dist/ looking exactly like a passing release.
#
# These tests drive a real `bash` subprocess rather than bats' `run main ...`
# on purpose: `run` does `set +eET`, which would disable exactly the errexit
# behavior under test. The driver sources build.sh (the bottom-of-file
# `BASH_SOURCE == $0` guard keeps main from auto-running) and overrides the
# expensive steps so no docker, network or real tarball is needed.

write_driver() {
    local path="$1" selftest_body="$2" tarball="$3"
    cat > "$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$BATS_TEST_DIRNAME/../build.sh"
load_versions()  { GUACAMOLE_TAG=1.6.0; }
pull_images()    { :; }
package_bundle() { printf '%s\n' "$tarball"; }
run_selftest() {
${selftest_body}
}
main "\$@"
EOF
}

@test "a failed selftest renames the tarball so it cannot pass for a release" {
    tarball="$BATS_TEST_TMPDIR/guacamole-offline-1.6.0-20260914.tar.gz"
    echo "fake tarball" > "$tarball"
    write_driver "$BATS_TEST_TMPDIR/drive.sh" \
        '    ( die "simulated selftest failure" )' "$tarball"

    run bash "$BATS_TEST_TMPDIR/drive.sh" --selftest
    [ "$status" -ne 0 ]
    [[ "$output" == *"simulated selftest failure"* ]]
    [[ "$output" == *".FAILED"* ]]
    [ ! -f "$tarball" ]
    [ -f "${tarball}.FAILED" ]
}

@test "a passing selftest leaves the tarball under its release name" {
    tarball="$BATS_TEST_TMPDIR/guacamole-offline-1.6.0-20260914.tar.gz"
    echo "fake tarball" > "$tarball"
    write_driver "$BATS_TEST_TMPDIR/drive_ok.sh" '    ( : )' "$tarball"

    run bash "$BATS_TEST_TMPDIR/drive_ok.sh" --selftest
    [ "$status" -eq 0 ]
    [ -f "$tarball" ]
    [ ! -f "${tarball}.FAILED" ]
}

@test "a build without --selftest never touches the tarball name" {
    tarball="$BATS_TEST_TMPDIR/guacamole-offline-1.6.0-20260914.tar.gz"
    echo "fake tarball" > "$tarball"
    write_driver "$BATS_TEST_TMPDIR/drive_noselftest.sh" \
        '    ( die "this must never run" )' "$tarball"

    run bash "$BATS_TEST_TMPDIR/drive_noselftest.sh"
    [ "$status" -eq 0 ]
    [ -f "$tarball" ]
    [ ! -f "${tarball}.FAILED" ]
}

@test "the selftest still aborts on its own unguarded failures (errexit intact)" {
    # The regression guard for the fix itself: marking the tarball must not be
    # implemented by putting run_selftest in a condition context, because bash
    # propagates that errexit suppression into run_selftest's own subshell and
    # every unguarded command in it would stop aborting the selftest.
    tarball="$BATS_TEST_TMPDIR/guacamole-offline-1.6.0-20260914.tar.gz"
    echo "fake tarball" > "$tarball"
    write_driver "$BATS_TEST_TMPDIR/drive_errexit.sh" \
        '    (
        echo "selftest: step one"
        false
        echo "selftest: step two MUST NOT RUN"
    )' "$tarball"

    run bash "$BATS_TEST_TMPDIR/drive_errexit.sh" --selftest
    [ "$status" -ne 0 ]
    [[ "$output" == *"step one"* ]]
    [[ "$output" != *"MUST NOT RUN"* ]]
    [ -f "${tarball}.FAILED" ]
}
