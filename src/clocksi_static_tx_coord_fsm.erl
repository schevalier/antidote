%% -------------------------------------------------------------------
%%
%% Copyright (c) 2014 SyncFree Consortium.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
%% @doc The coordinator for a given Clock SI static transaction.
%%      It handles the state of the tx and executes the operations sequentially
%%      by sending each operation to the responsible clockSI_vnode of the
%%      involved key. When a tx is finalized (committed or aborted), the fsm
%%      also finishes.

-module(clocksi_static_tx_coord_fsm).

-behavior(gen_fsm).

-include("antidote.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-define(DC_UTIL, mock_partition_fsm).
-define(VECTORCLOCK, mock_partition_fsm).
-define(LOG_UTIL, mock_partition_fsm).
-define(CLOCKSI_VNODE, mock_partition_fsm).
-define(CLOCKSI_DOWNSTREAM, mock_partition_fsm).
-define(LOGGING_VNODE, mock_partition_fsm).
-else.
-define(DC_UTIL, dc_utilities).
-define(VECTORCLOCK, vectorclock).
-define(LOG_UTIL, log_utilities).
-define(CLOCKSI_VNODE, clocksi_vnode).
-define(CLOCKSI_DOWNSTREAM, clocksi_downstream).
-define(LOGGING_VNODE, logging_vnode).
-endif.

%% API
-export([start_link/3,
         start_link/2,
         start_link/4,
	 start_link/5]).

%% Callbacks
-export([init/1,
	 start_tx/2,
	 generate_name/1,
	 code_change/4,
	 receive_prepared/2,
	 single_committing/2,
	 committing_single/3,
	 receive_committed/2,
	 receive_aborted/2,
	 abort/2,
	 handle_event/3,
	 handle_info/3,
         handle_sync_event/4,
	 terminate/3]).

%% States
-export([execute_batch_ops/3]).


%%%===================================================================
%%% API
%%%===================================================================

start_link(From, Clientclock, Operations, UpdateClock, StayAlive) ->
    case StayAlive of
	true ->
	    gen_fsm:start_link({local, generate_name(From)}, ?MODULE, [From, Clientclock, Operations, UpdateClock, StayAlive], []);
	false ->
	    gen_fsm:start_link(?MODULE, [From, Clientclock, Operations, UpdateClock, StayAlive], [])
    end.

start_link(From, Clientclock, Operations, UpdateClock) ->
    start_link(From, Clientclock, Operations, UpdateClock, false).

start_link(From, Clientclock, Operations) ->
    start_link(From, Clientclock, Operations, update_clock).

start_link(From, Operations) ->
    start_link(From, ignore, Operations).

%%%===================================================================
%%% States
%%%===================================================================

init([From, ClientClock, Operations, UpdateClock, StayAlive]) ->
    %lager:info("Initializing ~p",[Operations]),
    {ok, execute_batch_ops, start_tx_internal(From, ClientClock, Operations, UpdateClock, clocksi_interactive_tx_coord_fsm:init_state(StayAlive, true, true))}.

generate_name(From) ->
    list_to_atom(pid_to_list(From) ++ "static_cord").

start_tx({start_tx, From, ClientClock, Operations, UpdateClock}, SD0) ->
    %lager:info("Starting start_tx ~p",[Token]),
    {next_state, execute_batch_ops, start_tx_internal(From, ClientClock, Operations, UpdateClock, SD0)}.

start_tx_internal(From, ClientClock, Operations, UpdateClock, SD = #tx_coord_state{stay_alive = StayAlive}) ->
    %lager:info("Starting start_tx_internal ~p",[Operations]),
    {Transaction, _TransactionId} = clocksi_interactive_tx_coord_fsm:create_transaction_record(ClientClock, UpdateClock, StayAlive, From, true),
    SD#tx_coord_state{transaction=Transaction, operations=Operations}.

%% @doc Contact the leader computed in the prepare state for it to execute the
%%      operation, wait for it to finish (synchronous) and go to the prepareOP
%%       to execute the next operation.
execute_batch_ops(execute, Sender, SD=#tx_coord_state{operations = Operations,
					     transaction = Transaction}) ->
    %lager:info("In execute op ~p sender ~p",[Operations,Sender]),
    ExecuteOp = fun (Operation, Acc) ->
			case Acc of 
			    {error, Reason} ->  {error, Reason};
			    _ ->
				    case Operation of
				        {update, {Key, Type, OpParams}} ->
					        case clocksi_interactive_tx_coord_fsm:perform_update({Key,Type,OpParams},Acc#tx_coord_state.updated_partitions,Transaction,undefined) of
					            {error,Reason} ->   {error, Reason};
					            NewUpdatedPartitions ->  Acc#tx_coord_state{updated_partitions= NewUpdatedPartitions}
					        end;
				        {read, {Key, Type}} ->
                            %lager:info("Before reading"),
                            Preflist = ?LOG_UTIL:get_preflist_from_key(Key),
                            IndexNode = hd(Preflist),
                            %lager:info("Async read to ~p from ~p", [IndexNode,Preflist]),
					        ok = clocksi_vnode:async_read_data_item(IndexNode, Transaction, Key, Type),
                            NumToRead = Acc#tx_coord_state.num_to_read+1,
                            ReadSet = Acc#tx_coord_state.read_set,
                            Acc#tx_coord_state{num_to_read=NumToRead, read_set=[Key|ReadSet]}
				    end
			end
		end,    
    NewState = lists:foldl(ExecuteOp, SD, Operations),
    _Res = case NewState of 
	       {error, Reason} ->
		   %From ! {error, Reason},
		   gen_fsm:reply(Sender,{error,Reason}),
		   {stop, normal, SD};
	       _ ->
		   clocksi_interactive_tx_coord_fsm:prepare(NewState#tx_coord_state{from=Sender})
	   end.


%% @doc in this state, the fsm waits for prepare_time from each updated
%%      partitions in order to compute the final tx timestamp (the maximum
%%      of the received prepare_time).
receive_prepared({prepared, ReceivedPrepareTime},
                 S0=#tx_coord_state{num_to_ack=NumToAck,
                           num_to_read=NumToRead,
                           transaction=Transaction,
                           updated_partitions=UpdatedPartitions,
                           prepare_time=PrepareTime}) ->
    MaxPrepareTime = max(PrepareTime, ReceivedPrepareTime),
    case NumToAck of
        1 ->
            case NumToRead of
                0 ->
                    NumToCommit = length(UpdatedPartitions),
                    ok = ?CLOCKSI_VNODE:commit(UpdatedPartitions, Transaction, MaxPrepareTime),
                    {next_state, receive_committed,
                    S0#tx_coord_state{num_to_ack=NumToCommit, commit_time=MaxPrepareTime, 
                        state=committing}};
                _ ->
                    {next_state, receive_prepared, S0#tx_coord_state{num_to_ack= NumToAck-1,
                        commit_time=MaxPrepareTime, prepare_time=MaxPrepareTime}}
            end;
        _ ->
            {next_state, receive_prepared,
             S0#tx_coord_state{num_to_ack= NumToAck-1, prepare_time=MaxPrepareTime}}
    end;

receive_prepared({ok, {Key, Type, Snapshot}},
                 S0=#tx_coord_state{num_to_read=NumToRead,
                            read_set=ReadSet,
                            commit_time=CommitTime,
                            transaction=Transaction,
                            updated_partitions=UpdatedPartitions,
                            num_to_ack=NumToAck}) ->
    %%TODO: type is hard-coded..
    Value = Type:value(Snapshot),
    %lager:info("ReadSet ~p, Key ~p, Value ~p",[ReadSet,Key,Value]), 
    ReadSet1 = replace(ReadSet, Key, Value),
    case NumToRead of
        1 ->
            case NumToAck of
                0 ->
                    NumToCommit = length(UpdatedPartitions),
                    case NumToCommit of
                        0 ->
                            clocksi_interactive_tx_coord_fsm:reply_to_client(S0#tx_coord_state{state=committed_read_only, 
                            read_set=lists:reverse(ReadSet1)});
                        _ ->
                            ok = ?CLOCKSI_VNODE:commit(UpdatedPartitions, Transaction, CommitTime),
                            {next_state, receive_committed,
                               S0#tx_coord_state{num_to_ack=NumToCommit, read_set=lists:reverse(ReadSet1), state=committing}}
                    end;
                _ ->
                    {next_state, receive_prepared, S0#tx_coord_state{num_to_read= NumToRead-1,
                            read_set=ReadSet1}}
            end;
        _ ->
            {next_state, receive_prepared,
             S0#tx_coord_state{read_set=ReadSet1, num_to_read = NumToRead-1}}
    end;

receive_prepared(abort, S0) ->
    {next_state, abort, S0, 0};

receive_prepared(timeout, S0) ->
    lager:info("***TIMEOUT****"),
    {next_state, abort, S0, 0}.

single_committing({ok, {Key, Type, Snapshot}}, S0=#tx_coord_state{
                            num_to_read=NumToRead,
                            read_set=ReadSet,
                            num_to_ack=NumToAck}) ->
    %%TODO: type is hard-coded..
    Value = Type:value(Snapshot),
    ReadSet1 = replace(ReadSet, Key, Value),
    case NumToRead of
        1 ->
            case NumToAck of
                0 ->
                    clocksi_interactive_tx_coord_fsm:reply_to_client(S0#tx_coord_state{state=committed,
                    read_set=lists:reverse(ReadSet1)});
                _ ->
                    {next_state, single_committing, S0#tx_coord_state{num_to_read= NumToRead-1,
                            read_set=ReadSet1}}
            end;
        _ ->
            {next_state, single_committing,
             S0#tx_coord_state{read_set=ReadSet1, num_to_read = NumToRead-1}}
    end;

single_committing({committed, CommitTime}, S0=#tx_coord_state{from=From, full_commit=FullCommit, num_to_read=NumToRead}) ->
    case FullCommit of
	false ->
	    gen_fsm:reply(From, {ok, CommitTime}),
	    {next_state, committing_single,
	     S0#tx_coord_state{commit_time=CommitTime, state=committing}};
	true ->
        case NumToRead of
            0 ->
	            clocksi_interactive_tx_coord_fsm:reply_to_client(S0#tx_coord_state{prepare_time=CommitTime, commit_time=CommitTime, state=committed});
            _ ->
                {next_state, single_committing,
                 S0#tx_coord_state{commit_time=CommitTime, state=committing, num_to_ack=0}}
        end
    end;

single_committing(abort, S0=#tx_coord_state{from=_From}) ->
    %% {next_state, abort, S0, 0};
    clocksi_interactive_tx_coord_fsm:abort(S0);

single_committing(timeout, S0=#tx_coord_state{from=_From}) ->
    %% {next_state, abort, S0, 0}.
    clocksi_interactive_tx_coord_fsm:abort(S0).


committing_single(commit, Sender, SD0=#tx_coord_state{transaction = _Transaction,
					     commit_time=Commit_time}) ->
    clocksi_interactive_tx_coord_fsm:reply_to_client(SD0#tx_coord_state{prepare_time=Commit_time, from=Sender, commit_time=Commit_time, state=committed}).

%% @doc the fsm waits for acks indicating that each partition has successfully
%%	committed the tx and finishes operation.
%%      Should we retry sending the committed message if we don't receive a
%%      reply from every partition?
%%      What delivery guarantees does sending messages provide?
receive_committed(committed, S0=#tx_coord_state{num_to_ack= NumToAck}) ->
    case NumToAck of
        1 ->
            %lager:info("Before reply_to_client my process info ~p",[erlang:process_info(self())]),
            clocksi_interactive_tx_coord_fsm:reply_to_client(S0#tx_coord_state{state=committed});
        _ ->
           {next_state, receive_committed, S0#tx_coord_state{num_to_ack= NumToAck-1}}
    end.

abort(abort, SD0=#tx_coord_state{transaction = _Transaction,
                        updated_partitions=_UpdatedPartitions}) ->
    clocksi_interactive_tx_coord_fsm:abort(SD0);

abort({prepared, _}, SD0=#tx_coord_state{transaction=_Transaction,
                        updated_partitions=_UpdatedPartitions}) ->
    clocksi_interactive_tx_coord_fsm:abort(SD0);

abort(_, SD0=#tx_coord_state{transaction = _Transaction,
			     updated_partitions=_UpdatedPartitions}) ->
    clocksi_interactive_tx_coord_fsm:abort(SD0).

%% @doc the fsm waits for acks indicating that each partition has successfully
%%	aborted the tx and finishes operation.
%%      Should we retry sending the aborted message if we don't receive a
%%      reply from every partition?
%%      What delivery guarantees does sending messages provide?
receive_aborted(ack_abort, S0 = #tx_coord_state{num_to_ack = NumToAck}) ->
    case NumToAck of
        1 ->
            %lager:info("Before reply_to_client my process info ~p",[erlang:process_info(self())]),
            clocksi_interactive_tx_coord_fsm:reply_to_client(S0#tx_coord_state{state = aborted});
        _ ->
            {next_state, receive_aborted, S0#tx_coord_state{num_to_ack = NumToAck - 1}}
    end;

receive_aborted(_, S0) ->
    {next_state, receive_aborted, S0}.


%% =============================================================================

handle_info(_Info, _StateName, StateData) ->
    {stop, badmsg, StateData}.

handle_event(_Event, _StateName, StateData) ->
    {stop, badmsg, StateData}.

handle_sync_event(_Event, _From, _StateName, StateData) ->
    {stop, badmsg, StateData}.

code_change(_OldVsn, StateName, State, _Extra) -> {ok, StateName, State}.

terminate(_Reason, _SN, _SD) ->
    ok.

replace([], _, _) ->
    error;
replace([Key|Rest], Key, NewKey) ->
    [NewKey|Rest];
replace([NotMyKey|Rest], Key, NewKey) ->
    [NotMyKey|replace(Rest, Key, NewKey)].
    
%find([], _, _) ->
%    error;
%find([{Key, Value}|_], Key, Index) ->
%    {Key, Value, Index};
%find([_|Rest], Key, Index) ->
%    find(Rest, Key, Index+1).
