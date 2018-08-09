%%%-------------------------------------------------------------------
%%% @author Alex Misch <alex@alex-Lenovo>
%%% @copyright (C) 2018, Alex Misch
%%% @doc
%%% Separate server statem for the connection.
%%% @end
%%% Created :  7 Aug 2018 by Alex Misch <alex@alex-Lenovo>
%%%-------------------------------------------------------------------
-module(quic_server).

-behaviour(gen_statem).

%% See quic_conn for the API.
%% State functions.
-export([initial/3]).
-export([handshake/3]).
-export([await_finished/3]).
-export([partial_connected/3]).
-export([connected/3]).

%% gen_statem callbacks
-export([callback_mode/0, init/1, terminate/3, code_change/4]).

-include("quic_headers.hrl").


%%%===================================================================
%%% gen_statem callbacks
%%%===================================================================

-spec callback_mode() -> gen_statem:callback_mode_result().
callback_mode() -> state_functions.


-spec init([Args]) -> gen_statem:init_result(atom()) when
    Args :: Data | Options,
    Data :: #quic_data{},
    Options :: [Option],
    Option :: gen_quic:options().

init([#quic_data{
         type = server,
         conn = Conn
        } = Data0, Quic_Opts]) ->

  Params = quic_crypto:default_params(server, Quic_Opts),
  
  Recv = get_recv_state(Conn#quic_conn.owner, Quic_Opts),
  
  Data = Data0#quic_data{
           recv = Recv,
           params = Params,
           priority_num = 1,
           ready = quic_staging:new(none)
          },

  {ok, initial, Data}.


initial({call, _From}, {accept, LSocket, Timeout}, Data) ->
  %% Have control of socket.
  %% Set timeout for entire accept.
  %% Keep state, but add internal event for timeout
  %% Cast {accept, LSocket} to enter initial receive loop
  gen_statem:cast(self(), {accept, LSocket}),
  {keep_state_and_data, [{{timeout, accept}, Timeout, {error, timeout}}]};

%% This is a cast so that the state machine can cast to itself to repeat the
%% state without preventing timeouts and other messages like next_event would.
initial(cast, {accept, LSocket},
        #quic_data{
           conn = Conn0
          } = Data0) ->
  %% Poll every 100 milliseconds for a new packet.
  case prim_inet:recv(LSocket, 1, 100) of
    {error, timeout} ->
      %% Nothing received so repeat state and event.
      gen_statem:cast(self(), {accept, LSocket}),
      keep_state_and_data;
    
    {ok, {IP, Port, Packet}} ->
      %% Received a packet. Parse the header to get the initial crypto info.
      Conn = Conn0#quic_conn{
               address = IP,
               port = Port
              },
      
      case quic_crypto:parse_packet(Packet, Data0#quic_data{conn = Conn}) of
        %% TODO: Retry packets.
        %% {invalid, Data} ->
        %%   %% Send a retry packet.
        %%   {ok, Data, Packet} = quic_packet:form_packet(retry, Data),
        %%   %% Send over the new socket so the retry data is not lost.
        %%   prim_inet:sendto(Socket, IP, Port, Packet),

        %%   gen_statem:cast(self(), {accept, Socket}),
        %%   keep_state_and_data;

        {unsupported, Data} ->
          %% Need to send a version negotiation packet
          {ok, Data, Vx_Neg_Packet} = quic_packet:form_packet(vx_neg, Data),
          prim_inet:sendto(LSocket, IP, Port, Vx_Neg_Packet),
          %% Recurse and try again.
          gen_statem:cast(self(), {accept, LSocket}),
          %% Do not change the data
          keep_state_and_data;
        
        {initial, Data, Frames, TLS_Info} ->
          %% Received and was able to parse the packet.
          %% handle_initial will either fail and restart the accept or
          %% succeed and move to handshake state.
          %% {accept, LSocket} is the current event to restart.
          %% Maybe move to something like this.
          %% {keep_state, Data, 
          %%  [{next_event, internal, {handle, Frames, TLS_Info, {accept, LSocket}}}]};

          handle_initial(Data, Frames, TLS_Info, {accept, LSocket});
        
        _Other ->
          %% Could be a stray UDP packet or an invalid quic packet.
          %% Just repeat process.
          gen_statem:cast(self(), {accept, LSocket}),
          keep_state_and_data
      end;
    
    _Other ->
      %% Ignore other socket messages.
      gen_statem:cast(self(), {accept, LSocket}),
      keep_state_and_data
  end;

initial(internal, {protocol_violation, _Event},
        #quic_data{
           conn = #quic_conn{
                     owner = Owner
                    }
          }) ->
  %% TODO: Respond to client with error code.
  {stop_and_reply, {Owner, protocol_violation}};

initial({timeout, accept}, {error, timeout}, #quic_data{conn = Conn}) ->
  %% Accept timed out. Send back failure response and exit
  {stop_and_reply, {Conn#quic_conn.owner, {error, timeout}}}.


handle_initial(#quic_data{conn = Conn} = Data0, Frames, TLS_Info, Event) ->
  case quic_crypto:validate_tls(Data0, TLS_Info) of
    {invalid, _Reason} ->
      %% Depending on reason, should send hello_retry_request, but
      %% that isn't implemented yet, so just repeat waiting for a valid packet.
      gen_statem:cast(self(), Event),
      keep_state_and_data;
    
    {valid, Data1} ->
      %% Successful validation of client_hello
      Data2 = send_and_form_packet(initial, Data1),

      gen_statem:cast(self(), encrypted_exts),

      Data3 = handle_frames(Data2, Frames),

      {next_state, handshake, Data3,
       [{next_event, internal, rekey}]};
    
    {incomplete, _} ->
      %% The client_hello must fit in a single packet.
      %% TODO: Needs to respond with an error
      {keep_state_and_data, 
       [{next_event, internal, {protocol_violation, Event}}]}
  end.


handshake(internal, rekey, Data0) ->
  %% Rekey to handshake keys
  Data = quic_crypto:rekey(Data0),
  {keep_state, Data};

handshake(info, {udp, Socket, IP, Port, Raw_Packet}, 
          #quic_data{
             conn = #quic_conn{
                       socket = Socket,
                       address = IP,
                       port = Port
                      }
            } = Data0) ->
  %% Received back a packet at some point in this state.
  %% Decrypt it and see what it is.
  case quic_crypto:parse_packet(Raw_Packet, Data0) of
    {initial, Data, Frames, #tls_record{type = undefined}} ->
      %% The client's ack of our server_hello.
      %% TODO: Handling frame data.
      %% handle_frames will cancel timers for any ack frames that are in frames.
      Data1 = handle_frames(Data, Frames),
      {keep_state, Data1};
    
    {early_data, Data, Frames} ->
      %% 0-RTT early data from client
      %% Not Implemented Yet.
      Data1 = handle_frames(Data, Frames),
      {keep_state, Data1};
    
    {handshake, Data, Frames, #tls_record{type = undefined}} ->
      %% Acks for sent handshake packets.
      %% handle_frames will cancel timers for any ack frames that are in frames.
      Data1 = handle_frames(Data, Frames),
      {keep_state, Data1};
    
    _Other ->
      %% We should not be getting anything outside these three ranges.
      %% Ignore it if we do. Client cannot have all the information yet since
      %% Server is still in handshake state.
      keep_state_and_data
  end;

handshake(cast, encrypted_exts, Data0) ->
  %% Send an encrypted extensions packet.
  Data = send_and_form_packet(encrypted_exts, Data0),
  gen_statem:cast(self(), certificate),
  {keep_state, Data};

handshake(cast, certificate, Data0) ->
  %% Send the certificate packet.
  Data = send_and_form_packet(certificate, Data0),
  gen_statem:cast(self(), cert_verify),
  {keep_state, Data};

handshake(cast, cert_verify, Data0) ->
  %% Send the cert verify packet.
  Data = send_and_form_packet(cert_verify, Data0),
  gen_statem:cast(self(), finished),
  {keep_state, Data};

handshake(cast, finished, Data0) ->
  %% send the finished packet and start a window timeout.
  Data = send_and_form_packet(finished, Data0),
  
  {next_state, await_finished, Data,
   [{next_event, internal, rekey}]}.


await_finished(internal, rekey, Data0) ->
  %% rekey to application/1-RTT protected state
  Data = quic_crypto:rekey(Data0),
  %% wait for either a client finished or timeout message.
  {keep_state, Data};

await_finished(info, {timeout, Ref, {Pkt_Type, Pkt_Num} = Message},
               #quic_data{
                  window_timeout = #{rto := RTT} = Win0
                 } = Data0) when is_map_key(Ref, Win0) ->
  %% The timeout for the packet fired and data indicates it has not been deleted.
  %% Form a new one and send it again.
  %% TODO: New RTT calculations.

  Win = maps:remove(Message, Win0),

  Data = send_and_form_packet(Pkt_Type, Data0#quic_data{
                                          window_timeout = Win#{rto := RTT * 2}}),
  {keep_state, Data};

await_finished(info, {timeout, _Ref, _Message}, Data) ->
  %% Race condition clause.
  %% The packet was acknowledged, but the timer had already fired before cancelled.
  %% Ignore it.
  keep_state_and_data;

await_finished(info, {udp, Socket, IP, Port, Raw_Packet},
               #quic_data{
                  buffer = Buff,
                  conn = #quic_conn{
                            socket = Socket,
                            address = IP,
                            port = Port
                           }
                 } = Data0) ->
  %% Received a packet from the correct IP:Port combo.
  case quic_crypto:parse_packet(Raw_Packet, Data0) of
    {handshake, Data, Frames, TLS_Info} ->
      %% Potential success case.
      %% TODO: the handle ... cast event.
      {keep_state, Data, [{next_event, cast, {handle, Frames, TLS_Info}}]};
    
    {short, Data, Frames, TLS_Info} ->
      %% Still don't have the client's TLS finished so buffer it and wait again
      {keep_state, Data#quic_data{
                     buffer = Buff ++ [{short, Frames, TLS_Info}]
                    }};

    {initial, Data, Frames, TLS_Info} ->
      %% Most likely a repeat
      handle_initial(Data, Frames, TLS_Info);
    
    {early_data, Data, Frames} ->
      %% Early data, not fully implemented yet.
      %% This doesn't change state, just dispatches based on the data.
      Data1 = handle_frames(Data, Frames),
      {keep_state, Data1};
    
    Other ->
      %% Something else happened.
      %%handle_error(Data0, Other)
      keep_state_and_data %% For now.
  end;

await_finished({timeout, accept}, {error, timeout}, 
               #quic_data{
                 conn = #quic_conn{
                          owner = Owner
                          }}) ->
  {stop_and_reply, normal, {Owner, {error, timeout}}}.


handle_handshake(#quic_data{conn = Conn} = Data0, Frames, TLS_Info, Event) ->
  case quic_crypto:validate_tls(Data0, TLS_Info) of
    {invalid, _Reason} ->
      {keep_state_and_data, [{next_event, internal, {protocol_violation, Event}}]};
    
    {valid, Data1} ->
      %% Everything in the handshake state is complete so move to the partial-connected state.
      Data2 = handle_frames(Data1, Frames),
      {next_state, partial_connected, Data2, [{next_event, internal, success}]};
    
    {incomplete, Data1} ->
      %% We're still waiting on more handshake packets
      Data2 = handle_frames(Data1, Frames),
      {keep_state, Data2}
  end.

%% We made it. Now the server can send data, but first must respond to
%% owner that connection was successful and cancel accept timeout.
%% TODO: A partial-connected state to clean up the crypto stuff in Data
%%       and also handle the initial and handshake packet laggards/repeats.
partial_connected(internal, success, 
                  #quic_data{
                     conn = #quic_conn{
                               socket = Socket,
                               owner = Owner
                              }
                    }) ->
  gen_statem:reply(Owner, {ok, Socket}),
  %% Setting timeout on the timer to infinity cancels the timer.
  %% Transition to internal event to clear buffer.
  {keep_state_and_data, [{{timeout, accept}, infinity, none},
                         {next_event, internal, clear_buffer}]};

partial_connected(internal, clear_buffer, 
                  #quic_data{
                     buffer = [{short, Frames, TLS_Info} | Buffer]} = Data0) ->
  %% Need to send Frames to the right place and open streams for them.
  Data = handle_short(Data0#quic_data{buffer = Buffer}, Frames, TLS_Info),

  {keep_state, Data, [{next_event, internal, clear_buffer}]};

partial_connected(internal, clear_buffer,
                  #quic_data{buffer = []} = Data0) ->
  %% This will send a short packet of only acks for 0-RTT data, if any.
  %% TODO: Probably a good place to also send initial information like max_data
  %% if any different. Would be implemented by a setopts function like inet:setopts
  Data = send_and_form_packet(short, Data0),
  {next_state, connected, Data}.


connected(cast, {send, Frame}, Data0) ->
  %% Stage frames to be sent when ready.
  Data = quic_staging:enstage(Data0, Frame),
  {keep_state, Data};

connected(cast, {send_n_packets, N, RTO}, 
          #quic_data{window_timeout = Win} = Data0) ->
  %% Remote process will keep track of congestion control and when to send packets.
  %% This enters a destage and send loop
  %% Update the RTO timeout.
  Data = Data0#quic_data{window_timeout = Win#{rto := RTO}},

  {keep_state, Data, [{next_event, internal, {send, N}}]};

connected(internal, {send, 0}, _Data) ->
  %% Base Case of the send n loop when there are enough packets to send.
  keep_state_and_data;

connected(internal, {send, N}, 
          #quic_data{ready = Staging0} = Data0) ->
  %% Destage a list of frames from Data, if available.
  %% send and form the packet, which sets a RTO timeout.
  %% recurse on N-1
  case quic_staging:dequeue(Staging0) of
    empty ->
      %% Nothing to send so don't recurse.
      keep_state_and_data;
    
    {Staging, Frames, Size} ->
      %% Something to send.
      Data1 = Data0#quic_data{ready = Staging},
      Data2 = send_and_form_packet({short, Frames}, Data1),
      {keep_state, Data2, [{next_event, internal, {send, N-1}}]}
  end;

connected(info, {udp, Socket, IP, Port, Raw_Packet},
          #quic_data{
             conn = #quic_conn{
                       socket = Socket,
                       address = IP,
                       port = Port
                      }
            } = Data0) ->
  %% Received a packet.
  %% Decrypt and Parse it.
  case quic_crypto:parse_packet(Raw_Packet, Data0) of
    {early_data, Data1, Frames} ->
      %% Receiving a couple early_data packets is allowable.
      %% TODO: Maybe have a similar clause in partial_connected to handle
      %%       Packets sent before the client rekeys.
      Data2 = handle_frames(Data1, Frames),
      {keep_state, Data2};
    
    {handshake, Data1, Frames, TLS_Info} ->
      %% Should be a repeat packet.
      case quic_crypto:validate_tls(Data1, TLS_Info) of
        repeat ->
          %% It is a repeat packet.
          %% Data changes since the packet still needs to be acked.
          {keep_state, Data1};
        
        _Other ->
          %% If it is not a repeat, then this is an error since we already
          %% received the client's finished message.
          %% TODO: This needs better error code.
          {keep_state, Data1, 
           [{next_event, internal, {protocol_violation, connected}}]}
      end;
    
    {short, Data1, Frames, TLS_Info} ->
      case quic_crypto:validate_tls(Data1, TLS_Info) of
        no_change ->
          Data2 = handle_frames(Data1, Frames),
          {keep_state, Data1};
        
        {valid, Data2} ->
          %% Would be a key change initiated by the client.
          Data3 = handle_frames(Data2, Frames),
          {keep_state, Data2, [{next_event, internal, rekey}]};

        _Other ->
          %% TLS Protocol violation
          %% TODO: better error handling here.
          {keep_state, Data1,
           [{next_event, internal, {protocol_violation, connected}}]}
      end;
    
    _Other ->
      %% Should not receive anything else in this state.
      {keep_state_and_date, 
       [{next_event, internal, {protocol_violation, connected}}]}
  end;

connected(internal, rekey, Data0) ->
  %% update the current key.
  %% Not implemented yet.
  Data = quic_crypto:rekey(Data0),
  {keep_state, Data};

connected(internal, {protocol_violation, _Event},
         #quic_data{
            conn = #quic_conn{
                      owner = Owner
                     }
           }) ->
  %% TODO: send appropriate error to client.
  %% TODO: send better error to owner.
  {stop_and_reply, {Owner, protocol_violation}};

connected(info, {udp, _, _, _, _}, _Data) ->
  %% Received a udp message from somewhere else.
  %% Ignore it.
  keep_state_and_data;

connected({timeout, idle}, _, 
          #quic_data{
             conn = #quic_conn{
                       owner = Owner
                      }
            }) ->
  %% TODO: Idle timeout not implemented yet.
  %% Will be set in this state though.
  %% TODO: send response to client.
  {stop_and_reply, {Owner, idle_timeout}}.


send_and_form_packet(Pkt_Type,
                     #quic_data{
                        window_timeout = undefined
                        } = Data) ->
  %% Timeout window is not set yet. Set it to the default 100 milliseconds.
  %% "If no previous RTT is available, or if the network changes, the 
  %%  initial RTT SHOULD be set to 100ms."
  %% from QUIC Recovery
  send_and_form_packet(Pkt_Type, 
                       Data#quic_data{
                         window_timeout = #{rto => 100}
                        });

send_and_form_packet({short, Frames} = Pkt_Type,
                     #quic_data{
                        window_timeout = #{rto := Timeout} = Win,
                        app_pkt_num = Pkt_Num
                       } = Data0) ->

  {ok, #quic_data{
          conn = #quic_conn{
                    socket = Socket,
                    address = IP,
                    port = Port}
         } = Data1, Packet} = quic_crypto:form_packet(Pkt_Type, Data0, Frames),
  
  ok = prim_inet:sendto(Socket, IP, Port, Packet),

  %% We want to set a re-send timer to resend the packet if no ack
  %% has been received yet.
  Timer_Ref = erlang:start_timer(Timeout, self(), {Pkt_Type, Pkt_Num}),
  %% And update the window_timeout map to include it as well.
  %% This allows us to cancel the timer when an Ack is received.
  Data1#quic_data{window_timeout = Win#{{Pkt_Type, Pkt_Num} => Timer_Ref}}.

send_and_form_packet(Pkt_Type, 
                     #quic_data{
                        window_timeout = #{rtt := Timeout} = Win,
                        init_pkt_num = IPN,
                        hand_pkt_num = HPN
                       } = Data0) ->
  %% Forms the packet and sends it.
  %% Mostly just a wrapper function around these two functions.
  {ok, #quic_data{
          conn = #quic_conn{
                    socket = Socket,
                    address = IP,
                    port = Port}
         } = Data1, Packet} = quic_crypto:form_packet(Pkt_Type, Data0),
  
  ok = prim_inet:sendto(Socket, IP, Port, Packet),
  
  Pkt_Num = 
    case Pkt_Type of
      initial -> IPN;
      _Other -> HPN
    end,

  %% We want to set a re-send timer to resend the packet if no ack
  %% has been received yet.
  Timer_Ref = erlang:start_timer(Timeout, self(), {Pkt_Type, Pkt_Num}),
  %% And update the window_timeout map to include it as well.
  %% This allows us to cancel the timer when an Ack is received.
  Data1#quic_data{window_timeout = Win#{{Pkt_Type, Pkt_Num} => Timer_Ref}}.


-spec terminate(Reason :: term(), State :: term(), Data :: term()) ->
                   any().
terminate(_Reason, _State, _Data) ->
  void.


-spec code_change(
        OldVsn :: term() | {down,term()},
        State :: term(), Data :: term(), Extra :: term()) ->
                     {ok, NewState :: term(), NewData :: term()} |
                     (Reason :: term()).
code_change(_OldVsn, State, Data, _Extra) ->
  {ok, State, Data}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec get_recv_state(Owner, Options) -> Recv_State when
    Owner :: pid(),
    Options :: [Option],
    Option :: gen_quic:option(),
    Recv_State :: {active, Owner} |
                  {active, Owner, N} |
                  {[Packet], [Packet]},
    N :: non_neg_integer(),
    Packet :: binary() | list().

get_recv_state(Owner, Options) ->

  case inet_quic_util:get_opt(Options, active) of
    false ->
      %% Not defined in options.
      %% The default will be active.
      {active, Owner};
    
    {acive, true} ->
      {active, Owner};
    
    {active, false} ->
      %% Packets are stored in a makeshift queue.
      %% { InOrder list, Reversed List }
      {[], []};
    
    {active, once} ->
      %% Change once to an integer.
      {active, Owner, 1};
    
    {active, N} ->
      {active, Owner, N}
  end.


%% handle_recv either queues parsed data and returns 
%% {List, List} or sends the packet to the owner and 
%% returns an updated recv state.
%% TODO: Add support for binary() -> list() here.
%% Also need to add initialization option for it in get_recv_state/2
-spec handle_recv(Recv_State, Data, Socket) -> Recv_State when
    Recv_State :: {[Data], [Data]} |
                  {active, Owner} |
                  {active, Owner, non_neg_integer()},
    Data :: binary() | #quic_stream{},
    Socket :: gen_quic:socket(),
    Owner :: pid().

handle_recv(Recv, <<>>, _Socket) ->
  %% This clause is to make logic of handling 0-RTT data more smooth.
  %% Obviously if there is no data to handle, there's nothing to do.
  Recv;

handle_recv({[], []}, Data, _Socket) ->
  {[Data], []};

handle_recv({[], Items}, Data, _Socket) ->
  {lists:reverse([Data | Items]), []};

handle_recv({Next, Rest}, Data, _Socket) ->
  {Next, [Data | Rest]};

handle_recv({active, Owner}, Data, Socket) ->
  Owner ! {quic, Socket, Data},
  {active, Owner};

handle_recv({active, Owner, N}, Data, Socket) when N > 1 ->
  Owner ! {quic, Socket, Data},
  {active, Owner, N-1};

handle_recv({active, Owner, 1}, Data, Socket) ->
  Owner ! {quic, Socket, Data},
  Owner ! {quic_passive, Socket},
  {[], []}.
