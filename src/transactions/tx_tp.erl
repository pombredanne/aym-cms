%% @copyright 2009-2011 Zuse Institute Berlin
%%            2010 onScale solutions GmbH

%   Licensed under the Apache License, Version 2.0 (the "License");
%   you may not use this file except in compliance with the License.
%   You may obtain a copy of the License at
%
%       http://www.apache.org/licenses/LICENSE-2.0
%
%   Unless required by applicable law or agreed to in writing, software
%   distributed under the License is distributed on an "AS IS" BASIS,
%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%   See the License for the specific language governing permissions and
%   limitations under the License.

%% @author Florian Schintke <schintke@onscale.de>
%% @doc Part of generic transactions implementation using Paxos Commit
%%           The role of a transaction participant.
%% @version $Id$
-module(tx_tp).
-author('schintke@onscale.de').
-vsn('$Id$').

%-define(TRACE(X,Y), io:format(X,Y)).
-define(TRACE(X,Y), ok).

%%% public interface

%%% functions for gen_component module and supervisor callbacks
-export([init/0, on_init_TP/2]).
-export([on_do_commit_abort/3, on_do_commit_abort_fwd/6]).

-spec init() -> atom().
init() ->
    InstanceID = pid_groups:my_groupname(),
    Table = list_to_atom(InstanceID ++ "_tx_tp"),
    pdb:new(Table, [set, private, named_table]).

%%
%% Attention: this is not a separate process!!
%%            It runs inside the dht_node to get access to the ?DB
%%

-spec on_init_TP({tx_state:tx_id(),
                  [comm:mypid()], [comm:mypid()], comm:mypid(),
                  tx_tlog:tlog_entry(),
                  tx_item_state:tx_item_id(),
                  tx_item_state:paxos_id()},
                  dht_node_state:state()) -> dht_node_state:state().
%% messages handled in dht_node context:
on_init_TP({Tid, RTMs, Accs, TM, RTLogEntry, ItemId, PaxId} = Params, DHT_Node_State) ->
    ?TRACE("tx_tp:on_init_TP({..., ...})~n", []),
    %% validate locally via callback
    DB = dht_node_state:get(DHT_Node_State, db),
    Key = tx_tlog:get_entry_key(RTLogEntry),
    NewDB =
        %% check only necessary in case of damaged routing
        case dht_node_state:is_db_responsible(Key, DHT_Node_State) of
            true ->
                {TmpDB, Proposal} =
                    case tx_tlog:get_entry_operation(RTLogEntry) of
                        rdht_tx_read ->
                            rdht_tx_read:validate(DB, RTLogEntry);
                        rdht_tx_write ->
                            rdht_tx_write:validate(DB, RTLogEntry)
                    end,
                %% remember own proposal for lock release
                TP_DB = dht_node_state:get(DHT_Node_State, tx_tp_db),
                pdb:set({PaxId, Proposal}, TP_DB),

                %% initiate a paxos proposer round 0 with the proposal
                Proposer = comm:make_global(dht_node_state:get(DHT_Node_State,
                                                               proposer)),
                proposer:start_paxosid(Proposer, PaxId,
                                       _Acceptors = Accs, Proposal,
                                       _Maj = 3, _MaxProposers = 5,
                                       0),
                %% send registerTP to each RTM (send with it the learner id)
                _ = [ comm:send(X, {register_TP, {Tid, ItemId, PaxId,
                                                  comm:this()}})
                      || X <- [TM | RTMs], unknown =/= X],
                %% (optimized: embed the proposer's accept message in registerTP message)
                TmpDB;
            false ->
                %% forward commit to now responsible node
                dht_node_lookup:lookup_aux(
                  DHT_Node_State, Key, 0, {init_TP, Params}),
                DB
        end,
    dht_node_state:set_db(DHT_Node_State, NewDB).

-spec on_do_commit_abort({tx_item_state:paxos_id(),
                          tx_tlog:tlog_entry(),
                          comm:mypid(),
                          tx_item_state:tx_item_id()},
                         commit | abort, dht_node_state:state())
                        -> dht_node_state:state().
on_do_commit_abort({PaxosId, RTLogEntry, TM, TMItemId} = Id, Result, DHT_Node_State) ->
    ?TRACE("tx_tp:on_do_commit_abort({, ...})~n", []),
    %% inform callback on commit/abort to release locks etc.
    % get own proposal for lock release
    TP_DB = dht_node_state:get(DHT_Node_State, tx_tp_db),
    case pdb:get(PaxosId, TP_DB) of
        {PaxosId, Proposal} ->
            NewDB = update_db_or_forward(TM, TMItemId, RTLogEntry, Result, Proposal, DHT_Node_State),
            %% delete corresponding proposer state
            Proposer = comm:make_global(dht_node_state:get(DHT_Node_State, proposer)),
            proposer:stop_paxosids(Proposer, [PaxosId]),
            pdb:delete(PaxosId, TP_DB),
            dht_node_state:set_db(DHT_Node_State, NewDB);
        undefined ->
            %% delay or forward commit until corresponding validate seen
            Key = tx_tlog:get_entry_key(RTLogEntry),
            case dht_node_state:is_db_responsible(Key, DHT_Node_State) of
                true ->
                    %% we are not in a hurry, tx is already commited and we are the slow minority
                    msg_delay:send_local(
                      1, self(), {tp_do_commit_abort, Id, Result});
                false ->
                    % we don't have an own proposal yet (no validate seen), so we forward msg as is.
                    dht_node_lookup:lookup_aux(DHT_Node_State, Key, 0,
                                               {tp_do_commit_abort, Id,
                                                Result})
            end,
            DHT_Node_State
    end.

-spec on_do_commit_abort_fwd(comm:mypid(), tx_item_state:tx_item_id(),
                             tx_tlog:tlog_entry(),
                             commit | abort, prepared | abort,
                             dht_node_state:state())
                           -> dht_node_state:state().
on_do_commit_abort_fwd(TM, TMItemId, RTLogEntry, Result, OwnProposal, DHT_Node_State) ->
    NewDB = update_db_or_forward(TM, TMItemId, RTLogEntry, Result, OwnProposal, DHT_Node_State),
    dht_node_state:set_db(DHT_Node_State, NewDB).

update_db_or_forward(TM, TMItemId, RTLogEntry, Result, OwnProposal, DHT_Node_State) ->
    %% Check for DB responsibility:
    DB = dht_node_state:get(DHT_Node_State, db),
    Key = tx_tlog:get_entry_key(RTLogEntry),
    case dht_node_state:is_db_responsible(Key, DHT_Node_State) of
        true ->
            Res =
                case {tx_tlog:get_entry_operation(RTLogEntry), Result} of
                    {rdht_tx_read, abort} ->
                        rdht_tx_read:abort(DB, RTLogEntry, OwnProposal);
                    {rdht_tx_read, commit} ->
                        rdht_tx_read:commit(DB, RTLogEntry, OwnProposal);
                    {rdht_tx_write, abort} ->
                        rdht_tx_write:abort(DB, RTLogEntry, OwnProposal);
                    {rdht_tx_write, commit} ->
                        rdht_tx_write:commit(DB, RTLogEntry, OwnProposal)
                end,
            comm:send(TM, {tp_committed, TMItemId}),
            Res;
        false ->
            %% forward commit to now responsible node
            dht_node_lookup:lookup_aux(DHT_Node_State, Key, 0,
                                       {tp_do_commit_abort_fwd,
                                        TM, TMItemId, RTLogEntry,
                                        Result, OwnProposal}),
            DB
    end.
