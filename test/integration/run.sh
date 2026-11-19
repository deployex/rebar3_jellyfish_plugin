#!/usr/bin/env bash
# Builds two tiny rebar3 projects (a plain app and a two-app umbrella) with
# rebar3_jellyfish_plugin wired in, through a real v1 -> code change -> v2
# release cycle, and inspects the resulting .tar.gz: does the appup and
# jellyfish.json actually land where DeployEx expects them, with the right
# content.
#
# rebar3's `path` dependency type does not reliably fetch/load a plugin
# (observed against rebar3 3.27.0), so this script snapshots the plugin's
# current working tree into a throwaway git repo and has every scratch
# project depend on that instead. This also means it exercises whatever is
# currently checked out, uncommitted changes included - useful when running
# locally, and exactly what a CI checkout provides too.
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0

log() { printf '%s\n' "$*"; }
ok() { PASS=$((PASS + 1)); log "  OK   $*"; }
bad() {
    FAIL=$((FAIL + 1))
    log "  FAIL $*"
}

assert_file() {
    if [ -f "$1" ]; then ok "$1 exists"; else bad "$1 is missing"; fi
}

assert_no_file() {
    if [ -f "$1" ]; then bad "$1 should not exist"; else ok "$1 correctly absent"; fi
}

snapshot_plugin() {
    local dest="$WORKDIR/plugin_snapshot"
    mkdir -p "$dest"
    # rsync-free copy: good enough for a source tree this size, and avoids an
    # extra dependency on the host having rsync installed.
    cp -R "$PLUGIN_ROOT"/. "$dest"/
    rm -rf "$dest/_build" "$dest/.git"
    git -C "$dest" init -q -b integration-test
    git -C "$dest" add -A
    git -C "$dest" -c user.email=ci@example.com -c user.name=ci commit -q -m snapshot
    echo "$dest"
}

plugin_rebar_config_stanza() {
    local snapshot_dir="$1"
    cat <<EOF
{project_plugins, [{rebar3_jellyfish_plugin, {git, "file://${snapshot_dir}", {branch, "integration-test"}}}]}.
{provider_hooks, [
    {post, [{compile, {jellyfish, appup}}]}
]}.
EOF
}

build() {
    (cd "$1" && rebar3 tar >/"$1"/build.log 2>&1) || {
        bad "build failed in $1, see $1/build.log"
        tail -40 "$1/build.log" || true
        return 1
    }
    ok "build succeeded in $(basename "$1")"
}

# ===================================================================
# Scenario 1: a plain single-app project
# ===================================================================
run_single_app_scenario() {
    local snapshot_dir="$1"
    local proj="$WORKDIR/single_app"
    mkdir -p "$proj/src"

    {
        plugin_rebar_config_stanza "$snapshot_dir"
        cat <<'EOF'
{erl_opts, [debug_info]}.
{deps, []}.
{relx, [{release, {single_app, "0.1.0"}, [single_app]},
        {dev_mode, false},
        {include_erts, false},
        {extended_start_script, true},
        {overlay, [{copy, "rel/appups/lib", "lib"}]}]}.
EOF
    } >"$proj/rebar.config"

    write_app_src "$proj" single_app 0.1.0
    write_worker "$proj" 1

    log "--- single app: building v0.1.0 (no previous version yet) ---"
    build "$proj"
    assert_no_file "$proj/_build/default/rel/single_app/lib/single_app-0.1.0/ebin/jellyfish.json"

    sed -i.bak 's/0\.1\.0/0.1.1/' "$proj/rebar.config" "$proj/src/single_app.app.src"
    rm -f "$proj/rebar.config.bak" "$proj/src/single_app.app.src.bak"
    write_worker "$proj" 2

    log "--- single app: building v0.1.1 (real code change) ---"
    build "$proj"

    local tarball="$proj/_build/default/rel/single_app/single_app-0.1.1.tar.gz"
    assert_file "$tarball"

    local extract="$WORKDIR/single_app_extract"
    mkdir -p "$extract"
    tar -xzf "$tarball" -C "$extract"

    assert_file "$extract/lib/single_app-0.1.1/ebin/single_app.appup"
    assert_file "$extract/lib/single_app-0.1.1/ebin/jellyfish.json"

    check_jellyfish_json "$extract/lib/single_app-0.1.1/ebin/jellyfish.json" single_app project 0.1.0 0.1.1
    check_appup "$extract/lib/single_app-0.1.1/ebin/single_app.appup" 0.1.1 0.1.0
}

# ===================================================================
# Scenario 2: a two-app umbrella, only one app actually changes
# ===================================================================
run_umbrella_scenario() {
    local snapshot_dir="$1"
    local proj="$WORKDIR/umbrella"
    mkdir -p "$proj/apps/app_a/src" "$proj/apps/app_b/src"

    {
        plugin_rebar_config_stanza "$snapshot_dir"
        cat <<'EOF'
{erl_opts, [debug_info]}.
{deps, []}.
{relx, [{release, {umbrella, "0.1.0"}, [app_a, app_b]},
        {dev_mode, false},
        {include_erts, false},
        {extended_start_script, true},
        {overlay, [{copy, "rel/appups/lib", "lib"}]}]}.
EOF
    } >"$proj/rebar.config"

    write_app_src "$proj/apps/app_a" app_a 0.1.0
    write_worker "$proj/apps/app_a" 1
    write_app_src "$proj/apps/app_b" app_b 0.1.0
    write_worker "$proj/apps/app_b" 1

    log "--- umbrella: building v0.1.0 for both apps (no previous version yet) ---"
    build "$proj"

    # Only app_a changes: version bump + a real code change. app_b is left
    # completely untouched, same version and same source.
    sed -i.bak 's/0\.1\.0/0.1.1/' "$proj/apps/app_a/src/app_a.app.src"
    rm -f "$proj/apps/app_a/src/app_a.app.src.bak"
    write_worker "$proj/apps/app_a" 2
    sed -i.bak 's/{release, {umbrella, "0.1.0"}/{release, {umbrella, "0.1.1"}/' "$proj/rebar.config"
    rm -f "$proj/rebar.config.bak"

    log "--- umbrella: building v0.1.1 (only app_a changed) ---"
    build "$proj"

    local tarball="$proj/_build/default/rel/umbrella/umbrella-0.1.1.tar.gz"
    assert_file "$tarball"

    local extract="$WORKDIR/umbrella_extract"
    mkdir -p "$extract"
    tar -xzf "$tarball" -C "$extract"

    assert_file "$extract/lib/app_a-0.1.1/ebin/app_a.appup"
    assert_file "$extract/lib/app_a-0.1.1/ebin/jellyfish.json"
    check_jellyfish_json "$extract/lib/app_a-0.1.1/ebin/jellyfish.json" app_a project 0.1.0 0.1.1
    check_appup "$extract/lib/app_a-0.1.1/ebin/app_a.appup" 0.1.1 0.1.0

    # app_b never changed version, so there is nothing to diff against: it
    # must not get an appup or jellyfish.json at all.
    assert_no_file "$extract/lib/app_b-0.1.0/ebin/app_b.appup"
    assert_no_file "$extract/lib/app_b-0.1.0/ebin/jellyfish.json"
}

# ===================================================================
# Fixture writers
# ===================================================================

write_app_src() {
    local dir="$1" app="$2" vsn="$3"
    cat >"$dir/src/${app}.app.src" <<EOF
{application, ${app},
 [{description, "integration test app"},
  {vsn, "${vsn}"},
  {registered, []},
  {mod, {${app}_app, []}},
  {applications, [kernel, stdlib]},
  {env, []},
  {modules, []}
 ]}.
EOF
    cat >"$dir/src/${app}_app.erl" <<EOF
-module(${app}_app).
-behaviour(application).
-export([start/2, stop/1]).
start(_Type, _Args) -> ${app}_worker:start_link().
stop(_State) -> ok.
EOF
}

write_worker() {
    local dir="$1" revision="$2"
    local app
    app="$(basename "$(ls "$dir"/src/*.app.src | head -1)" .app.src)"
    cat >"$dir/src/${app}_worker.erl" <<EOF
-module(${app}_worker).
-behaviour(gen_server).
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, code_change/3]).
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
init([]) -> {ok, ${revision}}.
handle_call(_Req, _From, State) -> {reply, State, State}.
handle_cast(_Msg, State) -> {noreply, State}.
code_change(_OldVsn, State, _Extra) -> {ok, State + ${revision}}.
EOF
}

# ===================================================================
# Content checks
# ===================================================================

check_jellyfish_json() {
    local path="$1" name="$2" type="$3" from="$4" to="$5"
    local content
    content="$(cat "$path")"

    for pair in "\"name\": \"${name}\"" "\"type\": \"${type}\"" "\"from\": \"${from}\"" "\"to\": \"${to}\"" '"format_version": 1'; do
        if grep -qF "$pair" <<<"$content"; then
            ok "jellyfish.json ($path) has ${pair}"
        else
            bad "jellyfish.json ($path) missing ${pair}, got: $content"
        fi
    done

    if grep -q '"generator": "rebar3_jellyfish_plugin/' <<<"$content"; then
        ok "jellyfish.json ($path) has a generator field"
    else
        bad "jellyfish.json ($path) missing generator field, got: $content"
    fi
}

check_appup() {
    local path="$1" to="$2" from="$3"
    # A real term parse, not just text matching: this is what DeployEx's
    # check_app_up/3 does with the file too.
    erl -noshell -eval "
        case file:consult(\"$path\") of
            {ok, [{\"$to\", [{\"$from\", _}], [{\"$from\", _}]}]} ->
                halt(0);
            Other ->
                io:format(\"unexpected appup shape: ~p~n\", [Other]),
                halt(1)
        end
    " && ok "$path parses as a valid {$to, [{$from,_}], [{$from,_}]} appup" \
        || bad "$path did not parse as the expected appup shape"
}

# ===================================================================
# Main
# ===================================================================

log "Snapshotting plugin from $PLUGIN_ROOT..."
SNAPSHOT_DIR="$(snapshot_plugin)"

run_single_app_scenario "$SNAPSHOT_DIR"
run_umbrella_scenario "$SNAPSHOT_DIR"

log ""
log "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
