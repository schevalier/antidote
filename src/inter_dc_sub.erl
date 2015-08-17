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
-module(inter_dc_sub).
-behaviour(gen_server).
-include("antidote.hrl").
-include("inter_dc_repl.hrl").

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3, start_link/0, add_dc/2, del_dc/1]).
-record(state, {
  sockets :: dict() % DCID -> socket
}).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
init([]) -> {ok, #state{sockets = dict:new()}}.

add_dc(DCID, Publishers) -> gen_server:call(?MODULE, {add_dc, DCID, Publishers}).
del_dc(DCID) -> gen_server:call(?MODULE, {del_dc, DCID}).

handle_call({add_dc, DCID, Publishers}, _From, State) ->
  F = fun(Address) ->
    Socket = zmq_utils:create_connect_socket(sub, true, Address),
    lists:foreach(fun(P) ->
      ok = zmq_utils:sub_filter(Socket, inter_dc_utils:partition_to_bin(P))
    end, dc_utilities:get_my_partitions()),
    Socket
  end,
  Sockets = lists:map(F, Publishers),
  {reply, ok, State#state{sockets = dict:store(DCID, Sockets, State#state.sockets)}};

handle_call({del_dc, DCID}, _From, State) ->
  Sockets = dict:fetch(DCID, State#state.sockets),
  lists:foreach(fun zmq_utils:close_socket/1, Sockets),
  {reply, ok, State#state{sockets = dict:erase(DCID, State#state.sockets)}}.

handle_info({zmq, _Socket, BinaryMsg, _Flags}, State) ->
  Msg = inter_dc_utils:bin_to_txn(BinaryMsg),
  ok = inter_dc_sub_vnode:deliver_txn(Msg),
  {noreply, State}.

handle_cast(_Request, State) -> {noreply, State}.
code_change(_OldVsn, State, _Extra) -> {ok, State}.
terminate(_Reason, State) ->
  F = fun({_, Sockets}) -> lists:foreach(fun zmq_utils:close_socket/1, Sockets) end,
  lists:foreach(F, dict:to_list(State#state.sockets)).
