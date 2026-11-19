%% Generates a .appup term for one OTP application, by diffing its compiled
%% beams between two versions.
%%
%% This is a native-Erlang port of the same algorithm used by the Jellyfish
%% Elixir/Mix library (https://github.com/deployex/jellyfish), itself adapted
%% from Distillery. Both tools produce appups the same way so a reader (such
%% as DeployEx) never has to know whether a release came from `mix` or
%% `rebar3`.
-module(jellyfish_appup).

-export([make/5]).

-type app() :: atom().
-type version() :: string().
-type path() :: file:filename().
-type instruction() :: term().
-type appup() :: {version(), [{version(), [instruction()]}], [{version(), [instruction()]}]}.

-export_type([appup/0]).

%% @doc Builds a `{Vsn, UpFrom, DownTo}' appup term for `App', upgrading from
%% `V1' (found at `V1Path') to `V2' (found at `V2Path'). `V1Path'/`V2Path' are
%% each an application root directory, i.e. the parent of its `ebin'.
-spec make(app(), version(), version(), path(), path()) ->
    {ok, appup()} | {error, term()}.
make(App, V1, V2, V1Path, V2Path) ->
    case consult_dotapp(App, V1Path) of
        {ok, V1Props} ->
            case check_vsn(previous, vsn(V1Props), V1) of
                ok -> make_with_v2(App, V1, V1Path, V2, V2Path);
                Err -> Err
            end;
        Err ->
            Err
    end.

make_with_v2(App, V1, V1Path, V2, V2Path) ->
    case consult_dotapp(App, V2Path) of
        {ok, V2Props} ->
            case check_vsn(next, vsn(V2Props), V2) of
                ok -> {ok, make_appup(V1, V1Path, V2, V2Path)};
                Err -> Err
            end;
        Err ->
            Err
    end.

%% ===================================================================
%% Private
%% ===================================================================

consult_dotapp(App, Path) ->
    Dotapp = filename:join([Path, "ebin", atom_to_list(App) ++ ".app"]),
    case file:consult(Dotapp) of
        {ok, [{application, App, Props}]} -> {ok, Props};
        {error, Reason} -> {error, {appups, file, {invalid_dotapp, Reason}}}
    end.

check_vsn(_Which, Vsn, Vsn) ->
    ok;
check_vsn(Which, ConsultedVsn, ExpectedVsn) ->
    {error,
        {appups,
            {mismatched_versions, [{version, Which}, {expected, ExpectedVsn}, {got, ConsultedVsn}]}}}.

vsn(Props) ->
    {value, {vsn, Vsn}} = lists:keysearch(vsn, 1, Props),
    Vsn.

make_appup(V1, V1Path, V2, V2Path) ->
    V1Ebin = filename:join(V1Path, "ebin"),
    V2Ebin = filename:join(V2Path, "ebin"),

    {Deleted, Added, Changed} = beam_lib:cmp_dirs(V1Ebin, V2Ebin),

    % Some compilers (e.g. Elixir's) always show a changed Dbgi chunk even
    % when nothing meaningful changed, since it embeds compiler-run-specific
    % state. Filtering that out here keeps appups free of no-op instructions
    % regardless of which compiler produced the beam.
    ActuallyChanged = lists:filter(fun is_real_change/1, Changed),

    UpInstructions =
        generate_instructions(added, Added) ++
            generate_instructions(changed, ActuallyChanged) ++
            generate_instructions(deleted, Deleted),

    DownInstructions =
        generate_instructions(deleted, Added) ++
            generate_instructions(changed, ActuallyChanged) ++
            generate_instructions(added, Deleted),

    {V2, [{V1, UpInstructions}], [{V1, DownInstructions}]}.

is_real_change({V1Beam, V2Beam}) ->
    case beam_lib:cmp(V1Beam, V2Beam) of
        {error, beam_lib, {chunks_different, "Dbgi"}} -> false;
        _ -> true
    end.

generate_instructions(changed, Files) ->
    topological_sort([generate_instruction(changed, F) || F <- Files]);
generate_instructions(Type, Files) ->
    [generate_instruction(Type, F) || F <- Files].

generate_instruction(added, File) ->
    {add_module, module_name(File)};
generate_instruction(deleted, File) ->
    {delete_module, module_name(File)};
generate_instruction(changed, {V1File, V2File}) ->
    ModuleName = module_name(V1File),
    Attributes = beam_attributes(V1File),
    Exports = beam_exports(V1File),
    Imports = beam_imports(V2File),
    IsSupervisor = is_supervisor(Attributes),
    IsSpecialProcess = is_special_process(Exports),
    DependsOn = depended_modules(Imports),
    generate_instruction_advanced(ModuleName, IsSupervisor, IsSpecialProcess, DependsOn).

depended_modules(Imports) ->
    lists:reverse(
        lists:foldl(
            fun({Module, _F, _A}, Acc) ->
                case lists:member(Module, Acc) of
                    true -> Acc;
                    false -> [Module | Acc]
                end
            end,
            [],
            Imports
        )
    ).

beam_attributes(File) ->
    {ok, {_, [{attributes, Attributes}]}} = beam_lib:chunks(File, [attributes]),
    Attributes.

beam_exports(File) ->
    {ok, {_, [{exports, Exports}]}} = beam_lib:chunks(File, [exports]),
    Exports.

beam_imports(File) ->
    {ok, {_, [{imports, Imports}]}} = beam_lib:chunks(File, [imports]),
    Imports.

is_special_process(Exports) ->
    lists:member({system_code_change, 4}, Exports) orelse
        lists:member({code_change, 3}, Exports) orelse
        lists:member({code_change, 4}, Exports).

is_supervisor(Attributes) ->
    Behaviours =
        proplists:get_value(behavior, Attributes, []) ++
            proplists:get_value(behaviour, Attributes, []),
    lists:member(supervisor, Behaviours).

% supervisor
generate_instruction_advanced(M, true, _IsSpecial, _DepMods) ->
    {update, M, supervisor};
% special process (i.e. exports code_change/3 or system_code_change/4)
generate_instruction_advanced(M, false, true, []) ->
    {update, M, {advanced, []}};
generate_instruction_advanced(M, false, true, DepMods) ->
    {update, M, {advanced, []}, DepMods};
% non-special process (i.e. neither code_change/3 nor system_code_change/4 are exported)
generate_instruction_advanced(M, false, false, []) ->
    {load_module, M};
generate_instruction_advanced(M, false, false, DepMods) ->
    {load_module, M, DepMods}.

module_name(File) ->
    {module, M} = lists:keyfind(module, 1, beam_lib:info(File)),
    M.

% This "topological" sort is not truly topological, since module dependencies
% are represented as a directed, cyclic graph, and it is not actually
% possible to sort such a graph due to the cycles which occur. However, one
% can "break" loops, until one reaches a point that the graph becomes
% acyclic, and those topologically sortable. That's effectively what happens
% here: we perform the sort, breaking loops where they exist by attempting to
% weight each of the two dependencies based on the number of outgoing
% dependencies they have, where the fewer number of outgoing dependencies
% always comes first.
topological_sort(Instructions) ->
    Mods = [element(2, I) || I <- Instructions],
    Sorted = lists:sort(fun(A, B) -> do_sort_instructions(Mods, A, B) end, Instructions),
    [finalize_instruction(I, Mods) || I <- Sorted].

finalize_instruction({update, _M, _T} = I, _Mods) ->
    I;
finalize_instruction({load_module, _M} = I, _Mods) ->
    I;
finalize_instruction({update, M, T, Deps}, Mods) ->
    {update, M, T, filter_known_deps(Deps, M, Mods)};
finalize_instruction({load_module, M, Deps}, Mods) ->
    {load_module, M, filter_known_deps(Deps, M, Mods)}.

filter_known_deps(Deps, SelfMod, Mods) ->
    [D || D <- Deps, D =/= SelfMod, lists:member(D, Mods)].

do_sort_instructions(Mods, A, B) ->
    Am = element(2, A),
    Bm = element(2, B),
    Ad = filter_known_deps(extract_deps(A), Am, Mods),
    Bd = filter_known_deps(extract_deps(B), Bm, Mods),
    compare_dependency_counts(Am, Bm, Ad, Bd).

compare_dependency_counts(Am, Bm, Ad, Bd) ->
    Lad = length(Ad),
    Lbd = length(Bd),
    case {only_a_has_deps(Lad, Lbd), only_b_has_deps(Lad, Lbd)} of
        {true, _} ->
            true;
        {_, true} ->
            false;
        _ ->
            % If a depends on b and b doesn't depend on a, then b comes
            % first, and vice versa. Otherwise, if either they don't depend
            % on each other, or they both depend on each other, the module
            % with the least outgoing dependencies comes first.
            case {a_depends_on_b_only(Am, Bm, Ad, Bd), b_depends_on_a_only(Am, Bm, Ad, Bd)} of
                {true, _} -> true;
                {_, true} -> false;
                _ when Lad > Lbd -> false;
                _ when Lbd > Lad -> true;
                _ -> true
            end
    end.

only_a_has_deps(0, Lbd) -> Lbd =/= 0;
only_a_has_deps(_Lad, _Lbd) -> false.

only_b_has_deps(Lad, 0) -> Lad =/= 0;
only_b_has_deps(_Lad, _Lbd) -> false.

a_depends_on_b_only(Am, Bm, Ad, Bd) ->
    lists:member(Am, Bd) andalso not lists:member(Bm, Ad).

b_depends_on_a_only(Am, Bm, Ad, Bd) ->
    not lists:member(Am, Bd) andalso lists:member(Bm, Ad).

extract_deps({update, _M, Deps}) when is_list(Deps) -> Deps;
extract_deps({update, _M, _Change}) -> [];
extract_deps({update, _M, _Change, Deps}) -> Deps;
extract_deps({update, _M, _Change, _PrePurge, _PostPurge, Deps}) -> Deps;
extract_deps({load_module, _M, Deps}) -> Deps;
extract_deps({load_module, _M, _PrePurge, _PostPurge, Deps}) -> Deps;
extract_deps({delete_module, _M, Deps}) -> Deps;
extract_deps({add_module, _M, Deps}) -> Deps;
extract_deps(_) -> [].
