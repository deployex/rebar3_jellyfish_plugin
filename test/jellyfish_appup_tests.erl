-module(jellyfish_appup_tests).

-include_lib("eunit/include/eunit.hrl").

no_changes_test() ->
    Dir = build_fixture("0.1.0", fun worker_v1/0),
    ?assertEqual(
        {ok, {"0.1.0", [{"0.1.0", []}], [{"0.1.0", []}]}},
        jellyfish_appup:make(fixture_app, "0.1.0", "0.1.0", Dir, Dir)
    ).

changed_and_added_module_test() ->
    V1 = build_fixture("0.1.0", fun worker_v1/0),
    V2 = build_fixture("0.2.0", fun worker_v2_plus_new_module/0),

    {ok, {"0.2.0", [{"0.1.0", Up}], [{"0.1.0", Down}]}} =
        jellyfish_appup:make(fixture_app, "0.1.0", "0.2.0", V1, V2),

    % jf_fixture_worker calls into other modules (e.g. erlang:*) that aren't
    % part of this changeset, so its dependency list is filtered down to [],
    % but the instruction keeps the 4-tuple {update, M, Change, []} shape
    % rather than collapsing to the 3-tuple form - OTP treats the two
    % equivalently at upgrade time.
    ?assertEqual(
        [{add_module, jf_fixture_new}, {update, jf_fixture_worker, {advanced, []}, []}],
        Up
    ),
    ?assertEqual(
        [{delete_module, jf_fixture_new}, {update, jf_fixture_worker, {advanced, []}, []}],
        Down
    ).

% A module that exports code_change/3 only in the new version (the
% ordinary reason it gets added: to migrate a changed state shape) must
% still produce an `advanced` update instruction. The decision has to be
% based on the NEW beam's exports, not the old one, or this migration code
% would silently never run on a module that didn't need code_change before.
otp_behaviour_without_code_change_uses_soft_update_test() ->
    V1 = build_fixture("0.1.0", fun soft_worker_v1/0),
    V2 = build_fixture("0.2.0", fun soft_worker_v2/0),

    {ok, {"0.2.0", [{"0.1.0", Up}], [{"0.1.0", Down}]}} =
        jellyfish_appup:make(fixture_app, "0.1.0", "0.2.0", V1, V2),

    ?assertEqual([{update, jf_fixture_soft_worker, soft, []}], Up),
    ?assertEqual([{update, jf_fixture_soft_worker, soft, []}], Down).

code_change_added_only_in_new_version_test() ->
    V1 = build_fixture("0.1.0", fun special_proc_v1/0),
    V2 = build_fixture("0.2.0", fun special_proc_v2/0),

    {ok, {"0.2.0", [{"0.1.0", Up}], [{"0.1.0", Down}]}} =
        jellyfish_appup:make(fixture_app, "0.1.0", "0.2.0", V1, V2),

    ?assertEqual([{update, jf_fixture_special_proc, {advanced, []}, []}], Up),
    ?assertEqual([{update, jf_fixture_special_proc, {advanced, []}, []}], Down).

mismatched_previous_version_test() ->
    Dir = build_fixture("0.1.0", fun worker_v1/0),
    ?assertEqual(
        {error,
            {appups,
                {mismatched_versions, [
                    {version, previous}, {expected, "9.9.9"}, {got, "0.1.0"}
                ]}}},
        jellyfish_appup:make(fixture_app, "9.9.9", "0.1.0", Dir, Dir)
    ).

mismatched_next_version_test() ->
    Dir = build_fixture("0.1.0", fun worker_v1/0),
    ?assertEqual(
        {error,
            {appups,
                {mismatched_versions, [{version, next}, {expected, "9.9.9"}, {got, "0.1.0"}]}}},
        jellyfish_appup:make(fixture_app, "0.1.0", "9.9.9", Dir, Dir)
    ).

missing_dotapp_test() ->
    Dir = build_fixture("0.1.0", fun worker_v1/0),
    ?assertMatch(
        {error, {appups, file, {invalid_dotapp, _}}},
        jellyfish_appup:make(fixture_app, "0.1.0", "0.1.0", "/nonexistent/path", Dir)
    ).

malformed_dotapp_test() ->
    Dir = build_fixture("0.1.0", fun worker_v1/0),
    BadDir = mk_tmp_dir(),
    BadEbin = filename:join(BadDir, "ebin"),
    ok = filelib:ensure_dir(filename:join(BadEbin, "x")),
    % Not even a valid Erlang term, let alone an {application, ...} tuple.
    ok = file:write_file(filename:join(BadEbin, "fixture_app.app"), "not erlang terms at all"),
    ?assertMatch(
        {error, {appups, file, {invalid_dotapp, _}}},
        jellyfish_appup:make(fixture_app, "0.1.0", "0.1.0", Dir, BadDir)
    ).

supervisor_change_test() ->
    V1 = build_fixture("0.1.0", fun supervisor_v1/0),
    V2 = build_fixture("0.2.0", fun supervisor_v2/0),

    {ok, {"0.2.0", [{"0.1.0", Up}], [{"0.1.0", Down}]}} =
        jellyfish_appup:make(fixture_app, "0.1.0", "0.2.0", V1, V2),

    % A changed supervisor always gets the fixed 3-tuple {update, M,
    % supervisor} form, regardless of what it imports - OTP's release
    % handler treats supervisors specially during a hot upgrade.
    ?assertEqual([{update, jf_fixture_sup, supervisor}], Up),
    ?assertEqual([{update, jf_fixture_sup, supervisor}], Down).

% Documents a known limitation (see the README's "Known Limitations"
% section, and the Erlang appup cookbook on supervisor child specs): adding
% a child to a supervisor's init/1 is, from beam_lib's point of view, just
% an ordinary module change, so it only ever produces the generic
% {update, M, supervisor} instruction. That instruction adds the new
% child's spec, but never actually starts (or, on removal, stops) the
% corresponding process - a hand-added {apply, {supervisor, start_child,
% [...]}} instruction via EDIT_APPUP is required for that.
supervisor_added_child_test() ->
    V1 = build_fixture("0.1.0", fun supervisor_added_child_v1/0),
    V2 = build_fixture("0.2.0", fun supervisor_added_child_v2/0),

    {ok, {"0.2.0", [{"0.1.0", Up}], [{"0.1.0", Down}]}} =
        jellyfish_appup:make(fixture_app, "0.1.0", "0.2.0", V1, V2),

    ?assertEqual([{update, jf_fixture_sup, supervisor}], Up),
    ?assertEqual([{update, jf_fixture_sup, supervisor}], Down).

deleted_module_test() ->
    V1 = build_fixture("0.1.0", fun worker_v1/0),
    V2 = build_fixture("0.2.0", fun() -> [] end),

    {ok, {"0.2.0", [{"0.1.0", Up}], [{"0.1.0", Down}]}} =
        jellyfish_appup:make(fixture_app, "0.1.0", "0.2.0", V1, V2),

    ?assertEqual([{delete_module, jf_fixture_worker}], Up),
    ?assertEqual([{add_module, jf_fixture_worker}], Down).

unchanged_module_alongside_a_deletion_test() ->
    V1 = build_fixture("0.1.0", fun worker_plus_doomed_v1/0),
    V2 = build_fixture("0.2.0", fun() -> [] end),
    % jf_fixture_worker is meant to be byte-identical in both versions, but
    % two separate compiles of identical source are not guaranteed to
    % produce identical beams (e.g. a toolchain embedding build-specific
    % metadata outside the already-filtered Dbgi chunk) - copying V1's exact
    % beam into V2 keeps this test about deletion, not compiler determinism.
    ok = copy_beam(V1, V2, jf_fixture_worker),

    {ok, {"0.2.0", [{"0.1.0", Up}], [{"0.1.0", Down}]}} =
        jellyfish_appup:make(fixture_app, "0.1.0", "0.2.0", V1, V2),

    ?assertEqual([{delete_module, jf_fixture_doomed}], Up),
    ?assertEqual([{add_module, jf_fixture_doomed}], Down).

dependency_ordering_test() ->
    V1 = build_fixture("0.1.0", fun two_modules_v1/0),
    V2 = build_fixture("0.2.0", fun two_modules_v2/0),

    {ok, {"0.2.0", [{"0.1.0", Up}], [{"0.1.0", Down}]}} =
        jellyfish_appup:make(fixture_app, "0.1.0", "0.2.0", V1, V2),

    % jf_fixture_dep_a calls jf_fixture_dep_b, so b (no outgoing deps of its
    % own within this changeset, once filtered - see the comment on the
    % 4-tuple shape in changed_and_added_module_test above) must be
    % loaded/updated before a.
    ?assertEqual(
        [
            {load_module, jf_fixture_dep_b, []},
            {load_module, jf_fixture_dep_a, [jf_fixture_dep_b]}
        ],
        Up
    ),
    ?assertEqual(
        [
            {load_module, jf_fixture_dep_b, []},
            {load_module, jf_fixture_dep_a, [jf_fixture_dep_b]}
        ],
        Down
    ).

mixed_add_delete_and_change_test() ->
    V1 = build_fixture("0.1.0", fun mixed_v1/0),
    V2 = build_fixture("0.2.0", fun mixed_v2/0),
    % jf_fixture_stable is meant to be byte-identical across versions - see
    % the comment on unchanged_module_alongside_a_deletion_test above for
    % why it's copied rather than recompiled from the same source.
    ok = copy_beam(V1, V2, jf_fixture_stable),

    {ok, {"0.2.0", [{"0.1.0", Up}], [{"0.1.0", Down}]}} =
        jellyfish_appup:make(fixture_app, "0.1.0", "0.2.0", V1, V2),

    % Order follows make_appup's own concatenation: added, then changed,
    % then deleted (reversed for the downgrade direction) - jf_fixture_stable
    % appears nowhere, having changed in neither direction.
    ?assertEqual(
        [
            {add_module, jf_fixture_new},
            {update, jf_fixture_changed, {advanced, []}, []},
            {delete_module, jf_fixture_doomed}
        ],
        Up
    ),
    ?assertEqual(
        [
            {delete_module, jf_fixture_new},
            {update, jf_fixture_changed, {advanced, []}, []},
            {add_module, jf_fixture_doomed}
        ],
        Down
    ).

%% ===================================================================
%% Fixtures
%%
%% Each fixture is a tiny, freshly-compiled "application" directory (ebin
%% + a hand-written .app) so the test exercises real beam_lib diffing
%% without committing prebuilt .beam files that would need to track the
%% OTP version this suite happens to run under.
%% ===================================================================

build_fixture(Vsn, ModulesFun) ->
    Dir = mk_tmp_dir(),
    EbinDir = filename:join(Dir, "ebin"),
    ok = filelib:ensure_dir(filename:join(EbinDir, "x")),

    Modules = ModulesFun(),
    lists:foreach(fun(Source) -> compile_into(Source, EbinDir) end, Modules),

    ModuleNames = [M || {M, _Source} <- Modules],
    write_dotapp(EbinDir, Vsn, ModuleNames),

    Dir.

worker_v1() ->
    [
        {jf_fixture_worker,
            "-module(jf_fixture_worker).\n"
            "-behaviour(gen_server).\n"
            "-export([init/1, handle_call/3, code_change/3]).\n"
            "init(_Args) -> {ok, v1}.\n"
            "handle_call(_Req, _From, State) -> {reply, ok, State}.\n"
            "code_change(_OldVsn, State, _Extra) -> {ok, State}.\n"}
    ].

worker_v2_plus_new_module() ->
    [
        {jf_fixture_worker,
            "-module(jf_fixture_worker).\n"
            "-behaviour(gen_server).\n"
            "-export([init/1, handle_call/3, code_change/3]).\n"
            "init(_Args) -> {ok, v2}.\n"
            "handle_call(_Req, _From, State) -> {reply, ok, State}.\n"
            "code_change(_OldVsn, State, _Extra) -> {ok, State}.\n"},
        {jf_fixture_new,
            "-module(jf_fixture_new).\n"
            "-export([ping/0]).\n"
            "ping() -> pong.\n"}
    ].

worker_plus_doomed_v1() ->
    worker_v1() ++
        [
            {jf_fixture_doomed,
                "-module(jf_fixture_doomed).\n"
                "-export([ping/0]).\n"
                "ping() -> pong.\n"}
        ].

soft_worker_v1() ->
    [
        {jf_fixture_soft_worker,
            "-module(jf_fixture_soft_worker).\\n"
            "-behaviour(gen_server).\\n"
            "-export([init/1, handle_call/3]).\\n"
            "init(_Args) -> {ok, v1}.\\n"
            "handle_call(_Req, _From, State) -> {reply, ok, State}.\\n"}
    ].

soft_worker_v2() ->
    [
        {jf_fixture_soft_worker,
            "-module(jf_fixture_soft_worker).\\n"
            "-behaviour(gen_server).\\n"
            "-export([init/1, handle_call/3]).\\n"
            "init(_Args) -> {ok, v2}.\\n"
            "handle_call(_Req, _From, State) -> {reply, ok, State}.\\n"}
    ].

special_proc_v1() ->
    [
        {jf_fixture_special_proc,
            "-module(jf_fixture_special_proc).\n"
            "-behaviour(gen_server).\n"
            "-export([init/1, handle_call/3]).\n"
            "init(_Args) -> {ok, v1}.\n"
            "handle_call(_Req, _From, State) -> {reply, ok, State}.\n"}
    ].

special_proc_v2() ->
    [
        {jf_fixture_special_proc,
            "-module(jf_fixture_special_proc).\n"
            "-behaviour(gen_server).\n"
            "-export([init/1, handle_call/3, code_change/3]).\n"
            "init(_Args) -> {ok, {v2, 0}}.\n"
            "handle_call(_Req, _From, State) -> {reply, ok, State}.\n"
            "code_change(_OldVsn, OldState, _Extra) -> {ok, {v2, OldState}}.\n"}
    ].

supervisor_v1() ->
    [
        {jf_fixture_sup,
            "-module(jf_fixture_sup).\n"
            "-behaviour(supervisor).\n"
            "-export([init/1]).\n"
            "init([]) -> {ok, {{one_for_one, 5, 10}, []}}.\n"}
    ].

supervisor_v2() ->
    [
        {jf_fixture_sup,
            "-module(jf_fixture_sup).\n"
            "-behaviour(supervisor).\n"
            "-export([init/1]).\n"
            "init([]) -> {ok, {{one_for_one, 3, 10}, []}}.\n"}
    ].

supervisor_added_child_v1() ->
    [
        {jf_fixture_sup,
            "-module(jf_fixture_sup).\n"
            "-behaviour(supervisor).\n"
            "-export([init/1]).\n"
            "init([]) -> {ok, {{one_for_one, 5, 10}, [child_spec(worker_one)]}}.\n"
            "child_spec(Id) -> #{id => Id, start => {jf_fixture_sup, noop, []}}.\n"}
    ].

supervisor_added_child_v2() ->
    [
        {jf_fixture_sup,
            "-module(jf_fixture_sup).\n"
            "-behaviour(supervisor).\n"
            "-export([init/1]).\n"
            "init([]) -> {ok, {{one_for_one, 5, 10}, [child_spec(worker_one), child_spec(worker_two)]}}.\n"
            "child_spec(Id) -> #{id => Id, start => {jf_fixture_sup, noop, []}}.\n"}
    ].

two_modules_v1() ->
    [
        {jf_fixture_dep_b,
            "-module(jf_fixture_dep_b).\n"
            "-export([go/0]).\n"
            "go() -> 1.\n"},
        {jf_fixture_dep_a,
            "-module(jf_fixture_dep_a).\n"
            "-export([go/0]).\n"
            "go() -> jf_fixture_dep_b:go().\n"}
    ].

two_modules_v2() ->
    [
        {jf_fixture_dep_b,
            "-module(jf_fixture_dep_b).\n"
            "-export([go/0]).\n"
            "go() -> 2.\n"},
        {jf_fixture_dep_a,
            "-module(jf_fixture_dep_a).\n"
            "-export([go/0]).\n"
            "go() -> jf_fixture_dep_b:go() + 1.\n"}
    ].

mixed_v1() ->
    [
        {jf_fixture_stable,
            "-module(jf_fixture_stable).\n"
            "-export([ping/0]).\n"
            "ping() -> pong.\n"},
        {jf_fixture_changed,
            "-module(jf_fixture_changed).\n"
            "-behaviour(gen_server).\n"
            "-export([init/1, handle_call/3, code_change/3]).\n"
            "init(_Args) -> {ok, v1}.\n"
            "handle_call(_Req, _From, State) -> {reply, ok, State}.\n"
            "code_change(_OldVsn, State, _Extra) -> {ok, State}.\n"},
        {jf_fixture_doomed,
            "-module(jf_fixture_doomed).\n"
            "-export([ping/0]).\n"
            "ping() -> pong.\n"}
    ].

mixed_v2() ->
    [
        {jf_fixture_changed,
            "-module(jf_fixture_changed).\n"
            "-behaviour(gen_server).\n"
            "-export([init/1, handle_call/3, code_change/3]).\n"
            "init(_Args) -> {ok, v2}.\n"
            "handle_call(_Req, _From, State) -> {reply, ok, State}.\n"
            "code_change(_OldVsn, State, _Extra) -> {ok, State}.\n"},
        {jf_fixture_new,
            "-module(jf_fixture_new).\n"
            "-export([ping/0]).\n"
            "ping() -> pong.\n"}
    ].

copy_beam(FromDir, ToDir, Module) ->
    FromFile = filename:join([FromDir, "ebin", atom_to_list(Module) ++ ".beam"]),
    ToFile = filename:join([ToDir, "ebin", atom_to_list(Module) ++ ".beam"]),
    {ok, _} = file:copy(FromFile, ToFile),
    ok.

compile_into({Module, Source}, EbinDir) ->
    SrcPath = filename:join(EbinDir, atom_to_list(Module) ++ ".erl"),
    ok = file:write_file(SrcPath, Source),
    {ok, Module} = compile:file(SrcPath, [{outdir, EbinDir}, debug_info, return_errors]),
    ok = file:delete(SrcPath).

write_dotapp(EbinDir, Vsn, Modules) ->
    Contents = io_lib:format(
        "{application, fixture_app, [{vsn, \"~s\"}, {modules, ~p}, {applications, []}, {description, \"\"}]}.~n",
        [Vsn, Modules]
    ),
    ok = file:write_file(filename:join(EbinDir, "fixture_app.app"), Contents).

mk_tmp_dir() ->
    % os:getpid() guards against collisions across separate test runs, not
    % just within one: erlang:unique_integer/1's counter restarts from a
    % low value on every fresh VM, so without it a leftover directory from
    % an earlier run (nothing here ever deletes its own tmp dirs) could get
    % silently reused and its stale files bleed into an unrelated test.
    Dir = filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "jellyfish_appup_tests",
        os:getpid() ++ "-" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Dir.
