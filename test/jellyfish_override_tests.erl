-module(jellyfish_override_tests).

-include_lib("eunit/include/eunit.hrl").

%% ===================================================================
%% find/4 - the appup written by hand for one upgrade of one application
%% ===================================================================

finds_the_override_of_this_upgrade_test() ->
    with_root(fun(Root) ->
        Path = write_override(Root, "finch", "0.24.0_to_0.25.0.appup", [
            "%% Why it was written by hand.\n",
            "{\"0.25.0\",\n",
            " [{\"0.24.0\", [{stop, [finch]}, {load_module, finch}, {start, [finch]}]}],\n",
            " [{\"0.24.0\", []}]}.\n"
        ]),
        ?assertEqual({ok, Path}, jellyfish_override:find(Root, "finch", "0.24.0", "0.25.0"))
    end).

ignores_the_override_of_another_upgrade_test() ->
    with_root(fun(Root) ->
        Appup = "{\"0.25.0\", [{\"0.24.0\", []}], [{\"0.24.0\", []}]}.\n",
        write_override(Root, "finch", "0.24.0_to_0.25.0.appup", Appup),
        % No directory at all, another application, another pair of versions
        ?assertEqual(none, jellyfish_override:find(Root, "mint", "0.24.0", "0.25.0")),
        ?assertEqual(none, jellyfish_override:find(Root, "finch", "0.23.0", "0.25.0")),
        ?assertEqual(none, jellyfish_override:find(Root, "finch", "0.24.0", "0.26.0"))
    end),
    with_root(fun(Root) ->
        ?assertEqual(none, jellyfish_override:find(Root, "finch", "0.24.0", "0.25.0"))
    end).

refuses_an_appup_for_other_versions_than_its_name_test() ->
    Expected = [{to, "0.25.0"}, {upgrade_from, ["0.24.0"]}, {downgrade_to, ["0.24.0"]}],
    Cases = [
        % Another target version, another previous version
        {"{\"9.9.9\", [{\"0.24.0\", []}], [{\"0.24.0\", []}]}.\n",
            [{to, "9.9.9"}, {upgrade_from, ["0.24.0"]}, {downgrade_to, ["0.24.0"]}]},
        {"{\"0.25.0\", [{\"0.23.0\", []}], [{\"0.23.0\", []}]}.\n",
            [{to, "0.25.0"}, {upgrade_from, ["0.23.0"]}, {downgrade_to, ["0.23.0"]}]},
        % No downgrade, which the relup of a hot upgrade is also built with
        {"{\"0.25.0\", [{\"0.24.0\", []}], []}.\n",
            [{to, "0.25.0"}, {upgrade_from, ["0.24.0"]}, {downgrade_to, []}]},
        % More than one upgrade
        {"{\"0.25.0\", [{\"0.24.0\", []}, {\"0.23.0\", []}], [{\"0.24.0\", []}]}.\n",
            [{to, "0.25.0"}, {upgrade_from, ["0.24.0", "0.23.0"]}, {downgrade_to, ["0.24.0"]}]}
    ],
    with_root(fun(Root) ->
        [
            begin
                Path = write_override(Root, "finch", "0.24.0_to_0.25.0.appup", Contents),
                {error, Reason} = jellyfish_override:find(Root, "finch", "0.24.0", "0.25.0"),
                ?assertEqual(
                    {invalid_override, Path,
                        {mismatched_versions, [{expected, Expected}, {got, Got}]}},
                    Reason
                ),
                ?assertMatch(
                    {match, _},
                    re:run(jellyfish_override:format_error(Reason), "not for the versions of its name")
                )
            end
         || {Contents, Got} <- Cases
        ]
    end).

refuses_a_file_that_is_not_an_appup_test() ->
    with_root(fun(Root) ->
        Path = write_override(Root, "finch", "0.24.0_to_0.25.0.appup", "not_an_appup.\n"),
        NotAnAppup = {invalid_override, Path, not_an_appup},
        ?assertEqual({error, NotAnAppup}, jellyfish_override:find(Root, "finch", "0.24.0", "0.25.0")),
        ?assertMatch(
            {match, _},
            re:run(jellyfish_override:format_error(NotAnAppup), "does not hold one appup term")
        ),

        write_override(Root, "finch", "0.24.0_to_0.25.0.appup", "{unterminated"),
        {error, {invalid_override, Path, _} = Unreadable} =
            jellyfish_override:find(Root, "finch", "0.24.0", "0.25.0"),
        ?assertMatch({match, _}, re:run(jellyfish_override:format_error(Unreadable), "cannot be read"))
    end).

%% ===================================================================
%% Helpers
%% ===================================================================

with_root(Fun) ->
    Root = filename:join(
        filename:basedir(user_cache, "rebar3_jellyfish_plugin_tests"),
        "override-" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_dir(filename:join(Root, "x")),
    try
        Fun(Root)
    after
        file:del_dir_r(Root)
    end.

write_override(Root, App, Name, Contents) ->
    Path = filename:join([Root, "rel", "appup_overrides", App, Name]),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, Contents),
    Path.
