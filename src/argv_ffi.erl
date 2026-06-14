-module(argv_ffi).
-export([get/0]).

get() ->
    Args = init:get_plain_arguments(),
    [unicode:characters_to_binary(A) || A <- Args].
