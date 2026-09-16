#!/usr/bin/env bats

# build.sh deliberately duplicates a few lines from bundle/install.sh rather
# than sourcing it: the two scripts run on different machines (build side vs.
# air-gapped target), and install.sh must stay self-contained. The duplicated
# lines are how --run-local produces the same .env/TLS material and reads the
# same compose image list the real installer does. These tests lock each pair
# so a change to one side cannot silently leave the other behind.
#
# If one of these fails: either apply the same change to the other script, or
# decide the two should now differ and update the fragment here.

assert_in_both() {
    local fragment="$1"
    grep -qF -- "$fragment" build.sh \
        || { echo "build.sh no longer contains: $fragment"; return 1; }
    grep -qF -- "$fragment" bundle/install.sh \
        || { echo "bundle/install.sh no longer contains: $fragment"; return 1; }
}

@test "the Postgres password is generated the same way in build.sh and install.sh" {
    assert_in_both 'openssl rand -base64 24'
}

@test "env.template is substituted with the same placeholder and sed in build.sh and install.sh" {
    assert_in_both 'sed "s|__POSTGRES_PASSWORD__|${pg_password}|"'
    grep -q '__POSTGRES_PASSWORD__' bundle/env.template
}

@test "the self-signed TLS certificate is generated the same way in build.sh and install.sh" {
    assert_in_both 'openssl req -x509 -nodes -newkey rsa:2048'
    assert_in_both '-subj "/CN=guacamole.local"'
}

@test "compose_image_refs uses the identical awk in build.sh and install.sh" {
    assert_in_both "awk '\$1 == \"image:\" { print \$2 }'"
}
