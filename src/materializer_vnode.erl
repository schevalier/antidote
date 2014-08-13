-module(materializer_vnode).

-behaviour(riak_core_vnode).

-include("floppy.hrl").
-include_lib("riak_core/include/riak_core_vnode.hrl").

-export([start_vnode/1,
         read/3,
         update/2]).

-export([init/1,
         terminate/2,
         handle_command/3,
         is_empty/1,
         delete/1,
         handle_handoff_command/3,
         handoff_starting/2,
         handoff_cancelled/1,
         handoff_finished/2,
         handle_handoff_data/2,
         encode_handoff_item/2,
         handle_coverage/4,
         handle_exit/3]).

-record(state, {partition, cache}).

start_vnode(I) ->
    riak_core_vnode_master:get_vnode_pid(I, ?MODULE).

%% @doc Read state of key at given snapshot time
-spec read(key(), type(), vectorclock:vectorclock()) -> {ok, term()} | {error, atom()}.
read(Key, Type, SnapshotTime) ->
    DocIdx = riak_core_util:chash_key({?BUCKET, term_to_binary(Key)}),
    Preflist = riak_core_apl:get_primary_apl(DocIdx, 1, materializer),
    [{NewPref,_}] = Preflist,
    riak_core_vnode_master:sync_command(NewPref,
                                        {read, Key, Type, SnapshotTime},
                                        materializer_vnode_master).

%%@doc write downstream operation to persistant log and cache it for future read
-spec update(key(), #clocksi_payload{}) -> ok | {error, atom()}.
update(Key, DownstreamOp) ->
    DocIdx = riak_core_util:chash_key({?BUCKET, term_to_binary(Key)}),
    Preflist = riak_core_apl:get_primary_apl(DocIdx, 1, materializer),
    [{NewPref,_}] = Preflist,
    riak_core_vnode_master:sync_command(NewPref, {update, Key, DownstreamOp},
                                        materializer_vnode_master).

init([Partition]) ->
    Cache = ets:new(cache, [bag]),
    {ok, #state{partition=Partition, cache=Cache}}.

handle_command({read, Key, Type, SnapshotTime}, _Sender,
               State = #state{cache=Cache}) ->
    Operations = ets:lookup(Cache, Key),
    lager:info("operations: ~p", [Operations]),
    ListOfOps = filter_ops(Operations),
    lager:info("filter operations: ~p", [Operations]),
    {ok, Snapshot} = clocksi_materializer:get_snapshot(Type, SnapshotTime, ListOfOps),
    lager:info("snapshot: ~p", [Snapshot]),
    {reply, {ok, Snapshot}, State};

handle_command({update, Key, DownstreamOp}, _Sender,
               State = #state{cache = Cache})->
    %% TODO: Remove unnecessary information from op_payload in log_Record
    LogRecord = #log_record{tx_id=DownstreamOp#clocksi_payload.txid,
                            op_type=downstreamop,
                            op_payload=DownstreamOp},
    case floppy_rep_vnode:append(
           Key, DownstreamOp#clocksi_payload.type, LogRecord) of
        {ok, _} ->
            true = ets:insert(Cache, {Key, DownstreamOp}),
            {reply, ok, State};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_command(_Message, _Sender, State) ->
    {noreply, State}.

handle_handoff_command( _Message , _Sender, State) ->
    {noreply, State}.

handoff_starting(_TargetNode, State) ->
    {true, State}.

handoff_cancelled(State) ->
    {ok, State}.

handoff_finished(_TargetNode, State) ->
    {ok, State}.

handle_handoff_data(_Data, State) ->
    {reply, ok, State}.

encode_handoff_item(Key, Operation) ->
    term_to_binary({Key, Operation}).

is_empty(State) ->
    {true, State}.

delete(State) ->
    {ok, State}.

handle_coverage(_Req, _KeySpaces, _Sender, State) ->
    {stop, not_implemented, State}.

handle_exit(_Pid, _Reason, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

filter_ops(Ops) ->
    %% TODO: Filter out only downstream update operations from log
    [Op || { _Key, Op} <- Ops].
