-module(helper_launcher_ffi).
-export([resolve_dev_helper_path/0]).

-define(DEFAULT_HELPER_PATH, "native/tap_helper.py").

resolve_dev_helper_path() ->
    Candidates = [
        os:getenv("ZEROTIER_TAP_HELPER"),
        ?DEFAULT_HELPER_PATH
    ],
    case first_existing_path(Candidates) of
        {ok, Path} ->
            {ok, unicode:characters_to_binary(Path)};
        error ->
            {error, <<"helper_not_found">>}
    end.

first_existing_path([false | Rest]) ->
    first_existing_path(Rest);
first_existing_path(["" | Rest]) ->
    first_existing_path(Rest);
first_existing_path([Path | Rest]) when is_list(Path) ->
    case filelib:is_file(Path) of
        true -> {ok, Path};
        false -> first_existing_path(Rest)
    end;
first_existing_path([Path | Rest]) when is_binary(Path) ->
    first_existing_path([binary_to_list(Path) | Rest]);
first_existing_path([]) ->
    error.
