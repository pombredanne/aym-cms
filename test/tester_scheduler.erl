%  @copyright 2010 Konrad-Zuse-Zentrum fuer Informationstechnik Berlin
%  @end
%
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
%%%-------------------------------------------------------------------
%%% File    tester.erl
%%% @author Thorsten Schuett <schuett@zib.de>
%%% @doc    user-space scheduler
%%% @end
%%% Created :  4 Feb 2011 by Thorsten Schuett <schuett@zib.de>
%%%-------------------------------------------------------------------
%% @version $Id$
-module(tester_scheduler).

-author('schuett@zib.de').
-vsn('$Id$').

-export([
         % instrumented calls
         gen_component_spawned/1,
         gen_component_initialized/1,
         gen_component_calling_receive/1,
         comm_send/2,
         comm_send_local/2,
         comm_send_local_after/3,

         % create scheduler
         start/1,

         % start scheduling
         start_scheduling/0,

         % instrument a module
         instrument_module/2
         ]).

% tester_scheduler cannot use gen_component because gen_component is
% instrumented!

-include("tester.hrl").
-include("unittest.hrl").

-record(state, {waiting_processes::any(),
                started::boolean(),
               white_list::list(tuple())}).

comm_send(Pid, Message) ->
    {RealPid, RealMessage} = comm:unpack_cookie(Pid,Message),
    usscheduler ! {comm_send, self(), RealPid, RealMessage},
    receive
        {comm_send, ack} ->
            ok
    end,
    % assume TCP
    comm_layer:send(RealPid, RealMessage),
    ok.

comm_send_local(Pid, Message) ->
    {RealPid, RealMessage} = comm:unpack_cookie(Pid,Message),
    usscheduler ! {comm_send_local, self(), RealPid, RealMessage},
    receive
        {comm_send_local, ack} ->
            ok
    end,
    RealPid ! RealMessage,
    ok.

comm_send_local_after(Delay, Pid, Message) ->
    {RealPid, RealMessage} = comm:unpack_cookie(Pid,Message),
    usscheduler ! {comm_send_local_after, self(), Delay, RealPid, RealMessage},
    receive
        {comm_send_local_after, ack} ->
            ok
    end,
    erlang:send_after(Delay, RealPid, RealMessage),
    ok.

gen_component_spawned(Module) ->
    usscheduler ! {gen_component_spawned, self(), Module},
    receive
        {gen_component_spawned, ack} ->
            ok
    end.

gen_component_initialized(Module) ->
    usscheduler ! {gen_component_initialized, self(), Module},
    receive
        {gen_component_initialized, ack} ->
            ok
    end.

gen_component_calling_receive(Module) ->
    usscheduler ! {gen_component_calling_receive, self(), Module},
    receive
        {gen_component_calling_receive, ack} ->
            ok
    end.

start_scheduling() ->
    ct:pal("start_scheduling()", []),
    usscheduler ! {start_scheduling},
    ok.

instrument_module(Module, Src) ->
    code:delete(Module),
    code:purge(Module),
    case compile:file(Src, [binary, return_errors,
                            {i, "/home/schuett/zib/scalaris/include"},
                            {i, "/home/schuett/zib/scalaris/contrib/yaws/include"},
                            {i, "/home/schuett/zib/scalaris/contrib/log4erl/include"},
                            {d, tid_not_builtin},
                            {d, with_ct},
                            {parse_transform, tester_scheduler_parse_transform},
                            {d, with_export_type_support}]) of
        {ok,_ModuleName,Binary} ->
            %ct:pal("~w", [erlang:load_module(Module, Binary)]),
            %ct:pal("~w", [code:is_loaded(Module)]),
            ct:pal("Load binary: ~w", [code:load_binary(Module, Src, Binary)]),
            ct:pal("~w", [code:is_loaded(Module)]),
            ok;
        {ok,_ModuleName,Binary,Warnings} ->
            ct:pal("~w", [Warnings]),
            ct:pal("~w", [erlang:load_module(Module, Binary)]),
            ok;
        X ->
            ct:pal("1: ~w", [X]),
            ok
    end,
    ok.

loop(#state{waiting_processes=Waiting, started=Started, white_list=WhiteList} = State) ->
    receive
        {gen_component_spawned, Pid, Module} ->
            ct:pal("spawned ~w in ~w", [Pid, Module]),
            Pid ! {gen_component_spawned, ack},
            loop(State);
        {gen_component_initialized, Pid, Module} ->
            ct:pal("initialized ~w in ~w", [Pid, Module]),
            Pid ! {gen_component_initialized, ack},
            loop(State);
        {gen_component_calling_receive, Pid, Module} ->
            case lists:member(Module, WhiteList) of
                true ->
                    Pid ! {gen_component_calling_receive, ack},
                    loop(State);
                false ->
                    case Started of
                        true ->
                            %Pid ! {gen_component_calling_receive, ack},
                            loop(schedule_next_task(State, Pid));
                        false ->
                            ct:pal("stopped ~w in ~w", [Pid, Module]),
                            %Pid ! {gen_component_calling_receive, ack},
                            loop(State#state{waiting_processes=gb_sets:add(Pid, Waiting)})
                    end
            end;
        {comm_send, ReqPid, Pid, Message} ->
            ReqPid ! {comm_send, ack},
            loop(State);
        {comm_send_local, ReqPid, Pid, Message} ->
            ReqPid ! {comm_send_local, ack},
            loop(State);
        {comm_send_local_after, ReqPid, Delay, Pid, Message} ->
            ReqPid ! {comm_send_local_after, ack},
            loop(State);
        {reschedule} ->
            loop(schedule_next_task(State));
        {start_scheduling} ->
            loop(State#state{started=true});
        X ->
            ct:pal("unknown message ~w", [X]),
            loop(State)
    end.

start(Options) ->
    WhiteList = case lists:keyfind(white_list, 1, Options) of
                    {white_list, List} ->
                        List;
                    false ->
                        []
                end,
    State = #state{waiting_processes=gb_sets:new(), started=false, white_list=WhiteList},
    spawn_link(fun () -> loop(State) end).

schedule_next_task(#state{waiting_processes=Waiting, started=Started, white_list=WhiteList} = State, Pid) ->
    Waiting2 = gb_sets:add(Pid, Waiting),
    schedule_next_task(State#state{waiting_processes=Waiting2}).

schedule_next_task(#state{waiting_processes=Waiting, started=Started, white_list=WhiteList} = State) ->
    case pick_next_runner(Waiting) of
        false ->
            erlang:send_after(sleep_delay(), self(), {reschedule}),
            loop(State);
        Pid ->
            ct:pal("picked ~w", [Pid]),
            Pid ! {gen_component_calling_receive, ack},
            loop(State#state{waiting_processes=gb_sets:delete_any(Pid, Waiting)})
    end.

pick_next_runner(Pids) ->
    Runnable = gb_sets:fold(fun (Pid, List) ->
                                    case erlang:process_info(Pid, message_queue_len) of
                                        {message_queue_len, 0} ->
                                            List;
                                        {message_queue_len, _} ->
                                            [Pid | List];
                                        _ ->
                                            List
                                    end
                            end, [], Pids),
    case Runnable of
        [] ->
            false;
        _ ->
            util:randomelem(Runnable)
    end.

sleep_delay() -> 100.
% @todo
% - start_scheduling could set a new white_list
