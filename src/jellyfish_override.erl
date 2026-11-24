%% An appup written by hand, that the release uses in place of the generated
%% one.
%%
%% The plugin writes an appup from what changed in the compiled modules. It
%% cannot see what a release changes around them: a process that exists in
%% one version and not in the other, a supervisor whose children changed, a
%% different shape of the data that processes share. An upgrade like that
%% needs other instructions, and somebody has to write them.
%%
%% An override is where they go. It is a file in the repository, reviewed as
%% code is:
%%
%%     rel/appup_overrides/<application>/<from>_to_<to>.appup
%%
%% When the release is built for exactly that upgrade of that application,
%% the file is used as it is, comments included, and nothing is generated
%% for it. Any other upgrade ignores it, so an override can stay in the
%% repository after it has served. The path and the name are the ones
%% Jellyfish (the Elixir/Mix library) uses.
%%
%% The file holds one appup term, with one upgrade and one downgrade, both
%% for the previous version its name says. A file that is not that fails the
%% build: a release that silently fell back to the generated appup would be
%% the one the override was written to avoid.
-module(jellyfish_override).

-export([find/4, format_error/1]).

-type reason() ::
    {invalid_override, file:filename(),
        {mismatched_versions, [{expected | got, [{atom(), term()}]}]}
        | not_an_appup
        | term()}.

-export_type([reason/0]).

%% Looks under `RootDir' for the override of the upgrade of `App' from `V1'
%% to `V2'. Returns its path when there is one and it holds an appup for
%% those versions, `none' when there is no file, and an error when the file
%% is not usable.
-spec find(file:filename(), string(), string(), string()) ->
    {ok, file:filename()} | none | {error, reason()}.
find(RootDir, App, V1, V2) ->
    Path = filename:join([RootDir, "rel", "appup_overrides", App, V1 ++ "_to_" ++ V2 ++ ".appup"]),
    case filelib:is_regular(Path) of
        true -> validate(Path, V1, V2);
        false -> none
    end.

-spec format_error(reason()) -> iolist().
format_error({invalid_override, Path, {mismatched_versions, [{expected, Expected}, {got, Got}]}}) ->
    io_lib:format(
        "the override ~s is not for the versions of its name, expected: ~p, got: ~p",
        [Path, Expected, Got]
    );
format_error({invalid_override, Path, not_an_appup}) ->
    io_lib:format("the override ~s does not hold one appup term", [Path]);
format_error({invalid_override, Path, Reason}) ->
    io_lib:format("the override ~s cannot be read: ~s", [Path, file:format_error(Reason)]).

%% ===================================================================
%% Private
%% ===================================================================

validate(Path, V1, V2) ->
    case file:consult(Path) of
        {ok, [{V2, [{V1, Up}], [{V1, Down}]}]} when is_list(Up), is_list(Down) ->
            {ok, Path};
        {ok, [{To, Up, Down}]} when is_list(Up), is_list(Down) ->
            Expected = [{to, V2}, {upgrade_from, [V1]}, {downgrade_to, [V1]}],
            Got = [{to, To}, {upgrade_from, versions(Up)}, {downgrade_to, versions(Down)}],
            {error, {invalid_override, Path, {mismatched_versions, [{expected, Expected}, {got, Got}]}}};
        {ok, _Terms} ->
            {error, {invalid_override, Path, not_an_appup}};
        {error, Reason} ->
            {error, {invalid_override, Path, Reason}}
    end.

versions(Entries) ->
    [
        case Entry of
            {Version, _Instructions} -> Version;
            Other -> Other
        end
     || Entry <- Entries
    ].
