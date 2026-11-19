%% Writes the jellyfish.json sidecar file that accompanies every generated
%% .appup. Its presence is the actual signal a reader (such as DeployEx)
%% should trust, since a dependency can ship its own unrelated .appup file.
%%
%% The field set is the same one Jellyfish (the Elixir/Mix library) writes,
%% so a reader never has to know whether a release came from `mix` or
%% `rebar3`. See https://github.com/deployex/jellyfish#the-jellyfishjson-file.
-module(jellyfish_json).

-export([write/5]).

-define(FORMAT_VERSION, 1).

-type app_type() :: project | dependency.

-spec write(file:filename(), atom(), app_type(), string(), string()) -> ok | {error, term()}.
write(Path, App, Type, V1, V2) ->
    Contents = io_lib:format(
        "{~n"
        "  \"name\": \"~s\",~n"
        "  \"type\": \"~s\",~n"
        "  \"from\": \"~s\",~n"
        "  \"to\": \"~s\",~n"
        "  \"format_version\": ~b,~n"
        "  \"generator\": \"rebar3_jellyfish_plugin/~s\"~n"
        "}~n",
        [App, Type, V1, V2, ?FORMAT_VERSION, generator_version()]
    ),
    file:write_file(Path, Contents).

generator_version() ->
    {ok, Vsn} = application:get_key(rebar3_jellyfish_plugin, vsn),
    Vsn.
