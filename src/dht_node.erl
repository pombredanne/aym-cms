%  @copyright 2007-2010 Konrad-Zuse-Zentrum fuer Informationstechnik Berlin

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

%%% @author Thorsten Schuett <schuett@zib.de>
%%% @doc    dht_node main file
%%% @end
%% @version $Id$
-module(dht_node).
-author('schuett@zib.de').
-vsn('$Id$ ').

-include("transstore/trecords.hrl").
-include("../include/scalaris.hrl").

-behaviour(gen_component).

-export([start_link/1, start_link/2]).

-export([on/2, init/1]).

% state of the dht_node loop
-type(state() :: any()).

% accepted messages of dht_node processes
-type(message() :: any()).

%% @doc message handler
-spec(on/2 :: (message(), state()) -> state()).


% Join Messages

% join protocol

% first node
on({get_key_response_keyholder, Key}, {join_as_first}) ->
    log:log(info,"[ Node ~w ] joining as first: ~p",[self(), Key]),
    State = dht_node_join:join_first(Key),
    cs_send:send_local(get_local_dht_node_reregister_pid(),{go}),
    %log:log(info,"[ Node ~w ] joined",[self()]),
    State;  % join complete, State is the first "State"

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% !first node
% 1. get my key
on({get_key_response_keyholder, Key}, {join_phase1}) ->
    %io:format("p1: got key~n"),
    log:log(info,"[ Node ~w ] joining",[self()]),
    % send message to avoid code duplication
    cs_send:send_local(self(), {known_hosts_timeout}),
    {join_phase2, Key};

% 2. Find known hosts
on({known_hosts_timeout}, {join_phase2, Key}) ->
    %io:format("p2: known hosts timeout~n"),
    KnownHosts = config:read(known_hosts),
    % contact all known VMs
    _Res = [cs_send:send(KnownHost, {get_dht_nodes, cs_send:this()})
           || KnownHost <- KnownHosts],
    %io:format("~p~n", [Res]),
    % timeout just in case
    cs_send:send_local_after(1000, self() , {known_hosts_timeout}),
    {join_phase2, Key};

on({get_dht_nodes_response, []}, {join_phase2, Key}) ->
    %io:format("p2: got empty dht_nodes_response~n"),
    % there is a VM with no nodes
    {join_phase2, Key};

on({get_dht_nodes_response, Nodes}, {join_phase2, Key}) ->
    %io:format("p2: got dht_nodes_response ~p~n", [lists:delete(cs_send:this(), Nodes)]),
    case lists:delete(cs_send:this(), Nodes) of
        [] ->
            {join_phase2, Key};
        [First | Rest] ->
            cs_send:send(First, {lookup_aux, Key, 0, {get_node, cs_send:this(), Key}}),
            cs_send:send_local_after(3000, self(), {lookup_timeout}),
            {join_phase3, Rest, Key}
    end;

% 3. lookup my position
on({lookup_timeout}, {join_phase3, [], Key}) ->
    %io:format("p3: lookup_timeout~n"),
    % no more nodes left, go back to step 2
    cs_send:send_local(self(), {known_hosts_timeout}),
    {join_phase2, Key};

on({get_node_response, Key, Succ}, {join_phase3, _, Key}) ->
    %io:format("p3: lookup success~n"),
    % got my successor
    Me = node:new(cs_send:this(), Key),
    % announce join request
    cs_send:send(node:pidX(Succ), {join, cs_send:this(), Key}),
    {join_phase4, Key, Succ, Me};

% 4. joining my neighbors
on({join_response, Pred, Data}, {join_phase4, Id, Succ, Me}) ->
    %io:format("p4: join_response~n"),
    % @TODO data shouldn't be moved here, might be large
    log:log(info, "[ Node ~w ] got pred ~w",[self(), Pred]),
    DB = ?DB:add_data(?DB:new(Id), Data),
    rt_beh:initialize(Id, Pred, Succ),
    State = case node:is_null(Pred) of
                true ->
                    dht_node_state:new(?RT:empty(Succ), Succ, Pred, Me,
                                 {Id, Id}, dht_node_lb:new(), DB);
                false ->
                    cs_send:send(node:pidX(Pred), {update_succ, Me}),
                    dht_node_state:new(?RT:empty(Succ), Succ, Pred, Me,
                                 {node:id(Pred), Id}, dht_node_lb:new(), DB)
            end,
    cs_replica_stabilization:recreate_replicas(dht_node_state:get_my_range(State)),
    cs_send:send_local(get_local_dht_node_reregister_pid(), {go}),
    State;

% Catch all messages until the join protocol is finshed
on(Msg, State) when element(1, State) /= state ->
    %log:log(info("[csnode] [~p] postponed delivery of ~p~n", [self(), Msg]),
    cs_send:send_local_after(100, self(), Msg),
    State;

%% Kill Messages
on({kill}, _State) ->
    kill;

on({churn}, _State) ->
    idholder:reinit(),
    kill;

on({halt}, _State) ->
    util:sleep_for_ever();

on({die}, _State) ->
    kill;

%% Ring Maintenance (see rm_beh.erl)
on({init_rm,Pid},State) ->
    cs_send:send_local(Pid , {init, dht_node_state:id(State), dht_node_state:me(State),dht_node_state:pred(State), [dht_node_state:succ(State)]}),
    State;

on({rm_update_preds_succs, Preds, Succs}, State) ->
    dht_node_state:set_rt(dht_node_state:update_preds_succs(State, Preds, Succs),
                    ?RT:update_pred_succ_in_dht_node(hd(Preds), hd(Succs), dht_node_state:rt(State)));

on({rm_update_preds, Preds}, State) ->
    dht_node_state:set_rt(dht_node_state:update_preds(State, Preds),
                    ?RT:update_pred_succ_in_dht_node(hd(Preds), dht_node_state:succ(State), dht_node_state:rt(State)));

on({rm_update_succs, Succs}, State) ->
    dht_node_state:set_rt(dht_node_state:update_succs(State, Succs),
                    ?RT:update_pred_succ_in_dht_node(dht_node_state:pred(State), hd(Succs), dht_node_state:rt(State)));

%% @doc notification that my successor left
on({succ_left, Succ}, State) ->
    rm_beh:succ_left(Succ),
    State;

%% @doc notification that my predecessor left
on({pred_left, Pred}, State) ->
    rm_beh:pred_left(Pred),
    State;

%% @doc notify the dht_node his successor changed
on({update_succ, Succ}, State) ->
    rm_beh:notify_new_succ(Succ),
    State;

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Finger Maintenance 
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
on({rt_update, RoutingTable}, State) ->
    dht_node_state:set_rt(State, RoutingTable);

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Transactions (see transstore/*.erl)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
on({read, SourcePID, Key}, State) ->
    transaction:quorum_read(Key, SourcePID),
    State;

on({delete, SourcePID, Key}, State) ->
    transaction:delete(SourcePID, Key),
    State;

on({parallel_reads, SourcePID, Keys, TLog}, State) ->
    transaction:parallel_quorum_reads(Keys, TLog, SourcePID),
    State;

%%  initiate a read phase
on({do_transaction, TransFun, SuccessFun, FailureFun, Owner}, State) ->
    transaction:do_transaction(State, TransFun, SuccessFun, FailureFun, Owner),
    State;

%% do a transaction without a read phase
on({do_transaction_wo_rp, Items, SuccessFunArgument, SuccessFun, FailureFun, Owner}, State) ->
    transaction:do_transaction_wo_readphase(State, Items, SuccessFunArgument, SuccessFun, FailureFun, Owner),
    State;

%% answer - lookup for transaction participant
on({lookup_tp, Message}, State) ->
    {Leader} = Message#tp_message.message,
    {RangeBeg, RangeEnd} = dht_node_state:get_my_range(State),
    Responsible = util:is_between(RangeBeg, Message#tp_message.item_key, RangeEnd),
    if
        Responsible == true ->
            cs_send:send(Leader, {tp, Message#tp_message.item_key, Message#tp_message.orig_key, cs_send:this()}),
            State;
        true ->
            log:log(info,"[ Node ] LookupTP: Got Request for Key ~p, it is not between ~p and ~p ~n", [Message#tp_message.item_key, RangeBeg, RangeEnd]),
            State
    end;

        %% answer - lookup for replicated transaction manager
on({init_rtm, Message}, State) ->
    transaction:initRTM(State, Message);

%% a validation request for a node acting as a transaction participant
on({validate, TransID, Item}, State) ->
    tparticipant:tp_validate(State, TransID, Item);

%% this message contains the final decision for a certain transaction
on({decision, Message}, State) ->
    {_, TransID, Decision} = Message#tp_message.message,
    if
        Decision == commit ->
            tparticipant:tp_commit(State, TransID);
        true ->
            tparticipant:tp_abort(State, TransID)
    end;

%% remove tm->tid mapping after transaction manager stopped
on({remove_tm_tid_mapping, TransID, _TMPid}, State) ->
    {translog, TID_TM_Mapping, Decided, Undecided} = dht_node_state:get_trans_log(State),
    NewTID_TM_Mapping = dict:erase(TransID, TID_TM_Mapping),
    dht_node_state:set_trans_log(State, {translog, NewTID_TM_Mapping, Decided, Undecided});

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Ring Maintenance (rm_chord)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
on({get_pred, Source_Pid}, State) ->
    cs_send:send(Source_Pid, {get_pred_response, dht_node_state:pred(State)}),
    State;

on({get_succ_list, Source_Pid}, State) ->
    rm_chord:get_successorlist(Source_Pid),
    State;

on({get_successorlist_response, SuccList,Source_Pid}, State) ->
    cs_send:send(Source_Pid, {get_succ_list_response, dht_node_state:me(State),SuccList}),
    State;


on({notify, Pred}, State) -> 
    rm_chord:notify(Pred),
    State;

%% Finger Maintenance
on({lookup_pointer, Source_Pid, Index}, State) ->
    RT = process_dictionary:get_group_member(routing_table),
    cs_send:send_local(RT, {lookup_pointer, Source_Pid, Index}),
    State;

%% userdevguide-begin dht_node:rt_get_node
on({rt_get_node, Source_PID, Index}, State) ->
    cs_send:send(Source_PID, {rt_get_node_response, Index, dht_node_state:me(State)}),
    State;
%% userdevguide-end dht_node:rt_get_node

%% Lookup (see lookup.erl)
on({lookup_aux, Key, Hops, Msg}, State) ->
    dht_node_lookup:lookup_aux(State, Key, Hops, Msg),
    State;

on({lookup_fin, Hops, Msg}, State) ->
    cs_send:send_local(self(), Msg),
    State;

on({get_node, Source_PID, Key}, State) ->
    cs_send:send(Source_PID, {get_node_response, Key, dht_node_state:me(State)}),
    State;

on({get_process_in_group, Source_PID, Key, Process}, State) ->
    Pid = process_dictionary:get_group_member(Process),
    GPid = cs_send:make_global(Pid),
    cs_send:send(Source_PID, {get_process_in_group_reply, Key, GPid}),
    State;

on({get_rtm, Source_PID, Key, Process}, State) ->
    InstanceId = erlang:get(instance_id),
    Pid = process_dictionary:get_group_member(Process),
    SupTx = process_dictionary:get_group_member(sup_dht_node_core_tx),
    NewPid = case Pid of
                 failed ->
                     %% start, if necessary
                     RTM_desc = util:sup_worker_desc(
                                  Process, tx_tm_rtm, start_link,
                                  [InstanceId, Process]),
                     case supervisor:start_child(SupTx, RTM_desc) of
                         {ok, TmpPid} -> TmpPid;
                         {ok, TmpPid, _} -> TmpPid;
                         {error, _} -> Pid
                     end;
                 _ -> Pid
             end,
    GPid = cs_send:make_global(NewPid),
    cs_send:send(Source_PID, {get_rtm_reply, Key, GPid}),
    State;

%% Cyclon (see cyclon/*.erl)
on({get_cyclon_pid, Pid,Me}, State) ->
    CyclonPid = cs_send:make_global(get_local_cyclon_pid()),
    cs_send:send(Pid,{cyclon_pid, Me, CyclonPid}),
    State;

%% database
on({get_key, Source_PID, Key}, State) ->
    {RangeBeg, RangeEnd} = dht_node_state:get_my_range(State),
    case util:is_between(RangeBeg, Key, RangeEnd) of
        true ->
            dht_node_lookup:get_key(State, Source_PID, Key, Key),
            State;
        false ->
            log:log(info,"[ Node ] Get_Key: Got Request for Key ~p, it is not between ~p and ~p", [Key, RangeBeg, RangeEnd]),
            State
    end;

on({get_key, Source_PID, SourceId, HashedKey}, State) ->
%      case 0 =:= randoms:rand_uniform(0,6) of
%          true ->
%              io:format("drop get_key request~n");
%          false ->
    cs_send:send(Source_PID,
                 {get_key_with_id_reply, SourceId, HashedKey,
                  ?DB:read(dht_node_state:get_db(State), HashedKey)}),
%    end,
    State;

on({set_key, Source_PID, Key, Value, Versionnr}, State) ->
    {RangeBeg, RangeEnd} = dht_node_state:get_my_range(State),
    case util:is_between(RangeBeg, Key, RangeEnd) of
        true ->
            dht_node_lookup:set_key(State, Source_PID, Key, Value, Versionnr);
        false ->
            log:log(info,"[ Node ] Set_Key: Got Request for Key ~p, it is not between ~p and ~p ", [Key, RangeBeg, RangeEnd]),
            State
    end;

on({delete_key, Source_PID, Key}, State) ->
    {RangeBeg, RangeEnd} = dht_node_state:get_my_range(State),
    case util:is_between(RangeBeg, Key, RangeEnd) of
        true ->
            dht_node_lookup:delete_key(State, Source_PID, Key);
        false ->
            log:log(info,"[ Node ] delete_key: Got Request for Key ~p, it is not between ~p and ~p ", [Key, RangeBeg, RangeEnd]),
            State
    end;

on({drop_data, Data, Sender}, State) ->
    cs_send:send(Sender, {drop_data_ack}),
    DB = ?DB:add_data(dht_node_state:get_db(State), Data),
    dht_node_state:set_db(State, DB);


% bulk owner messages (see bulkowner.erl)
on({bulk_owner, I, Msg}, State) ->
    bulkowner:bulk_owner(State, I, Msg),
    State;

on({start_bulk_owner, I, Msg}, State) ->
    bulkowner:start_bulk_owner(I, Msg),
    State;

on({bulkowner_deliver, Range, {bulk_read_with_version, Issuer}}, State) ->
    cs_send:send(Issuer, {bulk_read_with_version_response, dht_node_state:get_my_range(State),
                          ?DB:get_range_with_version(dht_node_state:get_db(State), Range)}),
    State;

% load balancing messages (see dht_node_lb.erl)
on({get_load, Source_PID}, State) ->
    cs_send:send(Source_PID, {get_load_response, cs_send:this(), dht_node_state:load(State)}),
    State;

on({get_load_response, Source_PID, Load}, State) ->
    dht_node_lb:check_balance(State, Source_PID, Load),
    State;

on({get_middle_key, Source_PID}, State) ->
    {MiddleKey, NewState} = dht_node_lb:get_middle_key(State),
    cs_send:send(Source_PID, {get_middle_key_response, cs_send:this(), MiddleKey}),
    NewState;

on({get_middle_key_response, Source_PID, MiddleKey}, State) ->
    dht_node_lb:move_load(State, Source_PID, MiddleKey);

on({reset_loadbalance_flag}, State) ->
    dht_node_lb:reset_loadbalance_flag(State);

on({stabilize_loadbalance}, State) ->
    dht_node_lb:balance_load(State),
    State;

%% misc.
on({get_node_details, Pid}, State) ->
    cs_send:send(Pid, {get_node_details_response, dht_node_state:details(State)}),
    State;
on({get_node_details, Pid, Which}, State) ->
    cs_send:send(Pid, {get_node_details_response, dht_node_state:details(State, Which)}),
    State;

on({dump}, State) ->
    dht_node_state:dump(State),
    State;

on({'$gen_cast', {debug_info, Requestor}}, State) ->
    cs_send:send_local(Requestor , {debug_info_response, [{"rt_size", ?RT:get_size(dht_node_state:rt(State))}]}),
    State;


%% unit_tests
on({bulkowner_deliver, Range, {unit_test_bulkowner, Owner}}, State) ->
    Res = lists:map(fun ({Key, {Value, _, _, _}}) ->
                            {Key, Value}
                    end,
                    lists:filter(fun ({Key, _}) ->
                                         intervals:in(Key, Range)
                                 end, ?DB:get_data(dht_node_state:get_db(State)))),
    cs_send:send_local(Owner , {unit_test_bulkowner_response, Res, dht_node_state:id(State)}),
    State;

%% @TODO buggy ...
%on({get_node_response, _, _}, State) ->
%    State;

%% join messages (see dht_node_join.erl)
%% userdevguide-begin dht_node:join_message
on({join, Source_PID, Id}, State) ->
    dht_node_join:join_request(State, Source_PID, Id);
%% userdevguide-end dht_node:join_message

on({get_dht_nodes_response, _KnownHosts}, State) ->
    % will ignore these messages after join
    State;

on({known_hosts_timeout}, State) ->
    % will ignore these messages after join
    State;

on({lookup_timeout}, State) ->
    % will ignore these messages after join
    State;

%% messages handled as a transaction participant (TP)
on({init_TP, Params}, State) ->
    tx_tp:on_init_TP(Params, State);
on({tx_tm_rtm_commit_reply, Id, Result}, State) ->
    tx_tp:on_tx_commitreply(Id, Result, State);

on(_, _State) ->
    unknown_event.

%% userdevguide-begin dht_node:start
%% @doc joins this node in the ring and calls the main loop
-spec(init/1 :: ([any()]) -> {join_as_first, join_phase1}).
init([_InstanceId, Options]) ->
    %io:format("~p~n", [Options]),
    % first node in this vm and also vm is marked as first
    % or unit-test
    case lists:member(first, Options) andalso
          (is_unittest() orelse
          application:get_env(boot_cs, first) == {ok, true}) of
        true ->
            trigger_known_nodes(),
            idholder:get_key(),
            {join_as_first};
        _ ->
            idholder:get_key(),
            {join_phase1}
    end.
%% userdevguide-end dht_node:start

%% userdevguide-begin dht_node:start_link
%% @doc spawns a scalaris node, called by the scalaris supervisor process
%% @spec start_link(term()) -> {ok, pid()}
start_link(InstanceId) ->
    start_link(InstanceId, []).

start_link(InstanceId, Options) ->
    gen_component:start_link(?MODULE, [InstanceId, Options],
                             [{register, InstanceId, dht_node}]).
%% userdevguide-end dht_node:start_link

get_local_cyclon_pid() ->
    process_dictionary:get_group_member(cyclon).

get_local_dht_node_reregister_pid() ->
    process_dictionary:get_group_member(dht_node_reregister).

% @doc find existing nodes and initialize the comm_layer
trigger_known_nodes() ->
    KnownHosts = config:read(known_hosts),
    % note, cs_send:this() may be invalid at this moment
    [cs_send:send(KnownHost, {get_dht_nodes, cs_send:this()})
     || KnownHost <- KnownHosts],
    timer:sleep(100),
    case cs_send:is_valid(cs_send:this()) of
        true ->
            ok;
        false ->
            trigger_known_nodes()
    end.

% @doc try to check whether common-test is running
is_unittest() ->
    code:is_loaded(ct) =/= false andalso code:is_loaded(ct_framework) =/= false andalso
    lists:member(ct_logs, registered()).
