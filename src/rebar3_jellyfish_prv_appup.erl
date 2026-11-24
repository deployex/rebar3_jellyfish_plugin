%% `rebar3 jellyfish appup`: diffs each app's freshly-compiled beams against
%% any previous release found on disk and, for every app that changed,
%% writes a .appup file plus a jellyfish.json sidecar under
%% `rel/appups/lib/<app>-<vsn>/ebin/', mirroring a release's own `lib/'
%% layout.
%%
%% relx config can't be changed reliably at this point - by the time this
%% provider runs, relx has already parsed its own config - so getting those
%% files into the actual release relies on a static overlay rule the
%% consuming project declares once:
%%
%%     {provider_hooks, [{post, [{compile, {jellyfish, appup}}]}]}.
%%     {relx, [
%%         ...,
%%         {overlay, [{copy, "rel/appups/lib", "lib"}]}
%%     ]}.
%%
%% relx applies overlays as one of the last steps of assembling a release,
%% so this one rule carries our files into `release', `tar' and `relup'
%% alike, regardless of which one is invoked, without needing to be
%% touched again as versions change.
-module(rebar3_jellyfish_prv_appup).

-behaviour(provider).

-export([init/1, do/1, format_error/1]).

-ifdef(TEST).
-export([compare_versions/2, previous_version/3]).
-endif.

-define(PROVIDER, appup).
-define(NAMESPACE, jellyfish).
-define(DEPS, [{default, compile}]).

-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    Provider = providers:create([
        {name, ?PROVIDER},
        {namespace, ?NAMESPACE},
        {module, ?MODULE},
        {bare, true},
        {deps, ?DEPS},
        {example, "rebar3 jellyfish appup"},
        {opts, []},
        {short_desc, "Generate appup files for the current build"},
        {desc,
            "Diffs each app's freshly-compiled beams against any previous "
            "release found on disk and, for every app that changed, writes "
            "a .appup file plus a jellyfish.json sidecar under "
            "rel/appups/lib/<app>-<vsn>/ebin/. Requires a static "
            "{overlay, [{copy, \"rel/appups/lib\", \"lib\"}]} rule in the "
            "project's relx config to actually reach the release - see the "
            "module doc."}
    ]),
    {ok, rebar_state:add_provider(State, Provider)}.

-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, {module(), term()}}.
do(State) ->
    RelDir = release_dir(State),
    RootDir = rebar_dir:root_dir(State),

    % The overlay rule the consuming project declares (see the module doc)
    % always points at this directory, even on the very first build when
    % nothing below has a previous version to diff against yet - so it
    % must exist unconditionally, or relx's overlay copy step fails outright.
    ok = filelib:ensure_dir(filename:join([RootDir, "rel", "appups", "lib", "x"])),

    Apps =
        [{rebar_app_info:name(A), project, rebar_app_info:vsn(A), rebar_app_info:out_dir(A)}
            || A <- rebar_state:project_apps(State)] ++
        [{rebar_app_info:name(A), dependency, rebar_app_info:vsn(A), rebar_app_info:out_dir(A)}
            || A <- rebar_state:all_deps(State)],

    case process_apps(Apps, RelDir, RootDir) of
        ok -> {ok, State};
        {error, Reason} -> {error, {?MODULE, Reason}}
    end.

-spec format_error(term()) -> iolist().
format_error({appup_failed, App, Reason}) ->
    io_lib:format("jellyfish: failed to generate appup for ~s: ~p", [App, Reason]);
format_error(Reason) ->
    io_lib:format("jellyfish: ~p", [Reason]).

%% ===================================================================
%% Private
%% ===================================================================

%% Only used to discover previously-built versions on disk, never written
%% to: relx (not this plugin) owns copying apps into the release tree.
release_dir(State) ->
    RelxConfig = rebar_state:get(State, relx, []),
    case lists:keyfind(release, 1, RelxConfig) of
        {release, {RelName, _RelVsn}, _} ->
            RelOutDir = proplists:get_value(rel_out_dir, RelxConfig, "rel"),
            BaseDir = rebar_dir:base_dir(State),
            filename:join([BaseDir, RelOutDir, atom_to_list(RelName)]);
        false ->
            %% No relx release is configured (e.g. a library-only project);
            %% there's nothing to diff against yet.
            undefined
    end.

process_apps(_Apps, undefined, _RootDir) ->
    ok;
process_apps([], _RelDir, _RootDir) ->
    ok;
process_apps([{NameBin, Type, Vsn, AppDir} | Rest], RelDir, RootDir) ->
    App = binary_to_atom(NameBin, utf8),
    AppStr = atom_to_list(App),

    case previous_version(RelDir, AppStr, Vsn) of
        none ->
            process_apps(Rest, RelDir, RootDir);
        {V1, V1Path} ->
            case generate(App, AppStr, Type, Vsn, AppDir, V1, V1Path, RootDir) of
                ok ->
                    process_apps(Rest, RelDir, RootDir);
                {error, Reason} ->
                    {error, {appup_failed, AppStr, Reason}}
            end
    end.

generate(App, AppStr, Type, V2, V2Path, V1, V1Path, RootDir) ->
    case jellyfish_appup:make(App, V1, V2, V1Path, V2Path) of
        {ok, Appup} ->
            EbinDir = filename:join([RootDir, "rel", "appups", "lib", AppStr ++ "-" ++ V2, "ebin"]),
            ok = filelib:ensure_dir(filename:join(EbinDir, "x")),

            AppupPath = filename:join(EbinDir, AppStr ++ ".appup"),
            ok = file:write_file(AppupPath, io_lib:format("~p.~n", [Appup])),

            JellyfishPath = filename:join(EbinDir, "jellyfish.json"),
            ok = jellyfish_json:write(JellyfishPath, App, Type, V1, V2),

            maybe_pause_for_edit(AppupPath),

            rebar_api:info("jellyfish: [~s] versions: [~s, ~s] - appup: ~s", [
                AppStr, V1, V2, AppupPath
            ]),

            ok;
        {error, _} = Err ->
            Err
    end.

maybe_pause_for_edit(AppupPath) ->
    case os:getenv("EDIT_APPUP") of
        false ->
            ok;
        _ ->
            io:format(
                "~n------------------------------------------------------------------------------~n"
            ),
            io:get_line(
                io_lib:format("Press enter when you're done editing ~s~n", [AppupPath])
            ),
            ok
    end.

%% Looks for every previously-built version of `App' under `RelDir' (a
%% release assembled by an earlier build, left on disk), and returns the
%% highest one that isn't `CurrentVsn'.
previous_version(RelDir, App, CurrentVsn) ->
    Candidates = filelib:wildcard(filename:join([RelDir, "lib", App ++ "-*"])),

    Versions =
        lists:filtermap(
            fun(Dir) ->
                case app_vsn(Dir, App) of
                    {ok, CurrentVsn} -> false;
                    {ok, Vsn} -> {true, {Vsn, Dir}};
                    {error, _} -> false
                end
            end,
            Candidates
        ),

    case lists:sort(fun({V1, _}, {V2, _}) -> compare_versions(V1, V2) end, Versions) of
        [] -> none;
        [Latest | _] -> Latest
    end.

%% A previous build left on disk could have a mangled or foreign .app file
%% (hand-edited, from an unrelated release layout, truncated by a failed
%% write, ...) - this always returns {error, _} rather than crashing the
%% whole provider over one unreadable directory, since the actual version
%% discovery this feeds into is meant to be read-only and best-effort.
app_vsn(Dir, App) ->
    DotApp = filename:join([Dir, "ebin", App ++ ".app"]),
    case file:consult(DotApp) of
        {ok, [{application, _, Props}]} when is_list(Props) ->
            case lists:keyfind(vsn, 1, Props) of
                {vsn, Vsn} -> {ok, Vsn};
                false -> {error, {no_vsn_in_dotapp, DotApp}}
            end;
        {ok, Terms} ->
            {error, {unexpected_dotapp_shape, DotApp, Terms}};
        {error, Reason} ->
            {error, Reason}
    end.

%% Highest version first, as `lists:sort/2' wants it. The order is the one
%% Jellyfish (the Elixir/Mix library) uses to pick the previous version, so
%% both tools diff against the same one:
%%
%%   * the numeric parts decide first, compared as numbers and not as text,
%%     and any number of them is accepted ("1.2" and "1.2.0" are the same);
%%   * a pre-release ("1.0.0-rc1") is lower than its release, and its
%%     identifiers compare as Semantic Versioning says: numbers as numbers
%%     and below text, a shorter list below a longer one that starts with it;
%%   * build metadata ("1.0.0+abc") is ignored;
%%   * a `git describe' version ("1.0.0-4-gabc1234") is its release plus the
%%     number of commits since, so it is higher than that release;
%%   * a version that is none of these is lower than every one that is, and
%%     compares as text with another of its kind.
%%
%% A build identifier after the version ("0.1.0-9cad9cd") is a pre-release
%% identifier, compared as text: two builds of the same version are ordered
%% by that text and not by when they were built.
compare_versions(V1, V2) ->
    version_key(V1) >= version_key(V2).

version_key(V) ->
    case re:run(V, "^([0-9]+(?:\\.[0-9]+)*)-([0-9]+)-[0-9A-Ga-g]+$", [{capture, all_but_first, list}]) of
        {match, [Base, Commits]} ->
            {1, numeric_parts(Base), {1, []}, list_to_integer(Commits)};
        nomatch ->
            parsed_version(V)
    end.

parsed_version(V) ->
    [WithoutBuild | _] = string:split(V, "+"),
    {Base, Pre} =
        case string:split(WithoutBuild, "-") of
            [B] -> {B, release};
            [B, P] -> {B, P}
        end,
    try
        {1, numeric_parts(Base), pre_release_key(Pre), 0}
    catch
        _:_ -> {0, V}
    end.

%% Trailing zeros are dropped, so "1.2" and "1.2.0" compare as equal.
numeric_parts(Base) ->
    Parts = [digits_to_integer(Part) || Part <- string:split(Base, ".", all)],
    lists:reverse(lists:dropwhile(fun(Part) -> Part =:= 0 end, lists:reverse(Parts))).

%% A release is higher than any of its pre-releases.
pre_release_key(release) ->
    {1, []};
pre_release_key(Pre) ->
    {0, [pre_release_identifier(Id) || Id <- string:split(Pre, ".", all)]}.

pre_release_identifier([]) ->
    error(empty_identifier);
pre_release_identifier(Id) ->
    case lists:all(fun is_digit/1, Id) of
        true -> {0, list_to_integer(Id)};
        false -> {1, Id}
    end.

digits_to_integer([]) ->
    error(empty_part);
digits_to_integer(Part) ->
    true = lists:all(fun is_digit/1, Part),
    list_to_integer(Part).

is_digit(C) -> C >= $0 andalso C =< $9.
