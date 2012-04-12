%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @doc OpenFlow Logical Switch logic.
%%% @end
%%%-----------------------------------------------------------------------------
-module(ofs_logic).

-behaviour(gen_server).

%% API
-export([
         start_link/2,
         message/2,
         send/1,
         register_receiver/2,
         unregister_receiver/1,
         get_connection/1
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("of_switch.hrl").
-include_lib("of_protocol/include/of_protocol.hrl").

-record(state, {
          connections = [] :: [#connection{}],
          generation_id :: integer(),
          backend_mod :: atom(),
          backend_state :: term()
         }).

%%%-----------------------------------------------------------------------------
%%% API functions
%%%-----------------------------------------------------------------------------

%% @doc Start the OF Switch logic.
-spec start_link(atom(), term()) -> {ok, pid()} | {error, any()}.
start_link(BackendMod, BackendOpts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE,
                          [BackendMod, BackendOpts], []).

%% @doc Deliver message to the OF Switch logic.
-spec message(ofp_message(), pid()) -> any().
message(Message, From) ->
    gen_server:cast(?MODULE, {message, From, Message}).

%% @doc Send message out to controllers.
-spec send(ofp_message()) -> any().
send(Message) ->
    gen_server:cast(?MODULE, {send, Message}).

%% @doc Register receiver.
-spec register_receiver(pid(), port()) -> any().
register_receiver(Pid, Socket) ->
    gen_server:cast(?MODULE, {register, Pid, Socket}).

%% @doc Unregister receiver.
-spec unregister_receiver(pid()) -> any().
unregister_receiver(Pid) ->
    gen_server:cast(?MODULE, {unregister, Pid}).

%% @doc Get connection information.
-spec get_connection(pid()) -> any().
get_connection(Pid) ->
    gen_server:call(?MODULE, {get_connection, Pid}).

%%%-----------------------------------------------------------------------------
%%% gen_server callbacks
%%%-----------------------------------------------------------------------------

init([BackendMod, BackendOpts]) ->
    {ok, Controllers} = application:get_env(of_switch, controllers),
    [ofs_receiver_sup:open(Host, Port) || {Host, Port} <- Controllers],
    {ok, BackendState} = BackendMod:start(BackendOpts),
    {ok, #state{backend_mod = BackendMod,
                backend_state = BackendState}}.

handle_call({get_connection, Pid}, _From,
            #state{connections = Connections} = State) ->
    Connection = lists:keyfind(Pid, #connection.pid, Connections),
    {reply, Connection, State}.

handle_cast({register, Pid, Socket},
            #state{connections = Connections} = State) ->
    Connection = #connection{pid = Pid, socket = Socket},
    {noreply, State#state{connections = [Connection | Connections]}};
handle_cast({unregister, Pid}, #state{connections = Connections} = State) ->
    NewConnections = lists:keydelete(Pid, #connection.pid, Connections),
    {noreply, State#state{connections = NewConnections}};
handle_cast({message, From, Message},
            #state{connections = Connections} = State) ->
    Connection = lists:keyfind(From, #connection.pid, Connections),
    ?INFO("Received message from controller (~p): ~p~n", [Connection, Message]),
    NewState = handle_message(Message, Connection, State),
    {noreply, NewState};
handle_cast({send, Message}, #state{connections = Connections} = State) ->
    Target = if
                 (is_record(Message, port_status))
                 orelse (is_record(Message, error_msg)) ->
                     Connections;
                 (is_record(Message, packet_in))
                 orelse (is_record(Message, flow_removed)) ->
                     lists:filter(fun(#connection{role = slave}) ->
                                          false;
                                     (#connection{role = _}) ->
                                          true
                                  end, Connections);
                 true ->
                     []
             end,
    [do_send(Socket, Message) || #connection{socket = Socket} <- Target],
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{backend_mod = BackendMod,
                          backend_state = BackendState}) ->
    BackendMod:stop(BackendState).

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%%%-----------------------------------------------------------------------------
%%% Message handling functions
%%%-----------------------------------------------------------------------------

%% @doc Handle different kind of messages.
-spec handle_message(ofp_message(), connection(),
                     #state{}) -> #state{}.
handle_message(#hello{header = #ofp_header{version = ReceivedVersion} = Header},
               #connection{pid = Pid, socket = Socket,
                           version = undefined} = Connection,
               #state{connections = Connections} = State) ->
    %% Wait for hello and decide on version if it's undefined.
    case decide_on_version(ReceivedVersion) of
        {ok, Version} ->
            NewConnection = Connection#connection{version = Version},
            NewConnections = lists:keyreplace(Pid, #connection.pid, Connections,
                                              NewConnection),
            State#state{connections = NewConnections};
        error ->
            send_error_reply(Socket, Header, #error_msg{type = hello_failed,
                                                        code = incompatible}),
            State
    end;
handle_message(_Message, #connection{version = undefined}, State) ->
    %% If version is undefined drop all the other messages.
    State;
handle_message(#hello{}, _, State) ->
    %% Drop hello messages once version is known.
    State;
handle_message(#error_msg{type = hello_failed},
               #connection{pid = Pid}, State) ->
    %% Disconnect when hello_failed was received.
    ofs_receiver:stop(Pid),
    State;
handle_message(#features_request{header = Header},
               #connection{socket = Socket},
               State) ->
    FeaturesReply = #features_reply{header = Header,
                                    datapath_mac = <<0:48>>,
                                    datapath_id = 0,
                                    n_buffers = 0,
                                    n_tables = 255},
    do_send(Socket, FeaturesReply),
    State;
handle_message(#set_config{}, _, State) ->
    %% TODO: persist incoming configuration
    State;
handle_message(#get_config_request{header = Header},
               #connection{socket = Socket},
               State) ->
    ConfigReply = #get_config_reply{header = Header,
                                    flags = [],
                                    miss_send_len = ?OFPCML_NO_BUFFER},
    do_send(Socket, ConfigReply),
    State;
handle_message(ModRequest,
               #connection{socket = Socket, role = slave},
               State) when is_record(ModRequest, flow_mod);
                           is_record(ModRequest, group_mod);
                           is_record(ModRequest, port_mod);
                           is_record(ModRequest, table_mod) ->
    %% Don't allow slave controllers to modify flows, groups, ports and tables.
    Header = get_header(ModRequest),
    send_error_reply(Socket, Header, #error_msg{type = bad_request,
                                                code = is_slave}),
    State;
handle_message(#port_mod{} = PortMod, Connection, State) ->
    handle_in_backend(modify_port, PortMod, Connection, State);
handle_message(#table_mod{} = TableMod, Connection, State) ->
    handle_in_backend(modify_table, TableMod, Connection, State);
handle_message(#role_request{} = RoleRequest,
               #connection{socket = Socket} = Connection,
               #state{} = State) ->
    {Reply, NewState} = handle_role(RoleRequest, Connection, State),
    do_send(Socket, Reply),
    NewState;
handle_message(#echo_request{} = Request, Connection, State) ->
    handle_in_backend(echo_request, Request, Connection, State);
handle_message(#flow_mod{command = Command, buffer_id = BufferId} = FlowMod,
               Connection, State) ->
    NewState = handle_in_backend(modify_flow, FlowMod, Connection, State),
    case should_do_flow_mod_packet_out(Command, BufferId) of
        true ->
            ok; %% TODO: emulate packet_out
        false ->
            do_nothing
    end,
    NewState;
handle_message(#packet_out{} = PacketOut, Connection, State) ->
    handle_in_backend(packet_out, PacketOut, Connection, State);
handle_message(_, _, State) ->
    %% Drop everything else.
    State.

%%%-----------------------------------------------------------------------------
%%% Helper functions
%%%-----------------------------------------------------------------------------

-spec decide_on_version(integer()) -> {ok, integer()} | error.
decide_on_version(ReceivedVersion) ->
    {ok, SupportedVersions} = application:get_env(of_switch, supported_versions),
    ProposedVersion = lists:max(SupportedVersions),
    if
        ProposedVersion > ReceivedVersion ->
            case lists:member(ReceivedVersion, SupportedVersions) of
                true ->
                    {ok, ReceivedVersion};
                false ->
                    error
            end;
        true ->
            {ok, ProposedVersion}
    end.

-spec handle_role(role_request(), connection(), #state{}) ->
                         {ofp_message(), #state{}}.
handle_role(#role_request{header = Header, role = Role,
                          generation_id = GenerationId},
            #connection{pid = Pid} = Connection,
            #state{connections = Connections,
                   generation_id = CurrentGenId} = State) ->
    case Role of
        equal ->
            NewConns = lists:keyreplace(Pid, #connection.pid, Connections,
                                        Connection#connection{role = equal}),
            RoleReply = #role_reply{header = Header,
                                    role = Role,
                                    generation_id = GenerationId},
            {RoleReply, State#state{connections = NewConns}};
        _ ->
            if
                (CurrentGenId /= undefined)
                andalso (GenerationId - CurrentGenId < 0) ->
                    ErrorReply = #error_msg{header = Header,
                                            type = role_request_failed,
                                            code = stale},
                    {ErrorReply, State};
                true ->
                    NewConn = Connection#connection{role = Role},
                    NewConns = lists:keyreplace(Pid, #connection.pid,
                                                Connections, NewConn),
                    case Role of
                        master ->
                            Fun = fun(Conn = #connection{role = R}) ->
                                          case R of
                                              master ->
                                                  Conn#connection{role = slave};
                                              _ ->
                                                  Conn
                                          end
                                  end,
                            NewConns2 = lists:map(Fun, NewConns);
                        slave ->
                            NewConns2 = NewConns
                    end,
                    NewState = State#state{connections = NewConns2,
                                           generation_id = GenerationId},
                    RoleReply = #role_reply{header = Header,
                                            role = Role,
                                            generation_id = GenerationId},
                    {RoleReply, NewState}
            end
    end.

should_do_flow_mod_packet_out(delete, _) ->
    false;
should_do_flow_mod_packet_out(delete_strict, _) ->
    false;
should_do_flow_mod_packet_out(_, no_buffer) ->
    false;
should_do_flow_mod_packet_out(_, _) ->
    true.

-spec handle_in_backend(atom(), record(), #connection{}, #state{}) -> #state{}.
handle_in_backend(BackendFun, Request, #connection{socket = Socket},
                  #state{backend_mod = BackendMod,
                         backend_state = BackendState} = State) ->
    case BackendMod:BackendFun(BackendState, Request) of
        {ok, NewBackendState} ->
            ok;
        {ok, Reply, NewBackendState} ->
            do_send(Socket, Reply);
        {error, Message, NewBackendState} ->
            Header = get_header(Request),
            send_error_reply(Socket, Header, Message)
    end,
    State#state{backend_state = NewBackendState}.

-spec get_header(record()) -> #ofp_header{}.
get_header(Packet) ->
    element(2, Packet).

-spec do_send(port(), ofp_message()) -> any().
do_send(Socket, Message) ->
    {ok, EncodedMessage} = of_protocol:encode(Message),
    gen_tcp:send(Socket, EncodedMessage).

send_error_reply(Socket, Header, Message) ->
    do_send(Socket, Message#error_msg{header = Header}).
