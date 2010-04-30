%  @copyright 2009-2010 Konrad-Zuse-Zentrum fuer Informationstechnik Berlin

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

%%% @author Christian Hennig <hennig@zib.de>
%%% @doc    T-Man ring maintenance
%%% @end
%% @version $Id$
-module(rm_tmansharp).
-author('hennig@zib.de').
-vsn('$Id$ ').

-include("scalaris.hrl").

-export([init/1, on/2]).

-behavior(rm_beh).
-behavior(gen_component).

-export([start_link/1, check_config/0]).

% unit testing
-export([merge/2, rank/2, get_pred/1, get_succ/1, get_preds/1, get_succs/1]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Startup
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% @doc spawns a chord-like ring maintenance process
-spec start_link(instanceid()) -> {ok, pid()}.
start_link(InstanceId) ->
    start_link(InstanceId, []).

-spec start_link(instanceid(), [any()]) -> {ok, pid()}.
start_link(InstanceId, Options) ->
   gen_component:start_link(?MODULE, [InstanceId, Options], [{register, InstanceId, ring_maintenance}]).

-spec init([instanceid() | [any()]]) -> any().
init(_Args) ->
    log:log(info,"[ RM ~p ] starting ring maintainer TMAN~n", [self()]),
    dn_cache:subscribe(),
     cs_send:send_local(get_cs_pid(), {init_rm,self()}),
    uninit.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Internal Loop
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
on({init, NewId, NewMe, NewPred, NewSuccList, _DHTNode},uninit) ->
        rm_beh:update_preds_and_succs([NewPred], NewSuccList),
        fd:subscribe(lists:usort([node:pidX(Node) || Node <- [NewPred | NewSuccList]])),
        Token = 0,
        cs_send:send_local_after(0, self(), {stabilize,Token}),
        {NewId, NewMe, [NewPred]++NewSuccList,config:read(cyclon_cache_size),stabilizationInterval_min(),Token,NewPred,hd(NewSuccList),[]};
on(_,uninit) ->
        uninit;

% @doc the Token takes care, that there is only one timermessage for stabilize 
on({get_succlist, Pid},
   {_Id, Me, [], _RandViewSize, _Interval, _AktToken, _AktPred, _AktSucc, _RandomCache} = State) ->
    cs_send:send_local(Pid, {get_succlist_response,[Me]}),
    State;

on({get_predlist, Pid},
   {_Id, Me, [], _RandViewSize, _Interval, _AktToken, _AktPred, _AktSucc, _RandomCache} = State) ->
    cs_send:send_local(Pid, {get_predlist_response, [Me]}),
    State;

on({get_succlist, Pid},
   {_Id, _Me, View, _RandViewSize, _Interval, _AktToken, _AktPred, _AktSucc, _RandomCache} = State) ->
    cs_send:send_local(Pid, {get_succlist_response, get_succs(View)}),
    State;

on({get_predlist, Pid},
   {_Id, _Me, View, _RandViewSize, _Interval, _AktToken, _AktPred, _AktSucc, _RandomCache} = State) ->
    cs_send:send_local(Pid, {get_predlist_response, get_preds(View)}),
    State;

on({stabilize, AktToken},
   {_Id, Me, View, RandViewSize, Interval, AktToken, _AktPred, _AktSucc, RandomCache} = State) -> % new stabilization interval
    % Triger an update of the Random view
    cyclon:get_subset_rand(RandViewSize),
    RndView = get_RndView(RandViewSize,RandomCache),
    %log:log(debug, " [RM | ~p ] RNDVIEW: ~p", [self(),RndView]),
    P = selectPeer(rank(View++RndView,node:id(Me)),Me),
    %io:format("~p~n",[{Preds,Succs,RndView,Me}]),
    %Test for being alone
    case (P == Me) of
        true ->
            rm_beh:update_preds([Me]),
            rm_beh:update_succs([Me]);
        false ->
            cs_send:send_to_group_member(node:pidX(P), ring_maintenance, {rm_buffer,Me,extractMessage(View++[Me]++RndView,P)})
    end,
    cs_send:send_local_after(Interval, self(), {stabilize,AktToken}),
    State;

on({stabilize,_}, State) ->
    State;

on({cy_cache, NewCache},
   {Id, Me, View, RandViewSize, Interval, AktToken, AktPred, AktSucc, _RandomCache}) ->
    {Id, Me, View, RandViewSize, Interval, AktToken, AktPred, AktSucc, NewCache};

on({rm_buffer, Q, Buffer_q},
   {Id, Me, View, RandViewSize, Interval, AktToken, AktPred, AktSucc, RandomCache}) ->
    RndView = get_RndView(RandViewSize,RandomCache),
    cs_send:send_to_group_member(node:pidX(Q),ring_maintenance,{rm_buffer_response,extractMessage(View++[Me]++RndView,Q)}),
    %io:format("after_send~p~n",[self()]),
    NewView = rank(View++Buffer_q++RndView,node:id(Me)),
    %io:format("after_rank~p~n",[self()]),
    %SuccsNew=get_succs(NewView),
    %PredsNew=get_preds(NewView),
    {NewAktPred,NewAktSucc} = update_dht_node(NewView,AktPred,AktSucc),
    update_failuredetector(View,NewView),
    NewInterval = new_interval(View,NewView,Interval),
    cs_send:send_local_after(NewInterval , self(), {stabilize,AktToken+1}),
    %io:format("loop~p~n",[self()]),
    {Id, Me, NewView, RandViewSize, NewInterval, AktToken+1, NewAktPred, NewAktSucc, RandomCache};

on({rm_buffer_response, Buffer_p},
   {Id, Me, View ,RandViewSize,Interval,AktToken,AktPred,AktSucc,RandomCache})->
    RndView = get_RndView(RandViewSize,RandomCache),
    %log:log(debug, " [RM | ~p ] RNDVIEW: ~p", [self(),RndView]),
    Buffer = rank(View++Buffer_p++RndView,node:id(Me)),
    %io:format("after_rank~p~n",[self()]),
    NewView = lists:sublist(Buffer,config:read(succ_list_length)+config:read(pred_list_length)),
    {NewAktPred,NewAktSucc} = update_dht_node(View,AktPred,AktSucc),
    update_failuredetector(View,NewView),
    NewInterval = new_interval(View,NewView,Interval),
    %inc RandViewSize (no error detected)
    RandViewSizeNew = case RandViewSize < config:read(cyclon_cache_size) of
                          true  -> RandViewSize+1;
                          false -> RandViewSize
                      end,
    cs_send:send_local_after(NewInterval , self(), {stabilize,AktToken+1}),
    {Id, Me, NewView, RandViewSizeNew, NewInterval, AktToken+1, NewAktPred, NewAktSucc, RandomCache};

on({zombie, Node},
   {Id, Me, View, RandViewSize, Interval, AktToken, AktPred, AktSucc, RandomCache}) ->
    erlang:send(self(), {stabilize, AktToken+1}),
    %TODO: Inform Cyclon !!!!
    {Id, Me, View, RandViewSize, Interval, AktToken+1, AktPred, AktSucc, [Node|RandomCache]};

on({crash, DeadPid},
   {Id, Me, View, _RandViewSize, _Interval, AktToken, AktPred, AktSucc, RandomCache}) ->
    NewView = filter(DeadPid, View),
    NewCache = filter(DeadPid, RandomCache),
    update_failuredetector(View,NewView),
    erlang:send(self(), {stabilize, AktToken+1}),
    {Id, Me, NewView, 0, stabilizationInterval_min(), AktToken+1, AktPred, AktSucc, NewCache};

on({'$gen_cast', {debug_info, Requestor}},
   {_Id, _Me, View, _RandViewSize, _Interval, _AktToken, _AktPred, _AktSucc, _RandomCache} = State) ->
    cs_send:send_local(Requestor,
                       {debug_info_response, [{"pred", lists:flatten(io_lib:format("~p", [get_preds(View)]))},
                                              {"succs", lists:flatten(io_lib:format("~p", [get_succs(View)]))}]}),
    State;

on({check_ring, 0, Me},
   {_Id, Me, _View, _RandViewSize, _Interval, _AktToken, _AktPred, _AktSucc, _RandomCache} = State) ->
    io:format(" [RM ] CheckRing   OK  ~n"),
    State;

on({check_ring, Token, Me},
   {_Id, Me, _View, _RandViewSize, _Interval, _AktToken, _AktPred, _AktSucc, _RandomCache} = State) ->
    io:format(" [RM ] Token back with Value: ~p~n",[Token]),
    State;

on({check_ring, 0, Master},
   {_Id, Me, _View, _RandViewSize, _Interval, _AktToken, _AktPred, _AktSucc, _RandomCache} = State) ->
    io:format(" [RM ] CheckRing  reach TTL in Node ~p not in ~p~n", [Master, Me]),
    State;

on({check_ring, Token, Master},
   {_Id, _Me, _View, _RandViewSize, _Interval, _AktToken, AktPred, _AktSucc, _RandomCache} = State) ->
    cs_send:send_to_group_member(node:pidX(AktPred), ring_maintenance, {check_ring,Token-1,Master}),
    State;

on({init_check_ring, Token},
   {_Id, Me, _View, _RandViewSize, _Interval, _AktToken, AktPred, _AktSucc, _RandomCache} = State) ->
    cs_send:send_to_group_member(node:pidX(AktPred), ring_maintenance, {check_ring,Token-1,Me}),
    State;

on({notify_new_pred, _NewPred}, State) ->
    %% @TODO use the new predecessor info
    State;

on({notify_new_succ, _NewSucc}, State) ->
    %% @TODO use the new successor info
    State;

on(_, _State) ->
    unknown_event.

%% @doc Checks whether config parameters of the rm_tmansharp process exist and
%%      are valid.
-spec check_config() -> boolean().
check_config() ->
    config:is_integer(stabilization_interval_min) and
    config:is_greater_than(stabilization_interval_min, 0) and

    config:is_integer(stabilization_interval_max) and
    config:is_greater_than(stabilization_interval_max, 0) and
    config:is_greater_than_equal(stabilization_interval_max, stabilization_interval_min) and

    config:is_integer(cyclon_cache_size) and
    config:is_greater_than(cyclon_cache_size, 2) and

    config:is_integer(succ_list_length) and
    config:is_greater_than_equal(succ_list_length, 0) and

    config:is_integer(pred_list_length) and
    config:is_greater_than_equal(pred_list_length, 0).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Internal Functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% @doc merge two successor lists into one
%%      and sort by identifier
rank(MergedList,Id) ->
    %io:format("--------------------------------- ~p ~n",[Id]),
    %io:format("in: ~p ~p ~n",[self(),MergedList]),
    Order = fun(A, B) ->
            node:id(A) =< node:id(B)
            %A=<B
        end,
    Larger  = lists:usort(Order, [X || X <- MergedList, node:id(X) >  Id]),
    Equal   = lists:usort(Order, [X || X <- MergedList, node:id(X) == Id]),
    Smaller = lists:usort(Order, [X || X <- MergedList, node:id(X) <  Id]),

    H1 = Larger++Smaller,
    Half = length(H1) div 2,
    {Succs,Preds} = lists:split(Half,H1),
    Return=lists:sublist(merge(Succs,lists:reverse(Preds)),10), %config:read(succ_list_length)+config:read(pred_list_length)

    %io:format("return: ~p ~p ~n",[self(),Return]),
    A =case Return of
        []  -> Equal;
        _   -> Return
    end,
    %io:format("out: ~p ~p ~n",[self(),A]),
    A.

selectPeer([],Me) ->
    Me;
selectPeer(View,_) ->
    NTH = randoms:rand_uniform(1, 3),
    case (NTH=<length(View)) of
        true -> lists:nth( NTH,View);
        false -> lists:nth(length(View),View)
    end.

extractMessage(View,P) ->
    lists:sublist(rank(View,node:id(P)),10).

merge([H1|T1],[H2|T2]) ->
    [H1,H2]++merge(T1,T2);
merge([],[T|H]) ->
    [T|H];
merge([],X) ->
    X;
merge(X,[]) ->
    X;
merge([],[]) ->
    [].

get_succs([T]) ->
    [T];
get_succs(View) ->
    get_every_nth(View,1,0).
get_preds([T]) ->
    [T];
get_preds(View) ->
    get_every_nth(View,1,1).

get_succ([H|_]) ->
    H.

get_pred([H|T]) ->
    case T of
        []  -> H;
        _   -> get_succ(T)
    end.

get_every_nth([],_,_) ->
    [];
get_every_nth([H|T],Nth,Offset) ->
    case Offset of
        0 ->  [H|get_every_nth(T,Nth,Nth)];
        _ ->  get_every_nth(T,Nth,Offset-1)
    end.

%-spec(filter/2 :: (cs_send:mypid(), list(node:node_type()) -> list(node:node_type()).
filter(_Pid, []) ->
    [];
filter(Pid, [Succ | Rest]) ->
    case Pid == node:pidX(Succ) of
	true ->

        %Hook for DeadNodeCache
        dn_cache:add_zombie_candidate(Succ),

	    filter(Pid, Rest);
	false ->
	    [Succ | filter(Pid, Rest)]
    end.

%% @doc get a peer form the cycloncache which is alive
get_RndView(N,Cache) ->
     lists:sublist(Cache, N).

% @doc Check if change of failuredetector is necessary
update_failuredetector(OldView,NewView) ->
    case (NewView /= OldView) of
        true ->
            NewNodes = util:minus(NewView,OldView),
            OldNodes = util:minus(OldView,NewView),
            update_fd([node:pidX(Node) || Node <- OldNodes],fun fd:unsubscribe/1),
            update_fd([node:pidX(Node) || Node <- NewNodes],fun fd:subscribe/1);
        false ->
            ok
    end,
    ok.

update_fd([], _) ->
    ok;
update_fd(Nodes, F) ->
    F(Nodes).

	
% @doc informed the dht_node for new [succ|pred] if necessary
update_dht_node(View,_AktPred,_AktSucc) ->
        NewAktPred=get_pred(View),
        NewAktSucc=get_succ(View),
      	rm_beh:update_preds([NewAktPred]),
      	rm_beh:update_succs([NewAktSucc]),
{NewAktPred,NewAktSucc}.

% @doc adapt the Tman-interval
new_interval(View,NewView,Interval) ->
    case (View==NewView) of
        true ->
            case (Interval >= stabilizationInterval_max() ) of
                true -> stabilizationInterval_max();
                false -> Interval + ((stabilizationInterval_max() - stabilizationInterval_min()) div 10)
            end;
        false ->
            case (Interval - (stabilizationInterval_max()-stabilizationInterval_min()) div 2) =< (stabilizationInterval_min()  ) of
                true -> stabilizationInterval_min() ;
                false -> Interval - (stabilizationInterval_max()-stabilizationInterval_min()) div 2
            end
    end.

% print_view(Me,View) ->
%     io:format("[~p] -> ",[node:pidX(Me)]),
%     [io:format("~p",[node:pidX(Node)]) || Node <- View],
%     io:format("~n").

% @private

% get Pid of assigned dht_node
get_cs_pid() ->
    process_dictionary:get_group_member(dht_node).

%% @doc the interval between two stabilization runs Max
%% @spec stabilizationInterval_max() -> integer() | failed
stabilizationInterval_max() ->
    config:read(stabilization_interval_max).

%% @doc the interval between two stabilization runs Min
%% @spec stabilizationInterval_min() -> integer() | failed
stabilizationInterval_min() ->
    config:read(stabilization_interval_min).
