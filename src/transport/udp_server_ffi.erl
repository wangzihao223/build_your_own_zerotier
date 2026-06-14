-module(udp_server_ffi).

-export([send_to/4]).

send_to(Socket, IpAddress, {port, Port}, Payload) ->
  Address = case IpAddress of
    {ipv4_address, A, B, C, D} -> {A, B, C, D};
    {ipv6_address, A, B, C, D, E, F, G, H} -> {A, B, C, D, E, F, G, H}
  end,
  case gen_udp:send(Socket, Address, Port, Payload) of
    ok -> {ok, nil};
    {error, _} -> {error, nil}
  end.
