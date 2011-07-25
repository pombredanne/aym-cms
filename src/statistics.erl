% @copyright 2007-2011 Zuse Institute Berlin

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

%% @author Thorsten Schuett <schuett@zib.de>
%% @doc Statistics Module for mgmt server
%% @version $Id$
-module(statistics).
-author('schuett@zib.de').
-vsn('$Id$').

-export([get_ring_details/0, get_ring_details_neighbors/1,
         get_total_load/1, get_average_load/1, get_load_std_deviation/1,
         get_average_rt_size/1, get_rt_size_std_deviation/1,
         get_memory_usage/1, get_max_memory_usage/1]).

-include("scalaris.hrl").

-ifdef(with_export_type_support).
-export_type([ring/0, ring_element/0]).
-endif.

-type ring_element() :: {ok, Details::node_details:node_details()} | {failed, comm:mypid()}.
-type ring() :: [ring_element()].

-spec get_total_load(Ring::ring()) -> node_details:load().
get_total_load(Ring) ->
    lists:foldl(fun (X, Sum) -> X + Sum end, 0, lists:map(fun get_load/1, Ring)).

-spec get_average_load(Ring::ring()) -> float().
get_average_load(Ring) ->
    FilteredRing = lists:filter(fun (X) -> is_valid(X) end, Ring),
    get_total_load(FilteredRing) / length(FilteredRing).

-spec get_memory_usage(Ring::ring()) -> float().
get_memory_usage(Ring) ->
    FilteredRing = lists:filter(fun (X) -> is_valid(X) end, Ring),
    lists:foldl(fun (X, Sum) -> X + Sum end, 0,
                lists:map(fun get_memory/1, FilteredRing)) / length(FilteredRing).

-spec get_max_memory_usage(Ring::ring()) -> node_details:memory().
get_max_memory_usage(Ring) ->
    lists:foldl(fun (X, Sum) -> util:max(X, Sum) end, 0,
                lists:map(fun get_memory/1, Ring)).

-spec get_load_std_deviation(Ring::ring()) -> float().
get_load_std_deviation(Ring) ->
    FilteredRing = lists:filter(fun (X) -> is_valid(X) end, Ring),
    Average = get_average_load(FilteredRing),
    math:sqrt(lists:foldl(fun (Load, Acc) ->
                                   Acc + (Load - Average) * (Load - Average)
                          end, 0,
                          lists:map(fun get_load/1, FilteredRing)) / length(FilteredRing)).

-spec get_load(ring_element()) -> node_details:load().
get_load({ok, Details}) ->
    node_details:get(Details, load);
get_load({failed, _}) ->
    0.

-spec get_memory(ring_element()) -> node_details:memory().
get_memory({ok, Details}) ->
    node_details:get(Details, memory);
get_memory({failed, _}) ->
    0.

%% @doc Returns a sorted list of all known nodes.
%%      See compare_node_details/2 for a definition of the order.
%%      Note: throws 'mgmt_server_timeout' if the mgmt server does not respond
%%      within 2s.
-spec get_ring_details() -> ring().
get_ring_details() ->
    mgmt_server:node_list(),
    Nodes = receive
                {get_list_response, N} -> N
            after 2000 ->
                log:log(error,"[ ST ] Timeout getting node list from mgmt server"),
                throw('mgmt_server_timeout')
            end,
    lists:sort(fun compare_node_details/2, get_ring_details(Nodes)).

%% @doc Returns a sorted list of all known nodes in the neighborhoods of the
%%      dht_node processes in this VM, recurses to their neighboring nodes if
%%      requested.
%%      See compare_node_details/2 for a definition of the order.
-spec get_ring_details_neighbors(RecursionLvl::non_neg_integer()) -> ring().
get_ring_details_neighbors(RecursionLvl) ->
    Nodes = [comm:make_global(Pid) || Pid <- pid_groups:find_all(dht_node)],
    get_ring_details_neighbors(RecursionLvl, [], Nodes).

-spec get_ring_details_neighbors(RecursionLvl::non_neg_integer(), Ring::ring(), Nodes::[comm:mypid()]) -> ring().
get_ring_details_neighbors(RecursionLvl, Ring, Nodes) ->
    % first get the nodes with no details yet:
    RingNodes = [begin
                     case RingE of
                         {ok, Details} ->
                             node:pidX(node_details:get(Details, node));
                         {failed, Pid} ->
                             Pid
                     end
                 end || RingE <- Ring],
    {_OnlyRing, _Both, NewNodes} = util:split_unique(RingNodes, Nodes),
    % then get their node details:
    NewRing = lists:sort(fun compare_node_details/2,
                         lists:append(Ring, get_ring_details(NewNodes))),
    case RecursionLvl =< 1 of
        true -> NewRing;
        _ -> % gather nodes for the next recusion:
            NextNodes =
                lists:append(
                  [begin
                     case RingE of
                         {ok, Details} ->
                             [node:pidX(Node) || Node <- node_details:get(Details, predlist)] ++
                             [node:pidX(Node) || Node <- node_details:get(Details, succlist)];
                         {failed, _Pid} ->
                             []
                     end
                 end || RingE <- NewRing]),
            get_ring_details_neighbors(RecursionLvl - 1, NewRing, NextNodes)
    end.

%% @doc Returns a sorted list of details about the given nodes.
%%      See compare_node_details/2 for a definition of the order.
-spec get_ring_details(Nodes::[comm:mypid()]) -> ring().
get_ring_details(Nodes) ->
    _ = [begin
             SourcePid = comm:this_with_cookie(Pid),
             comm:send(Pid, {get_node_details, SourcePid})
         end || Pid <- Nodes],
    get_node_details(Nodes, [], 0).

%% @doc Defines an order of ring_element() terms so that {failed, Pid} terms
%%      are considered the smallest but sorted by their pids.
%%      Terms like {ok, node_details:node_details()} are compared using the
%%      order of their node ids.
-spec compare_node_details(ring_element(), ring_element()) -> boolean().
compare_node_details({ok, X}, {ok, Y}) ->
    node:id(node_details:get(X, node)) < node:id(node_details:get(Y, node));
compare_node_details({failed, X}, {failed, Y}) ->
    X =< Y;
compare_node_details({failed, _}, {ok, _}) ->
    true;
compare_node_details({ok, _}, {failed, _}) ->
    false.

-spec get_node_details(Pids::[comm:mypid()], ring(), TimeInMS::non_neg_integer()) -> ring().
get_node_details([], Ring, _TimeInS) -> Ring;
get_node_details(Pids, Ring, TimeInMS) ->
    Continue =
        if
            TimeInMS =:= 2000 ->
                log:log(error,"[ ST ]: 2sec Timeout waiting for get_node_details_response from ~p",[Pids]),
                continue;
            TimeInMS >= 6000 ->
                log:log(error,"[ ST ]: 6sec Timeout waiting for get_node_details_response from ~p",[Pids]),
                stop;
            true -> continue
    end,
    case Continue of
        continue ->
            receive
                {{get_node_details_response, Details}, Pid} ->
                    get_node_details(lists:delete(Pid, Pids),
                                     [{ok, Details} | Ring],
                                     TimeInMS)
            after
                10 ->
                    get_node_details(Pids, Ring, TimeInMS + 10)
            end;
        _ -> Failed = [{failed, Pid} || Pid <- Pids],
             lists:append(Failed, Ring)
    end.

%%%-------------------------------RT----------------------------------

-spec get_total_rt_size(Ring::ring()) -> node_details:rt_size().
get_total_rt_size(Ring) ->
    lists:foldl(fun (X, Sum) -> X + Sum end, 0, lists:map(fun get_rt/1, Ring)).

-spec get_average_rt_size(Ring::ring()) -> float().
get_average_rt_size(Ring) ->
    FilteredRing = lists:filter(fun (X) -> is_valid(X) end, Ring),
    get_total_rt_size(FilteredRing) / length(FilteredRing).

-spec get_rt_size_std_deviation(Ring::ring()) -> float().
get_rt_size_std_deviation(Ring) ->
    FilteredRing = lists:filter(fun (X) -> is_valid(X) end, Ring),
    Average = get_average_rt_size(FilteredRing),
    math:sqrt(lists:foldl(fun (RTSize, Acc) ->
                                   Acc + (RTSize - Average) * (RTSize - Average)
                          end, 0,
                          lists:map(fun get_rt/1, FilteredRing)) / length(FilteredRing)).

-spec get_rt(ring_element()) -> node_details:rt_size().
get_rt({ok, Details}) ->
    node_details:get(Details, rt_size);
get_rt({failed, _}) ->
    0.

-spec is_valid({ok, Details::node_details:node_details()}) -> true;
              ({failed, _}) -> false.
is_valid({ok, _}) ->
    true;
is_valid({failed, _}) ->
    false.
