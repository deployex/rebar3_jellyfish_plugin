-module(rebar3_jellyfish_plugin).

-export([init/1]).

-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    {ok, State1} = rebar3_jellyfish_prv_appup:init(State),
    {ok, State1}.
