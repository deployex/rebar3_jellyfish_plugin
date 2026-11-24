-module(rebar3_jellyfish_prv_appup_tests).

-include_lib("eunit/include/eunit.hrl").

%% ===================================================================
%% compare_versions/2 - "highest version first" comparator used to pick
%% the previous release to diff against.
%% ===================================================================

numeric_versions_sort_by_magnitude_not_lexically_test() ->
    % A plain string/lexicographic compare would put "0.1.9" after
    % "0.1.10" ("1" < "9" per character), which is backwards.
    ?assert(rebar3_jellyfish_prv_appup:compare_versions("0.1.10", "0.1.9")),
    ?assertNot(rebar3_jellyfish_prv_appup:compare_versions("0.1.9", "0.1.10")).

equal_versions_compare_true_either_way_test() ->
    % compare_versions is used as a `lists:sort/2` ordering function, which
    % requires a true result for equal elements (a "weak" <=), not just <.
    ?assert(rebar3_jellyfish_prv_appup:compare_versions("1.2.3", "1.2.3")).

major_version_dominates_test() ->
    ?assert(rebar3_jellyfish_prv_appup:compare_versions("2.0.0", "1.9.9")),
    ?assertNot(rebar3_jellyfish_prv_appup:compare_versions("1.9.9", "2.0.0")).

%% The order has to be the one Jellyfish uses, so that a project built with
%% either tool diffs against the same previous version.

pre_release_is_lower_than_its_release_test() ->
    ?assert(higher("1.0.0", "1.0.0-rc1")),
    ?assert(higher("1.0.0-rc2", "1.0.0-rc1")),
    ?assert(higher("1.0.1-rc1", "1.0.0")),
    % Numeric identifiers compare as numbers, and are lower than text ones
    ?assert(higher("1.0.0-rc.10", "1.0.0-rc.9")),
    ?assert(higher("1.0.0-alpha", "1.0.0-1")),
    % A shorter list of identifiers is lower than a longer one it starts
    ?assert(higher("1.0.0-rc.1", "1.0.0-rc")).

numeric_parts_decide_before_the_suffix_test() ->
    % As text, "0.10.0-x" is lower than "0.9.0-x"
    ?assert(higher("0.10.0-9cad9cd", "0.9.0-f00dfee")),
    ?assert(higher("0.10.0-rc1", "0.9.0")).

any_number_of_numeric_parts_test() ->
    ?assert(higher("1.10", "1.9")),
    ?assert(higher("1.2.3.10", "1.2.3.9")),
    ?assert(same("1.2", "1.2.0")).

build_metadata_is_ignored_test() ->
    ?assert(same("1.0.0+abc", "1.0.0")),
    ?assert(same("1.0.0+abc", "1.0.0+def")),
    ?assert(higher("1.0.1+abc", "1.0.0+def")).

git_describe_is_higher_than_its_release_test() ->
    ?assert(higher("1.0.0-4-gabc1234", "1.0.0")),
    ?assert(higher("1.0.0-10-gabc1234", "1.0.0-9-gfff0000")),
    ?assert(higher("1.0.1", "1.0.0-4-gabc1234")),
    % The commit and not the count is what differs here
    ?assert(same("1.0.0-4-gabc1234", "1.0.0-4-gfff0000")).

a_build_identifier_orders_as_text_test() ->
    % Two builds of one version: the text decides, not when they were built
    ?assert(higher("0.1.0-f00dfee", "0.1.0-9cad9cd")).

unparseable_version_is_lower_and_does_not_crash_test() ->
    ?assert(higher("0.0.1", "main")),
    ?assert(higher("0.0.1-rc1", "main")),
    ?assert(higher("main", "develop")),
    ?assert(same("main", "main")),
    [
        ?assert(is_boolean(rebar3_jellyfish_prv_appup:compare_versions(A, B)))
     || A <- odd_versions(), B <- odd_versions()
    ].

odd_versions() ->
    ["", "1..2", "1.0.0-", "1.0.0-rc..1", "-rc1", "1.0.0-a-b", "v1.0.0", "1.0.0+"].

%% compare_versions/2 is "A is not lower than B"
higher(A, B) ->
    rebar3_jellyfish_prv_appup:compare_versions(A, B) andalso
        not rebar3_jellyfish_prv_appup:compare_versions(B, A).

same(A, B) ->
    rebar3_jellyfish_prv_appup:compare_versions(A, B) andalso
        rebar3_jellyfish_prv_appup:compare_versions(B, A).

%% ===================================================================
%% previous_version/3 - scans a release dir's `lib/<app>-*` entries and
%% picks the highest one that isn't the current version.
%% ===================================================================

previous_version_test_() ->
    {setup, fun setup_rel_dir/0, fun cleanup/1, fun previous_version_cases/1}.

setup_rel_dir() ->
    RelDir = mk_tmp_dir(),
    write_app_dir(RelDir, "myapp", "0.1.0"),
    write_app_dir(RelDir, "myapp", "0.2.0"),
    write_app_dir(RelDir, "myapp", "0.1.5"),
    write_app_dir(RelDir, "myapp", "0.2.0-rc1"),
    write_app_dir(RelDir, "myapp", "0.10.0-9cad9cd"),
    RelDir.

cleanup(RelDir) ->
    ok = file_rm_rf(RelDir).

previous_version_cases(RelDir) ->
    [
        ?_assertEqual(
            % Higher than 0.2.0 as a number, lower as text
            {"0.10.0-9cad9cd", filename:join(RelDir, "lib/myapp-0.10.0-9cad9cd")},
            rebar3_jellyfish_prv_appup:previous_version(RelDir, "myapp", "0.11.0")
        ),
        ?_assertEqual(
            % The current version itself must be excluded even though it's
            % the highest one on disk - otherwise a no-op "upgrade" from a
            % version to itself could be generated. 0.2.0 is the next one
            % down, above its own release candidate.
            {"0.2.0", filename:join(RelDir, "lib/myapp-0.2.0")},
            rebar3_jellyfish_prv_appup:previous_version(RelDir, "myapp", "0.10.0-9cad9cd")
        ),
        ?_assertEqual(
            none,
            rebar3_jellyfish_prv_appup:previous_version(RelDir, "nonexistent_app", "0.1.0")
        )
    ].

%% A .app directory left over from a failed or foreign build shouldn't take
%% down version discovery for every other, perfectly fine, directory.
malformed_dotapp_test_() ->
    {
        setup,
        fun() ->
            RelDir = mk_tmp_dir(),
            write_app_dir(RelDir, "flakyapp", "0.1.0"),
            write_malformed_app_dir(RelDir, "flakyapp", "0.1.5"),
            RelDir
        end,
        fun cleanup/1,
        fun(RelDir) ->
            [
                ?_assertEqual(
                    {"0.1.0", filename:join(RelDir, "lib/flakyapp-0.1.0")},
                    rebar3_jellyfish_prv_appup:previous_version(RelDir, "flakyapp", "0.2.0")
                )
            ]
        end
    }.

%% ===================================================================
%% Helpers
%% ===================================================================

write_app_dir(RelDir, App, Vsn) ->
    EbinDir = filename:join([RelDir, "lib", App ++ "-" ++ Vsn, "ebin"]),
    ok = filelib:ensure_dir(filename:join(EbinDir, "x")),
    Contents = io_lib:format(
        "{application, ~s, [{vsn, \"~s\"}, {modules, []}, {applications, []}, {description, \"\"}]}.~n",
        [App, Vsn]
    ),
    ok = file:write_file(filename:join(EbinDir, App ++ ".app"), Contents).

write_malformed_app_dir(RelDir, App, Vsn) ->
    EbinDir = filename:join([RelDir, "lib", App ++ "-" ++ Vsn, "ebin"]),
    ok = filelib:ensure_dir(filename:join(EbinDir, "x")),
    % Parses fine as Erlang terms, but isn't the {application, Name, Props}
    % shape app_vsn/2 expects.
    ok = file:write_file(filename:join(EbinDir, App ++ ".app"), "{not_an_application_term}.\n").

mk_tmp_dir() ->
    % See the matching comment in jellyfish_appup_tests:mk_tmp_dir/0 - the
    % pid prefix is what actually makes this collision-proof across runs.
    Dir = filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "jellyfish_prv_appup_tests",
        os:getpid() ++ "-" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Dir.

file_rm_rf(Dir) ->
    case filelib:is_dir(Dir) of
        true ->
            {ok, Entries} = file:list_dir(Dir),
            lists:foreach(
                fun(Entry) ->
                    Path = filename:join(Dir, Entry),
                    case filelib:is_dir(Path) of
                        true -> file_rm_rf(Path);
                        false -> file:delete(Path)
                    end
                end,
                Entries
            ),
            file:del_dir(Dir);
        false ->
            ok
    end.
