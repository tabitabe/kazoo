-module(kz_global).

-export([name/1
        ,name_pos/0
        ,pid/1
        ,zone/1
        ,server/1
        ,state/1
        ,is_local/1
        ,is_remote/1
        ,node/1
        ,is_local_node/1
        ,timestamp/1

        ,all_names/1
        ,all_globals_by_pid/2
        ,all_globals_by_node/2
        ,all_dead_pids/1

        ,from_jobj/2
        ,update_with_pid_ref/2, update_with_pid_ref/3
        ,new_global/4, new_global/5, new_global/6

        ,register_local/2
        ,register_remote/2
]).

-export_type([global/0
             ,globals/0
             ,name/0
             ]).

-include("kazoo_globals.hrl").

-record(kz_global, {node = node() :: atom() | '_'
                   ,zone :: atom() | '_'
                   ,pid :: api_pid() | '$2' | '_'
                   ,server :: any() | '_'
                   ,name :: name() | '$1' | '_'
                   ,monitor :: api_reference() | '_'
                   ,state = 'none' :: kapi_globals:state() | '_'
                   ,timestamp :: integer() | '_'
                   }).

-type global() :: #kz_global{}.
-type globals() :: [global()].

-type name() :: term().
-type names() :: [name()].

from_jobj(JObj, Zone) ->
    Node = kz_api:node(JObj),
    #kz_global{node=kz_util:to_atom(Node, 'true')
              ,zone=Zone
              ,server = kz_api:server_id(JObj)
              ,name = kapi_globals:name(JObj)
              ,state = kapi_globals:state(JObj)
              ,timestamp = kapi_globals:timestamp(JObj)
              }.

-spec new_global(name(), pid(), atom(), ne_binary()) -> global().
new_global(Name, Pid, Zone, Queue) ->
    new_global(Name, Pid, Zone, Queue, 'local').

-spec new_global(name(), pid(), atom(), ne_binary(), atom()) -> global().
new_global(Name, Pid, Zone, Queue, State) ->
    new_global(Name, Pid, Zone, Queue, State, erlang:system_time('micro_seconds')).

-spec new_global(name(), pid(), atom(), ne_binary(), atom(), integer()) -> global().
new_global(Name, Pid, Zone, Queue, State, Timestamp) ->
    #kz_global{node = node()
              ,zone = Zone
              ,server = Queue
              ,pid = Pid
              ,name = Name
              ,state=State
              ,timestamp=Timestamp
              }.

-spec update_with_pid_ref(global(), pid_ref()) -> global().
-spec update_with_pid_ref(global(), pid(), reference()) -> global().
update_with_pid_ref(Global, {Pid, Ref}) ->
    update_with_pid_ref(Global, Pid, Ref).

update_with_pid_ref(Global, Pid, Ref)
  when is_pid(Pid)
       andalso is_reference(Ref)
       ->
    Global#kz_global{monitor=Ref
                    ,pid=Pid
                    }.

-spec all_names(ets:tab()) -> names().
all_names(Table) ->
    MatchSpec = [{#kz_global{name = '$1', _ = '_'} ,[],['$1']}],
    ets:select(Table, MatchSpec).

-spec all_globals_by_pid(ets:tab(), pid()) -> globals().
all_globals_by_pid(Table, Pid) ->
    MatchSpec = [{#kz_global{pid = Pid, _ = '_'} ,[],['$_']}],
    ets:select(Table, MatchSpec).

all_dead_pids(Table) ->
    MatchSpec = [{#kz_global{pid = '$2', name = '$1', _ = '_'}
                 ,[]
                 ,[['$1', '$2']]
                 }],
    [{Name, Pid}
     || [Name, Pid] <- ets:select(Table, MatchSpec),
        erlang:is_process_alive(Pid) =:= 'false'
    ].

-spec all_globals_by_node(ets:tab(), atom()) -> globals().
all_globals_by_node(Table, Node) ->
    MatchSpec = [{#kz_global{node = Node, _ = '_'} ,[],['$_']}],
    ets:select(Table, MatchSpec).

name(#kz_global{name=Name}) ->
    Name.

name_pos() ->
    #kz_global.name.

pid(#kz_global{pid=Pid}) ->
    Pid.

zone(#kz_global{zone=Zone}) ->
    Zone.

server(#kz_global{server=Queue}) ->
    Queue.

node(#kz_global{node=Node}) ->
    Node.

timestamp(#kz_global{timestamp=Timestamp}) ->
    Timestamp.

is_local_node(#kz_global{node=Node}) ->
    Node =:= node().

state(#kz_global{state=State}) ->
    State.

is_local(#kz_global{state='local'}) -> 'true';
is_local(#kz_global{}) -> 'false'.

is_remote(#kz_global{state='remote'}) -> 'true';
is_remote(#kz_global{}) -> 'false'.

-spec register_local(ets:tab(), global()) -> global().
register_local(Table
              ,#kz_global{pid=Pid
                         ,name=Name
                         }=Global
              ) ->
    Monitor = erlang:monitor('process', Pid),
    Updates = [{#kz_global.state, 'local'}
              ,{#kz_global.monitor, Monitor}
              ],
    Local = Global#kz_global{state='local'
                    ,monitor=Monitor
                    },
    lager:debug("inserting local ~p", [Local]),
    ets:update_element(Table, Name, Updates),
    Local.

-spec register_remote(ets:tab(), global()) -> global().
register_remote(Table, Global) ->
    ProxyGlobal = start_proxy(Global),
    lager:debug("inserting proxy ~p", [ProxyGlobal]),
    ets:insert(Table, ProxyGlobal),
    ProxyGlobal.

-spec start_proxy(global()) -> global().
start_proxy(Global) ->
    {'ok', Pid} = kz_global_proxies_sup:new(Global),
    link(Pid),
    ProxyGlobal = update_with_pid_ref(Global, {Pid, monitor('process', Pid)}),
    ProxyGlobal#kz_global{state='remote'}.
