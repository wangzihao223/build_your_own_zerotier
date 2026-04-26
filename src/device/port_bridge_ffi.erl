-module(port_bridge_ffi).
-export([start/2, send_frame/2, receive_message/2, stop/1]).

start(Command, Args) when is_binary(Command), is_list(Args) ->
    CommandString = binary_to_list(Command),
    case os:find_executable(CommandString) of
        false ->
            {error, <<"command_not_found">>};
        Executable ->
            PortSettings = [
                binary,
                use_stdio,
                hide,
                exit_status,
                {packet, 4},
                {args, [binary_to_list(Arg) || Arg <- Args]}
            ],
            try
                {ok, open_port({spawn_executable, Executable}, PortSettings)}
            catch
                Class:Reason ->
                    Message = io_lib:format("~p:~p", [Class, Reason]),
                    {error, unicode:characters_to_binary(Message)}
            end
    end.

send_frame(Port, Frame) ->
    true = port_command(Port, Frame),
    nil.

receive_message(Port, TimeoutMs) ->
    receive
        {Port, {data, Frame}} ->
            {frame, Frame};
        {Port, {exit_status, Code}} ->
            {exit_status, Code};
        _Other ->
            unknown
    after TimeoutMs ->
        timeout
    end.

stop(Port) ->
    true = port_close(Port),
    nil.
