%% -*- erlang-indent-level: 2 -*-

%%% @doc Concuerror's scheduler component
%%%
%%% concuerror_scheduler is the main driver of interleaving
%%% exploration.  A rough trace through it is the following:

%%% The entry point is `concuerror_scheduler:run/1` which takes the
%%% options and initializes the exploration, spawning the main
%%% process.  There are plenty of state info that are kept in the
%%% `#scheduler_state` record the most important of which being a list
%%% of `#trace_state` records, recording events in the exploration.
%%% This list corresponds more or less to "E" in the various DPOR
%%% papers (representing the execution trace).

%%% The logic of the exploration goes through `explore/1`, which is
%%% fairly clean: as long as there are more processes that can be
%%% executed and yield events, `get_next_event/1` will be returning
%%% `ok`, after executing one of them and doing all necessary updates
%%% to the state (adding new `#trace_state`s, etc).  If
%%% `get_next_event/1` returns `none`, we are at the end of an
%%% interleaving (either due to no more enabled processes or due to
%%% "sleep set blocking") and can do race analysis and report any
%%% errors found in the interleaving.  Race analysis is contained in
%%% `plan_more_interleavings/1`, reporting whether the current
%%% interleaving was buggy is contained in `log_trace/1` and resetting
%%% most parts to continue exploration is contained in
%%% `has_more_to_explore/1`.

%%% Focusing on `plan_more_interleavings`, it is composed out of two
%%% steps: first (`assign_happens_before/3`) we assign a
%%% happens-before relation to all events to be able to detect when
%%% races are reversible or not (if two events are dependent not only
%%% directly but also via a chain of dependent events then the race is
%%% not reversible) and then (`plan_more_interleavings/3`) for each
%%% event (`more_interleavings_for_event/6`) we do an actual race
%%% analysis, adding initials or wakeup sequences in appropriate
%%% places in the list of `#trace_state`s.

-module(concuerror_scheduler).

%% User interface
-export([run/1, explain_error/1]).

-export_type([ interleaving_error/0,
               interleaving_error_tag/0,
               interleaving_result/0,
               unique_id/0
             ]).

%% =============================================================================
%% DATA STRUCTURES & TYPES
%% =============================================================================

-include("concuerror.hrl").

%%------------------------------------------------------------------------------

-type interleaving_id() :: pos_integer().

-ifdef(BEFORE_OTP_17).
%% Not supported.
-else.
-ifdef(BEFORE_OTP_18).
-type clock_vector() :: orddict:orddict().
-else.
-type clock_vector() :: orddict:orddict(pid(), index()).
-endif.
-endif.

-ifdef(BEFORE_OTP_17).
-type clock_map()           :: dict().
-type message_event_queue() :: queue().
-else.
-type clock_map()           :: dict:dict(pid(), clock_vector()).
-type message_event_queue() :: queue:queue(#message_event{}).
-endif.

-record(backtrack_entry, {
          conservative = false :: boolean(),
          event                :: event(),
          origin = 1           :: interleaving_id(),
          wakeup_tree = []     :: event_tree()
         }).

-type event_tree() :: [#backtrack_entry{}].

-type channel_actor() :: {channel(), message_event_queue()}.

-type unique_id() :: {interleaving_id(), index()}.

-record(trace_state, {
          actors                        :: [pid() | channel_actor()],
          clock_map        = dict:new() :: clock_map(),
          done             = []         :: [event()],
          enabled          = []         :: [pid() | channel_actor()],
          index                         :: index(),
          unique_id                     :: unique_id(),
          previous_actor   = 'none'     :: 'none' | actor(),
          scheduling_bound = infinity   :: concuerror_options:bound(),
          sleep_set        = []         :: [event()],
          wakeup_tree      = []         :: event_tree()
         }).

-type trace_state() :: #trace_state{}.

-type interleaving_result() ::
        'ok' | 'sleep_set_block' | {[interleaving_error()], [event()]}.

-type interleaving_error_tag() ::
        'abnormal_exit' |
        'abnormal_halt' |
        'deadlock' |
        'depth_bound'.

-type interleaving_error() ::
        {'abnormal_exit', {index(), pid(), term(), [term()]}} |
        {'abnormal_halt', {index(), pid(), term()}} |
        {'deadlock', [pid()]} |
        {'depth_bound', concuerror_options:bound()} |
        'fatal'.

%% DO NOT ADD A DEFAULT VALUE IF IT WILL ALWAYS BE OVERWRITTEN.
%% Default values for fields should be specified in ONLY ONE PLACE.
%% For e.g., user options this is normally in the _options module.
-record(scheduler_state, {
          assertions_only              :: boolean(),
          assume_racing                :: assume_racing_opt(),
          current_state_unique_id      :: 'undefined' | unique_id(),
          depth_bound                  :: pos_integer(),
          dpor                         :: concuerror_options:dpor(),
          entry_point                  :: mfargs(),
          first_process                :: pid(),
          ignore_error                 :: [interleaving_error_tag()],
          interleaving_bound           :: concuerror_options:bound(),
          interleaving_errors          :: [interleaving_error()],
          interleaving_id              :: interleaving_id(),
          keep_going                   :: boolean(),
          logger                       :: pid(),
          last_scheduled               :: pid(),
          need_to_replay       = false :: boolean(),
          non_racing_system            :: [atom()],
          origin               = 1     :: interleaving_id(),
          print_depth                  :: pos_integer(),
          processes                    :: processes(),
          receive_timeout_total        :: non_neg_integer(),
          scheduling                   :: concuerror_options:scheduling(),
          scheduling_bound_type        :: concuerror_options:scheduling_bound_type(),
          show_races                   :: boolean(),
          strict_scheduling            :: boolean(),
          timeout                      :: timeout(),
          trace                        :: [trace_state()],
          treat_as_normal              :: [atom()],
          use_receive_patterns         :: boolean(),
          use_sleep_sets               :: boolean(),
          use_unsound_bpor             :: boolean()
         }).

%% =============================================================================
%% LOGIC (high level description of the exploration algorithm)
%% =============================================================================

-spec run(concuerror_options:options()) -> ok.

run(Options) ->
  process_flag(trap_exit, true),
  put(bound_exceeded, false),
  FirstProcess = concuerror_callback:spawn_first_process(Options),
  EntryPoint = ?opt(entry_point, Options),
  Timeout = ?opt(timeout, Options),
  ok =
    concuerror_callback:start_first_process(FirstProcess, EntryPoint, Timeout),
  InitialTrace =
    #trace_state{
       actors = [FirstProcess],
       enabled = [E || E <- [FirstProcess], enabled(E)],
       index = 1,
       scheduling_bound = ?opt(scheduling_bound, Options),
       unique_id = {1, 1}
      },
  Logger = ?opt(logger, Options),
  {SchedulingBoundType, UnsoundBPOR} =
    case ?opt(scheduling_bound_type, Options) of
      ubpor -> {bpor, true};
      Else -> {Else, false}
    end,
  InitialState =
    #scheduler_state{
       assertions_only = ?opt(assertions_only, Options),
       assume_racing = {?opt(assume_racing, Options), Logger},
       depth_bound = ?opt(depth_bound, Options) + 1,
       dpor = ?opt(dpor, Options),
       entry_point = EntryPoint,
       first_process = FirstProcess,
       ignore_error = ?opt(ignore_error, Options),
       interleaving_bound = ?opt(interleaving_bound, Options),
       interleaving_errors = [],
       interleaving_id = 1,
       keep_going = ?opt(keep_going, Options),
       last_scheduled = FirstProcess,
       logger = Logger,
       non_racing_system = ?opt(non_racing_system, Options),
       print_depth = ?opt(print_depth, Options),
       processes = Processes = ?opt(processes, Options),
       receive_timeout_total = 0,
       scheduling = ?opt(scheduling, Options),
       scheduling_bound_type = SchedulingBoundType,
       show_races = ?opt(show_races, Options),
       strict_scheduling = ?opt(strict_scheduling, Options),
       trace = [InitialTrace],
       treat_as_normal = ?opt(treat_as_normal, Options),
       timeout = Timeout,
       use_receive_patterns = ?opt(use_receive_patterns, Options),
       use_sleep_sets = not ?opt(disable_sleep_sets, Options),
       use_unsound_bpor = UnsoundBPOR
      },
  concuerror_logger:plan(Logger),
  ?time(Logger, "Exploration start"),
  Ret = explore(InitialState),
  concuerror_callback:cleanup_processes(Processes),
  Ret.

%%------------------------------------------------------------------------------

explore(State) ->
  {Status, UpdatedState} =
    try
      get_next_event(State)
    catch
      C:R ->
        S = erlang:get_stacktrace(),
        {{crash, C, R, S}, State}
    end,
  case Status of
    ok -> explore(UpdatedState);
    none ->
      LogState = log_trace(UpdatedState),
      RacesDetectedState = plan_more_interleavings(LogState),
      {HasMore, NewState} = has_more_to_explore(RacesDetectedState),
      case HasMore of
        true -> explore(NewState);
        false -> ok
      end;
    {crash, Class, Reason, Stack} ->
      FatalCrashState =
        add_error(fatal, discard_last_trace_state(UpdatedState)),
      catch log_trace(FatalCrashState),
      erlang:raise(Class, Reason, Stack)
  end.

%%------------------------------------------------------------------------------

log_trace(#scheduler_state{logger = Logger} = State) ->
  Log =
    case filter_errors(State) of
      [] -> none;
      Errors ->
        case proplists:get_value(sleep_set_block, Errors) of
          {Origin, Sleep} ->
            case State#scheduler_state.dpor =:= optimal of
              false ->
                ?unique(Logger, ?lwarning, msg(sleep_set_block), []);
              true ->
                ?crash({optimal_sleep_set_block, Origin, Sleep})
            end,
            sleep_set_block;
          undefined ->
            #scheduler_state{trace = Trace} = State,
            Fold =
              fun(#trace_state{done = [A|_], index = I}, Acc) ->
                  [{I, A}|Acc]
              end,
            TraceInfo = lists:foldl(Fold, [], Trace),
            {lists:reverse(Errors), TraceInfo}
        end
    end,
  concuerror_logger:complete(Logger, Log),
  case Log =/= none andalso Log =/= sleep_set_block of
    true when not State#scheduler_state.keep_going ->
      ?unique(Logger, ?lerror, msg(stop_first_error), []),
      State#scheduler_state{trace = []};
    Other ->
      case Other of
        true ->
          ?unique(Logger, ?linfo, "Continuing after error (-k)~n", []);
        false ->
          ok
      end,
      InterleavingId = State#scheduler_state.interleaving_id,
      NextInterleavingId = InterleavingId + 1,
      NextState =
        State#scheduler_state{
          interleaving_errors = [],
          interleaving_id = NextInterleavingId,
          receive_timeout_total = 0
         },
      case NextInterleavingId =< State#scheduler_state.interleaving_bound of
        true -> NextState;
        false ->
          UniqueMsg = "Reached interleaving bound (~p)~n",
          ?unique(Logger, ?lwarning, UniqueMsg, [InterleavingId]),
          NextState#scheduler_state{trace = []}
      end
  end.

filter_errors(State) ->
  #scheduler_state{
     ignore_error = Ignored,
     interleaving_errors = UnfilteredErrors,
     logger = Logger
    } = State,
  filter_errors(UnfilteredErrors, Ignored, Logger).

filter_errors(Errors, [], _) -> Errors;
filter_errors(Errors, [Ignore|Rest] = Ignored, Logger) ->
  case lists:keytake(Ignore, 1, Errors) of
    false -> filter_errors(Errors, Rest, Logger);
    {value, _, NewErrors} ->
      UniqueMsg = "Some errors were ignored ('--ignore_error').~n",
      ?unique(Logger, ?lwarning, UniqueMsg, []),
      filter_errors(NewErrors, Ignored, Logger)
  end.

discard_last_trace_state(State) ->
  #scheduler_state{trace = [_|Trace]} = State,
  State#scheduler_state{trace = Trace}.

add_error(Error, State) ->
  add_errors([Error], State).

add_errors(Errors, State) ->
  #scheduler_state{interleaving_errors = OldErrors} = State,
  State#scheduler_state{interleaving_errors = Errors ++ OldErrors}.

%%------------------------------------------------------------------------------

get_next_event(
  #scheduler_state{
     depth_bound = Bound,
     logger = Logger,
     trace = [#trace_state{index = Bound}|_]} = State) ->
  ?unique(Logger, ?lwarning, msg(depth_bound_reached), []),
  NewState =
    add_error({depth_bound, Bound - 1}, discard_last_trace_state(State)),
  {none, NewState};
get_next_event(#scheduler_state{logger = _Logger, trace = [Last|_]} = State) ->
  #trace_state{index = _I, wakeup_tree = WakeupTree} = Last,
  case WakeupTree of
    [] ->
      Event = #event{label = make_ref()},
      get_next_event(Event, State);
    [#backtrack_entry{event = Event, origin = N}|_] ->
      ?debug(
         _Logger,
         "New interleaving detected in ~p (diverge @ ~p)~n",
         [N, _I]),
      get_next_event(Event, State#scheduler_state{origin = N})
  end.

get_next_event(Event, MaybeNeedsReplayState) ->
  State = replay(MaybeNeedsReplayState),
  #scheduler_state{trace = [Last|_]} = State,
  #trace_state{actors = Actors, sleep_set = SleepSet} = Last,
  SortedActors = schedule_sort(Actors, State),
  #event{actor = Actor, label = Label} = Event,
  case Actor =:= undefined of
    true ->
      AvailableActors = filter_sleep_set(SleepSet, SortedActors),
      free_schedule(Event, AvailableActors, State);
    false ->
      #scheduler_state{print_depth = PrintDepth} = State,
      #trace_state{index = I} = Last,
      false = lists:member(Actor, SleepSet),
      OkUpdatedEvent =
        case Label =/= undefined of
          true ->
            NewEvent = get_next_event_backend(Event, State),
            try {ok, Event} = NewEvent
            catch
              _:_ ->
                New =
                  case NewEvent of
                    {ok, E} -> E;
                    _ -> NewEvent
                  end,
                Reason = {replay_mismatch, I, Event, New, PrintDepth},
                ?crash(Reason)
            end;
          false ->
            %% Last event = Previously racing event = Result may differ.
            ResetEvent = reset_event(Event),
            get_next_event_backend(ResetEvent, State)
        end,
      case OkUpdatedEvent of
        {ok, UpdatedEvent} ->
          update_state(UpdatedEvent, State);
        retry ->
          BReason = {blocked_mismatch, I, Event, PrintDepth},
          ?crash(BReason)
      end
  end.

filter_sleep_set([], AvailableActors) -> AvailableActors;
filter_sleep_set([#event{actor = Actor}|SleepSet], AvailableActors) ->
  NewAvailableActors =
    case ?is_channel(Actor) of
      true -> lists:keydelete(Actor, 1, AvailableActors);
      false -> lists:delete(Actor, AvailableActors)
    end,
  filter_sleep_set(SleepSet, NewAvailableActors).

schedule_sort([], _State) -> [];
schedule_sort(Actors, State) ->
  #scheduler_state{
     last_scheduled = LastScheduled,
     scheduling = Scheduling,
     strict_scheduling = StrictScheduling
    } = State,
  Sorted =
    case Scheduling of
      oldest -> Actors;
      newest -> lists:reverse(Actors);
      round_robin ->
        Split = fun(E) -> E =/= LastScheduled end,    
        {Pre, Post} = lists:splitwith(Split, Actors),
        Post ++ Pre
    end,
  case StrictScheduling of
    true when Scheduling =:= round_robin ->
      [LastScheduled|Rest] = Sorted,
      Rest ++ [LastScheduled];
    false when Scheduling =/= round_robin ->
      [LastScheduled|lists:delete(LastScheduled, Sorted)];
    _ -> Sorted
  end.

free_schedule(Event, Actors, State) ->
  #scheduler_state{
     dpor = DPOR,
     logger = Logger,
     scheduling_bound_type = SchedulingBoundType,
     trace = [Last|Prev]
    } = State,
  case DPOR =/= none of
    true -> free_schedule_1(Event, Actors, State);
    false ->
      Enabled = [A || A <- Actors, enabled(A)],
      ToBeExplored =
        case SchedulingBoundType =:= delay of
          false -> Enabled;
          true ->
            #trace_state{scheduling_bound = SchedulingBound} = Last,
            ?debug(Logger, "Select ~p of ~p~n", [SchedulingBound, Enabled]),
            lists:sublist(Enabled, SchedulingBound + 1)
        end,
      case ToBeExplored < Enabled of
        true -> concuerror_logger:bound_reached(Logger);
        false -> ok
      end,
      Eventify = [maybe_prepare_channel_event(E, #event{}) || E <- ToBeExplored],
      FullBacktrack = [#backtrack_entry{event = Ev} || Ev <- Eventify],
      case FullBacktrack of
        [] -> ok;
        [_|L] ->
          _ = [concuerror_logger:plan(Logger) || _ <- L],
          ok
      end,
      NewLast = Last#trace_state{wakeup_tree = FullBacktrack},
      NewTrace = [NewLast|Prev],
      NewState = State#scheduler_state{trace = NewTrace},
      free_schedule_1(Event, Actors, NewState)
  end.

enabled({_,_}) -> true;
enabled(P) -> concuerror_callback:enabled(P).

free_schedule_1(Event, [Actor|_], State) when ?is_channel(Actor) ->
  %% Pending messages can always be sent
  PrepEvent = maybe_prepare_channel_event(Actor, Event),
  {ok, FinalEvent} = get_next_event_backend(PrepEvent, State),
  update_state(FinalEvent, State);
free_schedule_1(Event, [P|ActiveProcesses], State) ->
  case get_next_event_backend(Event#event{actor = P}, State) of
    retry -> free_schedule_1(Event, ActiveProcesses, State);
    {ok, UpdatedEvent} -> update_state(UpdatedEvent, State)
  end;
free_schedule_1(_Event, [], State) ->
  %% Nothing to do, trace is completely explored
  #scheduler_state{logger = _Logger, trace = [Last|_]} = State,
  #trace_state{actors = Actors, sleep_set = SleepSet} = Last,
  NewErrors =
    case SleepSet =/= [] of
      true ->
        ?debug(_Logger, "Sleep set block:~n ~p~n", [SleepSet]),
        [{sleep_set_block, {State#scheduler_state.origin, SleepSet}}];
      false ->
        case concuerror_callback:collect_deadlock_info(Actors) of
          [] -> [];
          Info ->
            ?debug(_Logger, "Deadlock: ~p~n", [[P || {P,_} <- Info]]),
            [{deadlock, Info}]
        end
    end,
  {none, add_errors(NewErrors, discard_last_trace_state(State))}.

maybe_prepare_channel_event(Actor, Event) ->
  case ?is_channel(Actor) of
    false -> Event#event{actor = Actor};
    true ->
      {Channel, Queue} = Actor,
      MessageEvent = queue:get(Queue),
      Event#event{actor = Channel, event_info = MessageEvent}
  end.      

reset_event(#event{actor = Actor, event_info = EventInfo}) ->
  ResetEventInfo =
    case ?is_channel(Actor) of
      true -> EventInfo;
      false -> undefined
    end,
  #event{
     actor = Actor,
     event_info = ResetEventInfo,
     label = make_ref()
    }.

%%------------------------------------------------------------------------------

update_state(#event{actor = Actor} = Event, State) ->
  #scheduler_state{
     logger = Logger,
     scheduling_bound_type = SchedulingBoundType,
     trace = [Last|Prev],
     use_sleep_sets = UseSleepSets
    } = State,
  #trace_state{
     actors      = Actors,
     done        = RawDone,
     index       = Index,
     previous_actor = PreviousActor,
     scheduling_bound = SchedulingBound,
     sleep_set   = SleepSet,
     unique_id   = {InterleavingId, Index} = UID,
     wakeup_tree = WakeupTree
    } = Last,
  ?trace(Logger, "~s~n", [?pretty_s(Index, Event)]),
  concuerror_logger:graph_new_node(Logger, UID, Index, Event, 0),
  Done = reset_receive_done(RawDone, State),
  NextSleepSet =
    case UseSleepSets of
      true ->
        AllSleepSet =
          case WakeupTree of
            [#backtrack_entry{conservative = true}|_] ->
              concuerror_logger:plan(Logger),
              SleepSet;
            _ -> ordsets:union(ordsets:from_list(Done), SleepSet)
          end,
        update_sleep_set(Event, AllSleepSet, State);
      false -> []
    end,
  {NewLastWakeupTree, NextWakeupTree} =
    case WakeupTree of
      [] -> {[], []};
      [#backtrack_entry{wakeup_tree = NWT}|Rest] -> {Rest, NWT}
    end,
  NewSchedulingBound =
    next_bound(SchedulingBoundType, Done, PreviousActor, SchedulingBound),
  ?trace(Logger, "  Next bound: ~p~n", [NewSchedulingBound]),
  NewLastDone = [Event|Done],
  NextIndex = Index + 1,
  InitNextTrace =
    #trace_state{
       actors      = Actors,
       index       = NextIndex,
       previous_actor = Actor,
       scheduling_bound = NewSchedulingBound,
       sleep_set   = NextSleepSet,
       unique_id   = {InterleavingId, NextIndex},
       wakeup_tree = NextWakeupTree
      },
  NewLastTrace =
    Last#trace_state{
      done = NewLastDone,
      wakeup_tree = NewLastWakeupTree
     },
  UpdatedSpecialNextTrace =
    update_special(Event#event.special, InitNextTrace),
  NextTrace =
    maybe_update_enabled(SchedulingBoundType, UpdatedSpecialNextTrace),
  InitNewState =
    State#scheduler_state{trace = [NextTrace, NewLastTrace|Prev]},
  NewState = maybe_log(Event, InitNewState, Index),
  {ok, NewState}.

maybe_log(#event{actor = P} = Event, State0, Index) ->
  #scheduler_state{
     assertions_only = AssertionsOnly,
     logger = Logger,
     receive_timeout_total = ReceiveTimeoutTotal,
     treat_as_normal = Normal
    } = State0,
  State = 
    case is_pid(P) of
      true -> State0#scheduler_state{last_scheduled = P};
      false -> State0
    end,
  case Event#event.event_info of
    #builtin_event{mfargs = {erlang, exit, [_,Reason]}}
      when Reason =/= normal ->
      ?unique(Logger, ?ltip, msg(signal), []),
      State;
    #builtin_event{mfargs = {erlang, halt, [Status|_]}}
      when Status =/= 0 ->
      #event{actor = Actor} = Event,
      add_error({abnormal_halt, {Index, Actor, Status}}, State);
    #exit_event{reason = Reason} = Exit when Reason =/= normal ->
      {Tag, WasTimeout} =
        if tuple_size(Reason) > 0 ->
            T = element(1, Reason),
            {T, T =:= timeout};
           true -> {Reason, false}
        end,
      case is_atom(Tag) andalso lists:member(Tag, Normal) of
        true ->
          ?unique(Logger, ?lwarning, msg(treat_as_normal), []),
          State;
        false ->
          if WasTimeout -> ?unique(Logger, ?ltip, msg(timeout), []);
             Tag =:= shutdown -> ?unique(Logger, ?ltip, msg(shutdown), []);
             true -> ok
          end,
          IsAssertLike =
            case Tag of
              {MaybeAssert, _} when is_atom(MaybeAssert) ->
                case atom_to_list(MaybeAssert) of
                  "assert"++_ -> true;
                  _ -> false
                end;
              _ -> false
            end,
          Report =
            case {IsAssertLike, AssertionsOnly} of
              {false, true} ->
                ?unique(Logger, ?lwarning, msg(assertions_only_filter), []),
                false;
              {true, false} ->
                ?unique(Logger, ?ltip, msg(assertions_only_use), []),
                true;
              _ -> true
            end,
          if Report ->
              #event{actor = Actor} = Event,
              Stacktrace = Exit#exit_event.stacktrace,
              add_error({abnormal_exit, {Index, Actor, Reason, Stacktrace}}, State);
             true -> State
          end
      end;
    #receive_event{message = 'after'} ->
      NewReceiveTimeoutTotal = ReceiveTimeoutTotal + 1,
      Threshold = 50,
      case NewReceiveTimeoutTotal =:= Threshold of
        true ->
          ?unique(Logger, ?ltip, msg(maybe_receive_loop), [Threshold]);
        false -> ok
      end,
      State#scheduler_state{receive_timeout_total = NewReceiveTimeoutTotal};
    _ -> State
  end.

update_sleep_set(NewEvent, SleepSet, State) ->
  #scheduler_state{logger = _Logger} = State,
  Pred =
    fun(OldEvent) ->
        V = concuerror_dependencies:dependent_safe(NewEvent, OldEvent),
        ?trace(_Logger, "     Awaking (~p): ~s~n", [V,?pretty_s(OldEvent)]),
        V =:= false
    end,
  lists:filter(Pred, SleepSet).

update_special(List, TraceState) when is_list(List) ->
  lists:foldl(fun update_special/2, TraceState, List);
update_special(Special, #trace_state{actors = Actors} = TraceState) ->
  NewActors =
    case Special of
      halt -> [];
      {message, Message} ->
        add_message(Message, Actors);
      {message_delivered, MessageEvent} ->
        remove_message(MessageEvent, Actors);
      {message_received, _Message} ->
        Actors;
      {new, SpawnedPid} ->
        Actors ++ [SpawnedPid];
      {system_communication, _} ->
        Actors
    end,
  TraceState#trace_state{actors = NewActors}.

add_message(MessageEvent, Actors) ->
  #message_event{recipient = Recipient, sender = Sender} = MessageEvent,
  Channel = {Sender, Recipient},
  Update = fun(Queue) -> queue:in(MessageEvent, Queue) end,
  Initial = queue:from_list([MessageEvent]),
  insert_message(Channel, Update, Initial, Actors).

insert_message(Channel, Update, Initial, Actors) ->
  insert_message(Channel, Update, Initial, Actors, false, []).

insert_message(Channel, _Update, Initial, [], Found, Acc) ->
  case Found of
    true -> lists:reverse(Acc, [{Channel, Initial}]);
    false -> [{Channel, Initial}|lists:reverse(Acc)]
  end;
insert_message(Channel, Update, _Initial, [{Channel, Queue}|Rest], true, Acc) ->
  NewQueue = Update(Queue),
  lists:reverse(Acc, [{Channel, NewQueue}|Rest]);
insert_message({From, _} = Channel, Update, Initial, [Other|Rest], Found, Acc) ->
  case Other of
    {{_,_},_} ->
      insert_message(Channel, Update, Initial, Rest, Found, [Other|Acc]);
    From ->
      insert_message(Channel, Update, Initial, Rest,  true, [Other|Acc]);
    _ ->
      case Found of
        false ->
          insert_message(Channel, Update, Initial, Rest, Found, [Other|Acc]);
        true ->
          lists:reverse(Acc, [{Channel, Initial},Other|Rest])
      end
  end.

remove_message(#message_event{recipient = Recipient, sender = Sender}, Actors) ->
  Channel = {Sender, Recipient},
  remove_message(Channel, Actors, []).

remove_message(Channel, [{Channel, Queue}|Rest], Acc) ->
  NewQueue = queue:drop(Queue),
  case queue:is_empty(NewQueue) of
    true  -> lists:reverse(Acc, Rest);
    false -> lists:reverse(Acc, [{Channel, NewQueue}|Rest])
  end;
remove_message(Channel, [Other|Rest], Acc) ->
  remove_message(Channel, Rest, [Other|Acc]).

maybe_update_enabled(bpor, TraceState) ->
  #trace_state{actors = Actors} = TraceState,
  Enabled = [E || E <- Actors, enabled(E)],
  TraceState#trace_state{enabled = Enabled};
maybe_update_enabled(_, TraceState) ->
  TraceState.

%%------------------------------------------------------------------------------

plan_more_interleavings(#scheduler_state{dpor = none} = State) ->
  #scheduler_state{logger = _Logger} = State,
  ?debug(_Logger, "Skipping race detection~n", []),
  State;
plan_more_interleavings(State) ->
  #scheduler_state{
     dpor = DPOR,
     logger = Logger,
     trace = RevTrace,
     use_receive_patterns = UseReceivePatterns
    } = State,
  ?time(Logger, "Assigning happens-before..."),
  {RE, UntimedLate} = split_trace(RevTrace),
  {RevEarly, Late} =
    case UseReceivePatterns of
      false ->
        {RE, lists:reverse(assign_happens_before(UntimedLate, RE, State, untimed))};
      true ->
        RevUntimedLate = lists:reverse(UntimedLate),
        {ObsLate, Dict} = fix_receive_info(RevUntimedLate),
        {ObsEarly, _Dict} = fix_receive_info(RE, Dict),
        FixedEarly = assign_happens_before(ObsEarly, [], State, new_observers),
        FixedLate = assign_happens_before(ObsLate, FixedEarly, State, untimed),
        {FixedEarly, lists:reverse(FixedLate)}
    end,
  ?time(Logger, "Planning more interleavings..."),
  NewRevTrace =
    case DPOR =:= optimal of
      true ->
        plan_more_interleavings(lists:reverse(RevEarly, Late), [], State);
      false ->
        plan_more_interleavings(Late, RevEarly, State)
    end,
  State#scheduler_state{trace = NewRevTrace}.

split_trace(RevTrace) ->
  split_trace(RevTrace, []).

split_trace([], UntimedLate) ->
  {[], UntimedLate};
split_trace([#trace_state{clock_map = ClockMap} = State|RevEarlier] = RevEarly,
            UntimedLate) ->
  case dict:size(ClockMap) =:= 0 of
    true  -> split_trace(RevEarlier, [State|UntimedLate]);
    false -> {RevEarly, UntimedLate}
  end.

assign_happens_before(UntimedLate, RevEarly, State, Mode) ->
  assign_happens_before(UntimedLate, [], RevEarly, State, Mode).

assign_happens_before([], RevLate, _RevEarly, _State, _Mode) ->
  RevLate;
assign_happens_before([TraceState|Later], RevLate, RevEarly, State, Mode) ->
  #trace_state{done = [Event|_], index = Index} = TraceState,
  NewTraceState =
    case needs_recalculation(Event, Mode) of
      false -> TraceState;
      true ->
        #scheduler_state{logger = _Logger} = State,
        #event{actor = Actor, special = Special} = Event,
        ClockMap = get_base_clock(RevLate, RevEarly),
        OldClock = lookup_clock(Actor, ClockMap),
        ActorClock = orddict:store(Actor, Index, OldClock),
        ?trace(_Logger, "HB: ~s~n", [?pretty_s(Index,Event)]),
        BaseHappenedBeforeClock =
          add_pre_message_clocks(Special, ClockMap, ActorClock),
        HappenedBeforeClock =
          update_clock(RevLate, RevEarly, Event, BaseHappenedBeforeClock, State),
        BaseNewClockMap = dict:store(Actor, HappenedBeforeClock, ClockMap),
        NewClockMap =
          add_new_and_messages(Special, HappenedBeforeClock, BaseNewClockMap),
        StateClock = lookup_clock(state, ClockMap),
        OldActorClock = lookup_clock_value(Actor, StateClock),
        FinalActorClock = orddict:store(Actor, OldActorClock, HappenedBeforeClock),
        FinalStateClock = orddict:store(Actor, Index, StateClock),
        FinalClockMap =
          dict:store(
            Actor, FinalActorClock,
            dict:store(state, FinalStateClock, NewClockMap)),
        TraceState#trace_state{clock_map = FinalClockMap}
    end,
  assign_happens_before(Later, [NewTraceState|RevLate], RevEarly, State, Mode).

needs_recalculation(Event, Mode) ->
  Mode =:= untimed orelse is_message(Event).

is_message(#event{event_info = #message_event{}}) -> true;
is_message(#event{}) -> false.

get_base_clock(RevLate, RevEarly) ->
  case get_base_clock(RevLate) of
    {ok, V} -> V;
    none ->
      case get_base_clock(RevEarly) of
        {ok, V} -> V;
        none -> dict:new()
      end
  end.

get_base_clock([#trace_state{clock_map = ClockMap}|_]) -> {ok, ClockMap};
get_base_clock([]) -> none.

add_pre_message_clocks([], _, Clock) -> Clock;
add_pre_message_clocks([Special|Specials], ClockMap, Clock) ->
  NewClock =
    case Special of
      {message_delivered, #message_event{message = #message{id = Id}}} ->
        max_cv(Clock, lookup_clock({Id, sent}, ClockMap));
      {message_received, Id} ->
        max_cv(Clock, lookup_clock({Id, delivered}, ClockMap));
      _ -> Clock
    end,
  add_pre_message_clocks(Specials, ClockMap, NewClock).

add_new_and_messages([], _Clock, ClockMap) ->
  ClockMap;
add_new_and_messages([Special|Rest], Clock, ClockMap) ->
  NewClockMap =
    case Special of
      {new, SpawnedPid} ->
        dict:store(SpawnedPid, Clock, ClockMap);
      {message, #message_event{message = #message{id = Id}}} ->
        dict:store({Id, sent}, Clock, ClockMap);
      {message_delivered, #message_event{message = #message{id = Id}}} ->
        dict:store({Id, delivered}, Clock, ClockMap);
      _ -> ClockMap
    end,
  add_new_and_messages(Rest, Clock, NewClockMap).

update_clock(RevLate, RevEarly, Event, Clock, State) ->
  Clock1 = update_clock(RevLate, Event, Clock, State),
  update_clock(RevEarly, Event, Clock1, State).

update_clock([], _Event, Clock, _State) ->
  Clock;
update_clock([TraceState|Rest], Event, Clock, State) ->
  #trace_state{
     done = [#event{actor = EarlyActor} = EarlyEvent|_],
     index = EarlyIndex
    } = TraceState,
  EarlyClock = lookup_clock_value(EarlyActor, Clock),
  NewClock =
    case EarlyIndex > EarlyClock of
      false -> Clock;
      true ->
        #scheduler_state{assume_racing = AssumeRacing} = State,
        Dependent =
          concuerror_dependencies:dependent(EarlyEvent, Event, AssumeRacing),
        ?trace(State#scheduler_state.logger,
               "    ~s ~s~n",
               begin
                 Star = fun(false) -> " ";(_) -> "*" end,
                 [Star(Dependent), ?pretty_s(EarlyIndex,EarlyEvent)]
               end),
        case Dependent =:= false of
          true -> Clock;
          false ->
            #trace_state{clock_map = ClockMap} = TraceState,
            EarlyActorClock = lookup_clock(EarlyActor, ClockMap),
            max_cv(
              Clock, orddict:store(EarlyActor, EarlyIndex, EarlyActorClock))
        end
    end,
  update_clock(Rest, Event, NewClock, State).

plan_more_interleavings([], OldTrace, _SchedulerState) ->
  OldTrace;
plan_more_interleavings([TraceState|Rest], OldTrace, State) ->
  #scheduler_state{
     logger = _Logger,
     non_racing_system = NonRacingSystem
    } = State,
  #trace_state{done = [Event|_], index = Index, unique_id = UID} = TraceState,
  #event{actor = Actor, event_info = EventInfo, special = Special} = Event,
  Skip =
    case proplists:lookup(system_communication, Special) of
      {system_communication, System} -> lists:member(System, NonRacingSystem);
      none -> false
    end,
  case Skip of
    true ->
      plan_more_interleavings(Rest, [TraceState|OldTrace], State);
    false ->
      ClockMap = get_base_clock(OldTrace, []),
      StateClock = lookup_clock(state, ClockMap),
      ActorLast = lookup_clock_value(Actor, StateClock),
      ActorClock = orddict:store(Actor, ActorLast, lookup_clock(Actor, ClockMap)),
      BaseClock =
        case ?is_channel(Actor) of
          true ->
            #message_event{message = #message{id = Id}} = EventInfo,
            lookup_clock({Id, sent}, ClockMap);
          false -> ActorClock
        end,
      ?debug(_Logger, "~s~n", [?pretty_s(Index, Event)]),
      GState = State#scheduler_state{current_state_unique_id = UID},
      BaseNewOldTrace =
        more_interleavings_for_event(OldTrace, Event, Rest, BaseClock, GState, Index),
      NewOldTrace = [TraceState|BaseNewOldTrace],
      plan_more_interleavings(Rest, NewOldTrace, State)
  end.

more_interleavings_for_event(OldTrace, Event, Later, Clock, State, Index) ->
  more_interleavings_for_event(OldTrace, Event, Later, Clock, State, Index, []).

more_interleavings_for_event([], _Event, _Later, _Clock, _State, _Index,
                             NewOldTrace) ->
  lists:reverse(NewOldTrace);
more_interleavings_for_event([TraceState|Rest], Event, Later, Clock, State,
                             Index, NewOldTrace) ->
  #trace_state{
     clock_map = EarlyClockMap,
     done = [#event{actor = EarlyActor} = EarlyEvent|_],
     index = EarlyIndex
    } = TraceState,
  EarlyClock = lookup_clock_value(EarlyActor, Clock),
  Action =
    case EarlyIndex > EarlyClock of
      false -> none;
      true ->
        Dependent =
          case concuerror_dependencies:dependent_safe(EarlyEvent, Event) of
            true -> {true, no_observer};
            Other -> Other
          end,
        case Dependent of
          false -> none;
          irreversible -> update_clock;
          {true, ObserverInfo} ->
            ?debug(State#scheduler_state.logger,
                   "   races with ~s~n",
                   [?pretty_s(EarlyIndex, EarlyEvent)]),
            case
              update_trace(
                EarlyEvent, Event, Clock, TraceState,
                Later, NewOldTrace, Rest, ObserverInfo, State)
            of
              skip -> update_clock;
              {UpdatedNewOldTrace, ConservativeCandidates} ->
                {update, UpdatedNewOldTrace, ConservativeCandidates}
            end
        end
    end,
  NewClock =
    case Action =:= none of
      true -> Clock;
      false ->
        orddict:store(
          EarlyActor, EarlyIndex,
          max_cv(lookup_clock(EarlyActor, EarlyClockMap), Clock))
    end,
  {NewTrace, NewRest} =
    case Action of
      none -> {[TraceState|NewOldTrace], Rest};
      update_clock -> {[TraceState|NewOldTrace], Rest};
      {update, S, CI} ->
        maybe_log_race(TraceState, Index, Event, State),
        NR = add_conservative(Rest, EarlyActor, EarlyClock, CI, State),
        {S, NR}
    end,
  more_interleavings_for_event(NewRest, Event, Later, NewClock, State, Index, NewTrace).

update_trace(
  EarlyEvent, Event, Clock, TraceState,
  Later, NewOldTrace, Rest, ObserverInfo, State
 ) ->
  #scheduler_state{
     dpor = DPOR,
     interleaving_id = Origin,
     logger = Logger,
     scheduling_bound_type = SchedulingBoundType,
     use_unsound_bpor = UseUnsoundBPOR,
     use_receive_patterns = UseReceivePatterns
    } = State,
  #trace_state{
     done = [#event{actor = EarlyActor} = EarlyEvent|Done] = AllDone,
     index = EarlyIndex,
     previous_actor = PreviousActor,
     scheduling_bound = BaseBound,
     sleep_set = BaseSleepSet,
     wakeup_tree = Wakeup
    } = TraceState,
  Bound = next_bound(SchedulingBoundType, AllDone, PreviousActor, BaseBound),
  DPORInfo =
    {DPOR,
     case DPOR =:= persistent of
       true -> Clock;
       false -> {EarlyActor, EarlyIndex}
     end},
  SleepSet = BaseSleepSet ++ Done,
  RevEvent = update_context(Event, EarlyEvent),
  {MaybeNewWakeup, ConservativeInfo} =
    case Bound < 0 of
      true ->
        {over_bound,
         case SchedulingBoundType =:= bpor of
           true ->
             NotDep = not_dep(NewOldTrace, Later, DPORInfo, RevEvent),
             get_initials(NotDep);
           false ->
             false
         end};
      false ->
        NotDep = not_dep(NewOldTrace, Later, DPORInfo, RevEvent),
        {Plan, _} = NW =
          case DPOR =:= optimal of
            true ->
              case UseReceivePatterns of
                false ->
                  {insert_wakeup_optimal(SleepSet, Wakeup, NotDep, Bound, Origin), false};
                true ->
                  V =
                    case ObserverInfo =:= no_observer of
                      true -> NotDep;
                      false ->
                        NotObsRaw =
                          not_obs_raw(NewOldTrace, Later, ObserverInfo, Event),
                        NotObs = NotObsRaw -- NotDep,
                        NotDep ++ [EarlyEvent#event{label = undefined}] ++ NotObs
                    end,
                  RevV = lists:reverse(V),
                  {FixedV, ReceiveInfoDict} = fix_receive_info(RevV),
                  {FixedRest, _} = fix_receive_info(Rest, ReceiveInfoDict),
                  show_plan(v, Logger, 0, FixedV),
                  case has_weak_initial_before(lists:reverse(FixedRest), FixedV, Logger) of
                    true -> {skip, false};
                    false ->
                      {insert_wakeup_optimal(Done, Wakeup, FixedV, Bound, Origin), false}
                  end
              end;
            false ->
              Initials = get_initials(NotDep),
              AddCons =
                case SchedulingBoundType =:= bpor of
                  true -> Initials;
                  false -> false
                end,
              {insert_wakeup_non_optimal(SleepSet, Wakeup, Initials, false, Origin), AddCons}
          end,
        case is_atom(Plan) of
          true -> NW;
          false ->
            show_plan(standard, Logger, EarlyIndex, NotDep),
            NW
        end
    end,
  case MaybeNewWakeup of
    skip ->
      ?debug(Logger, "     SKIP~n",[]),
      skip;
    over_bound ->
      concuerror_logger:bound_reached(Logger),
      case UseUnsoundBPOR of
        true -> ok;
        false -> put(bound_exceeded, true)
      end,
      {[TraceState|NewOldTrace], ConservativeInfo};
    NewWakeup ->
      NS = TraceState#trace_state{wakeup_tree = NewWakeup},
      concuerror_logger:plan(Logger),
      {[NS|NewOldTrace], ConservativeInfo}
  end.

not_dep(Trace, Later, DPORInfo, RevEvent) ->
  NotDep = not_dep1(Trace, Later, DPORInfo, []),
  lists:reverse([RevEvent|NotDep]).

not_dep1([], [], _DPORInfo, NotDep) ->
  NotDep;
not_dep1([], T, {DPOR, _} = DPORInfo, NotDep) ->
  KeepLooking =
    case DPOR =:= optimal of
      true -> T;
      false -> []
    end,
  not_dep1(KeepLooking,  [], DPORInfo, NotDep);
not_dep1([TraceState|Rest], Later, {DPOR, Info} = DPORInfo, NotDep) ->
  #trace_state{
     clock_map = ClockMap,
     done = [#event{actor = LaterActor} = LaterEvent|_],
     index = LateIndex
    } = TraceState,
  NewNotDep =
    case DPOR =:= persistent of
      true ->
        Clock = Info,
        LaterActorClock = lookup_clock_value(LaterActor, Clock),
        case LateIndex > LaterActorClock of
          true -> NotDep;
          false -> [LaterEvent|NotDep]
        end;
      false ->
        {Actor, Index} = Info,
        LaterClock = lookup_clock(LaterActor, ClockMap),
        ActorLaterClock = lookup_clock_value(Actor, LaterClock),
        case Index > ActorLaterClock of
          false -> NotDep;
          true -> [LaterEvent|NotDep]
        end
    end,
  not_dep1(Rest, Later, DPORInfo, NewNotDep).

update_context(Event, EarlyEvent) ->
  NewEventInfo =
    case Event#event.event_info of
      %% A receive statement...
      #receive_event{message = Msg} = Info when Msg =/= 'after' ->
        %% ... in race with a message.
        case is_process_info_related(EarlyEvent) of
          true -> Info;
          false -> Info#receive_event{message = 'after'}
        end;
      Info -> Info
    end,
  %% The racing event's effect should differ, so new label.
  Event#event{
    event_info = NewEventInfo,
    label = undefined
   }.

is_process_info_related(Event) ->
  case Event#event.event_info of
    #builtin_event{mfargs = {erlang, process_info, _}} -> true;
    _ -> false
  end.

not_obs_raw(NewOldTrace, Later, ObserverInfo, Event) ->
  lists:reverse(not_obs_raw(NewOldTrace, Later, ObserverInfo, Event, [])).

not_obs_raw([], [], _ObserverInfo, _Event, _NotObs) ->
  [];
not_obs_raw([], Later, ObserverInfo, Event, NotObs) ->
  not_obs_raw(Later, [], ObserverInfo, Event, NotObs);
not_obs_raw([TraceState|Rest], Later, ObserverInfo, Event, NotObs) ->
  #trace_state{done = [#event{special = Special} = E|_]} = TraceState,
  case [Id || {message_received, Id} <- Special, Id =:= ObserverInfo] =:= [] of
    true ->
      not_obs_raw(Rest, Later, ObserverInfo, Event, [E|NotObs]);
    false ->
      #event{special = NewSpecial} = Event,
      ObsNewSpecial =
        case lists:keyfind(message_delivered, 1, NewSpecial) of
          {message_delivered, #message_event{message = #message{id = NewId}}} ->
            lists:keyreplace(ObserverInfo, 2, Special, {message_received, NewId});
          _ -> exit(impossible)
        end,
      [E#event{label = undefined, special = ObsNewSpecial}|NotObs]
  end.

has_weak_initial_before([], _, _Logger) ->
  ?debug(_Logger, "No weak initial before~n",[]),
  false;
has_weak_initial_before([TraceState|Rest], V, Logger) ->
  #trace_state{done = [EarlyEvent|Done]} = TraceState,
  case has_initial(Done, [EarlyEvent|V]) of
    true ->
      ?debug(Logger, "Check: ~s~n",[?join([?pretty_s(0,D)||D<-Done],"~n")]),
      show_plan(initial, Logger, 1, [EarlyEvent|V]),
      true;
    false ->
      ?debug(Logger, "Up~n",[]),
      has_weak_initial_before(Rest, [EarlyEvent|V], Logger)
  end.

show_plan(_Type, _Logger, _Index, _NotDep) ->
  ?debug(
     _Logger, "     PLAN (Type: ~p)~n~s",
     begin
       Indices = lists:seq(_Index, _Index + length(_NotDep) - 1),
       IndexedNotDep = lists:zip(Indices, _NotDep),
       [_Type] ++
         [lists:append(
            [io_lib:format("        ~s~n", [?pretty_s(I,S)])
             || {I,S} <- IndexedNotDep])]
     end).

maybe_log_race(TraceState, Index, Event, State) ->
  #scheduler_state{logger = Logger} = State,
  if State#scheduler_state.show_races ->
      #trace_state{done = [EarlyEvent|_], index = EarlyIndex} = TraceState,
      EarlyUID = TraceState#trace_state.unique_id,
      UID = State#scheduler_state.current_state_unique_id,
      concuerror_logger:graph_race(Logger, EarlyUID, UID),
      IndexedEarly = {EarlyIndex, EarlyEvent#event{location = []}},
      IndexedLate = {Index, Event#event{location = []}},
      concuerror_logger:race(Logger, IndexedEarly, IndexedLate);
     true ->
      ?unique(Logger, ?linfo, msg(show_races), [])
  end.

insert_wakeup_non_optimal(SleepSet, Wakeup, Initials, Conservative, Origin) ->
  case existing(SleepSet, Initials) of
    true -> skip;
    false -> add_or_make_compulsory(Wakeup, Initials, Conservative, Origin)
  end.

add_or_make_compulsory(Wakeup, Initials, Conservative, Origin) ->
  add_or_make_compulsory(Wakeup, Initials, Conservative, Origin, []).

add_or_make_compulsory([], [E|_], Conservative, Origin, Acc) ->
  Entry =
    #backtrack_entry{
       conservative = Conservative,
       event = E, origin = Origin,
       wakeup_tree = []
      },
  lists:reverse([Entry|Acc]);
add_or_make_compulsory([Entry|Rest], Initials, Conservative, Origin, Acc) ->
  #backtrack_entry{conservative = C, event = E, wakeup_tree = []} = Entry,
  #event{actor = A} = E,
  Pred = fun(#event{actor = B}) -> A =:= B end,
  case lists:any(Pred, Initials) of
    true ->
      case C andalso not Conservative of
        true ->
          NewEntry = Entry#backtrack_entry{conservative = false},
          lists:reverse(Acc, [NewEntry|Rest]);
        false -> skip
      end;
    false ->
      NewAcc = [Entry|Acc],
      add_or_make_compulsory(Rest, Initials, Conservative, Origin, NewAcc)
  end.

insert_wakeup_optimal(SleepSet, Wakeup, V, Bound, Origin) ->
  case has_initial(SleepSet, V) of
    true -> skip;
    false -> insert_wakeup(Wakeup, V, Bound, Origin)
  end.

has_initial([Event|Rest], V) ->
  case check_initial(Event, V) =:= false of
    true -> has_initial(Rest, V);
    false -> true
  end;
has_initial([], _) -> false.

insert_wakeup(          _, _NotDep,  Bound, _Origin) when Bound < 0 ->
  over_bound;
insert_wakeup(         [],  NotDep, _Bound,  Origin) ->
  backtrackify(NotDep, Origin);
insert_wakeup([Node|Rest],  NotDep,  Bound,  Origin) ->
  #backtrack_entry{event = Event, origin = M, wakeup_tree = Deeper} = Node,
  case check_initial(Event, NotDep) of
    false ->
      NewBound =
        case is_integer(Bound) of
          true -> Bound - 1;
          false -> Bound
        end,
      case insert_wakeup(Rest, NotDep, NewBound, Origin) of
        Special
          when
            Special =:= skip;
            Special =:= over_bound -> Special;
        NewTree -> [Node|NewTree]
      end;
    NewNotDep ->
      case Deeper =:= [] of
        true  -> skip;
        false ->
          case insert_wakeup(Deeper, NewNotDep, Bound, Origin) of
            Special
              when
                Special =:= skip;
                Special =:= over_bound -> Special;
            NewTree ->
              Entry =
                #backtrack_entry{
                   event = Event,
                   origin = M,
                   wakeup_tree = NewTree},
              [Entry|Rest]
          end
      end
  end.

backtrackify(Seq, Cause) ->
  Fold =
    fun(Event, Acc) ->
        [#backtrack_entry{event = Event, origin = Cause, wakeup_tree = Acc}]
    end,
  lists:foldr(Fold, [], Seq).

check_initial(Event, NotDep) ->
  check_initial(Event, NotDep, []).

check_initial(_Event, [], Acc) ->
  lists:reverse(Acc);
check_initial(Event, [E|NotDep], Acc) ->
  #event{actor = EventActor} = Event,
  #event{actor = EActor} = E,
  case EventActor =:= EActor of
    true -> lists:reverse(Acc,NotDep);
    false ->
      case concuerror_dependencies:dependent_safe(E, Event) =:= false of
        true -> check_initial(Event, NotDep, [E|Acc]);
        false -> false
      end
  end.

get_initials(NotDeps) ->
  get_initials(NotDeps, [], []).

get_initials([], Initials, _) -> lists:reverse(Initials);
get_initials([Event|Rest], Initials, All) ->
  Fold =
    fun(Initial, Acc) ->
        Acc andalso
          concuerror_dependencies:dependent_safe(Initial, Event) =:= false
    end,
  NewInitials =
    case lists:foldr(Fold, true, All) of
      true -> [Event|Initials];
      false -> Initials
    end,
  get_initials(Rest, NewInitials, [Event|All]).            

existing([], _) -> false;
existing([#event{actor = A}|Rest], Initials) ->
  Pred = fun(#event{actor = B}) -> A =:= B end,
  lists:any(Pred, Initials) orelse existing(Rest, Initials).

add_conservative(Rest, _Actor, _Clock, false, _State) ->
  Rest;
add_conservative(Rest, Actor, Clock, Candidates, State) ->
  case add_conservative(Rest, Actor, Clock, Candidates, State, []) of
    abort ->
      ?debug(State#scheduler_state.logger, "  aborted~n",[]),
      Rest;
    NewRest -> NewRest
  end.

add_conservative([], _Actor, _Clock, _Candidates, _State, _Acc) ->
  abort;
add_conservative([TraceState|Rest], Actor, Clock, Candidates, State, Acc) ->
  #scheduler_state{
     interleaving_id = Origin,
     logger = _Logger
    } = State,
  #trace_state{
     done = [#event{actor = EarlyActor} = _EarlyEvent|Done],
     enabled = Enabled,
     index = EarlyIndex,
     previous_actor = PreviousActor,
     sleep_set = BaseSleepSet,
     wakeup_tree = Wakeup
    } = TraceState,
  ?debug(_Logger,
         "   conservative check with ~s~n",
         [?pretty_s(EarlyIndex, _EarlyEvent)]),
  case EarlyActor =:= Actor of
    false -> abort;
    true ->
      case EarlyIndex < Clock of
        true -> abort;
        false ->
          case PreviousActor =:= Actor of
            true ->
              NewAcc = [TraceState|Acc],
              add_conservative(Rest, Actor, Clock, Candidates, State, NewAcc);
            false ->
              EnabledCandidates =
                [C ||
                  #event{actor = A} = C <- Candidates,
                  lists:member(A, Enabled)],
              case EnabledCandidates =:= [] of
                true -> abort;
                false ->
                  SleepSet = BaseSleepSet ++ Done,
                  case
                    insert_wakeup_non_optimal(
                      SleepSet, Wakeup, EnabledCandidates, true, Origin
                     )
                  of
                    skip -> abort;
                    NewWakeup ->
                      NS = TraceState#trace_state{wakeup_tree = NewWakeup},
                      lists:reverse(Acc, [NS|Rest])
                  end
              end
          end
      end
  end.

%%------------------------------------------------------------------------------

has_more_to_explore(State) ->
  #scheduler_state{
     scheduling_bound_type = SchedulingBoundType,
     trace = Trace
    } = State,
  TracePrefix = find_prefix(Trace, SchedulingBoundType),
  case TracePrefix =:= [] of
    true -> {false, State#scheduler_state{trace = []}};
    false ->
      NewState =
        State#scheduler_state{need_to_replay = true, trace = TracePrefix},
      {true, NewState}
  end.

find_prefix([], _SchedulingBoundType) -> [];
find_prefix(Trace, SchedulingBoundType) ->
  [#trace_state{wakeup_tree = Tree} = TraceState|Rest] = Trace,
  case SchedulingBoundType =/= 'bpor' orelse get(bound_exceeded) of
    false ->
      case [B || #backtrack_entry{conservative = false} = B <- Tree] of
        [] -> find_prefix(Rest, SchedulingBoundType);
        WUT -> [TraceState#trace_state{wakeup_tree = WUT}|Rest]
      end;
    true ->
      case Tree =:= [] of
        true -> find_prefix(Rest, SchedulingBoundType);
        false -> Trace
      end
  end.

replay(#scheduler_state{need_to_replay = false} = State) ->
  State;
replay(State) ->
  #scheduler_state{interleaving_id = N, logger = Logger, trace = Trace} = State,
  [#trace_state{index = I, unique_id = Sibling} = Last|
   [#trace_state{unique_id = Parent}|_] = Rest] = Trace,
  concuerror_logger:graph_set_node(Logger, Parent, Sibling),
  NewTrace =
    [Last#trace_state{unique_id = {N, I}, clock_map = dict:new()}|Rest],
  S = io_lib:format("New interleaving ~p. Replaying...", [N]),
  ?time(Logger, S),
  NewState = replay_prefix(NewTrace, State#scheduler_state{trace = NewTrace}),
  ?debug(Logger, "~s~n",["Replay done."]),
  NewState#scheduler_state{need_to_replay = false}.

%% =============================================================================

reset_receive_done([Event|Rest], #scheduler_state{use_receive_patterns = true}) ->
  NewSpecial =
    [patch_message_delivery(S, dict:new()) || S <- Event#event.special],
  [Event#event{special = NewSpecial}|Rest];
reset_receive_done(Done, _) ->
  Done.

fix_receive_info(RevTraceOrEvents) ->
  fix_receive_info(RevTraceOrEvents, dict:new()).

fix_receive_info(RevTraceOrEvents, ReceiveInfoDict) ->
  fix_receive_info(RevTraceOrEvents, ReceiveInfoDict, []).

fix_receive_info([], ReceiveInfoDict, TraceOrEvents) ->
  {TraceOrEvents, ReceiveInfoDict};
fix_receive_info([#trace_state{} = TraceState|RevTrace], ReceiveInfoDict, Trace) ->
  [Event|Rest] = TraceState#trace_state.done,
  {[NewEvent], NewDict} = fix_receive_info([Event], ReceiveInfoDict, []),
  NewTraceState = TraceState#trace_state{done = [NewEvent|Rest]},
  fix_receive_info(RevTrace, NewDict, [NewTraceState|Trace]);
fix_receive_info([#event{} = Event|RevEvents], ReceiveInfoDict, Events) ->
  #event{event_info = EventInfo, special = Special} = Event,
  NewReceiveInfoDict = store_receive_info(EventInfo, Special, ReceiveInfoDict),
  NewSpecial = [patch_message_delivery(S, NewReceiveInfoDict) || S <- Special],
  NewEventInfo =
    case EventInfo of
      #message_event{} ->
        {_, NI} =
          patch_message_delivery({message_delivered, EventInfo}, NewReceiveInfoDict),
        NI;
      _ -> EventInfo
    end,
  NewEvent = Event#event{event_info = NewEventInfo, special = NewSpecial},
  fix_receive_info(RevEvents, NewReceiveInfoDict, [NewEvent|Events]).

store_receive_info(EventInfo, Special, ReceiveInfoDict) ->
  case [ID || {message_received, ID} <- Special] of
    [] -> ReceiveInfoDict;
    IDs ->
      ReceiveInfo =
        case EventInfo of
          #receive_event{receive_info = RI} -> RI;
          _ -> {system, fun(_) -> true end}
        end,
      Fold = fun(ID,Dict) -> dict:store(ID, ReceiveInfo, Dict) end,
      lists:foldl(Fold, ReceiveInfoDict, IDs)
  end.

patch_message_delivery({message_delivered, MessageEvent}, ReceiveInfoDict) ->
  #message_event{message = #message{id = Id}} = MessageEvent,
  ReceiveInfo =
    case dict:find(Id, ReceiveInfoDict) of
      {ok, RI} -> RI;
      error -> not_received
    end,
  {message_delivered, MessageEvent#message_event{receive_info = ReceiveInfo}};
patch_message_delivery(Other, _ReceiveInfoDict) ->
  Other.

%% =============================================================================
%% ENGINE (manipulation of the Erlang processes under the scheduler)
%% =============================================================================

replay_prefix(Trace, State) ->
  #scheduler_state{
     entry_point = EntryPoint,
     first_process = FirstProcess,
     processes = Processes,
     timeout = Timeout
    } = State,
  concuerror_callback:reset_processes(Processes),
  ok =
    concuerror_callback:start_first_process(FirstProcess, EntryPoint, Timeout),
  NewState = State#scheduler_state{last_scheduled = FirstProcess},
  replay_prefix_aux(lists:reverse(Trace), NewState).

replay_prefix_aux([_], State) ->
  %% Last state has to be properly replayed.
  State;
replay_prefix_aux([#trace_state{done = [Event|_], index = I}|Rest], State) ->
  #scheduler_state{logger = _Logger, print_depth = PrintDepth} = State,
  ?trace(_Logger, "~s~n", [?pretty_s(I, Event)]),
  {ok, #event{actor = Actor} = NewEvent} = get_next_event_backend(Event, State),
  try
    true = Event =:= NewEvent
  catch
    _:_ ->
      #scheduler_state{print_depth = PrintDepth} = State,
      ?crash({replay_mismatch, I, Event, NewEvent, PrintDepth})
  end,
  NewLastScheduled =
    case is_pid(Actor) of
      true -> Actor;
      false -> State#scheduler_state.last_scheduled
    end,
  NewState = State#scheduler_state{last_scheduled = NewLastScheduled},
  replay_prefix_aux(Rest, maybe_log(Event, NewState, I)).

%% =============================================================================
%% INTERNAL INTERFACES
%% =============================================================================

%% Between scheduler and an instrumented process
%%------------------------------------------------------------------------------

get_next_event_backend(#event{actor = Channel} = Event, State)
  when ?is_channel(Channel) ->
  #scheduler_state{timeout = Timeout} = State,
  #event{event_info = MessageEvent} = Event,
  assert_no_messages(),
  UpdatedEvent =
    concuerror_callback:deliver_message(Event, MessageEvent, Timeout),
  {ok, UpdatedEvent};
get_next_event_backend(#event{actor = Pid} = Event, State) when is_pid(Pid) ->
  #scheduler_state{timeout = Timeout} = State,
  assert_no_messages(),
  Pid ! Event,
  concuerror_callback:wait_actor_reply(Event, Timeout).

assert_no_messages() ->
  receive
    Msg -> error({pending_message, Msg})
  after
    0 -> ok
  end.

%%%----------------------------------------------------------------------
%%% Helper functions
%%%----------------------------------------------------------------------

lookup_clock(P, ClockMap) ->
  case dict:find(P, ClockMap) of
    {ok, Clock} -> Clock;
    error -> orddict:new()
  end.

lookup_clock_value(P, CV) ->
  case orddict:find(P, CV) of
    {ok, Value} -> Value;
    error -> 0
  end.

max_cv(D1, D2) ->
  Merger = fun(_Key, V1, V2) -> max(V1, V2) end,
  orddict:merge(Merger, D1, D2).

next_bound(SchedulingBoundType, Done, PreviousActor, Bound) ->
  case SchedulingBoundType of
    none -> Bound;
    bpor ->
      NonPreemptExplored =
        [E || #event{actor = PA} = E <- Done, PA =:= PreviousActor] =/= [],
      case NonPreemptExplored of
        true -> Bound - 1;
        false -> Bound
      end;
    delay ->
      %% Every reschedule costs.
      Bound - length(Done)
  end.

%% =============================================================================

-spec explain_error(term()) -> string().

explain_error({blocked_mismatch, I, Event, Depth}) ->
  EString = concuerror_io_lib:pretty_s(Event, Depth),
  io_lib:format(
    "On step ~p, replaying a built-in returned a different result than"
    " expected:~n"
    "  original:~n"
    "    ~s~n"
    "  new:~n"
    "    blocked~n"
    ?notify_us_msg,
    [I,EString]
   );
explain_error({optimal_sleep_set_block, Origin, Who}) ->
  io_lib:format(
    "During a run of the optimal algorithm, the following events were left in~n"
    "a sleep set (the race was detected at interleaving #~p)~n~n"
    "  ~p~n"
    ?notify_us_msg,
    [Origin, Who]
   );
explain_error({replay_mismatch, I, Event, NewEvent, Depth}) ->
  [EString, NEString] =
    [concuerror_io_lib:pretty_s(E, Depth) || E <- [Event, NewEvent]],
  [Original, New] =
    case EString =/= NEString of
      true -> [EString, NEString];
      false ->
        [io_lib:format("~p",[E]) || E <- [Event, NewEvent]]
    end,
  io_lib:format(
    "On step ~p, replaying a built-in returned a different result than"
    " expected:~n"
    "  original:~n"
    "    ~s~n"
    "  new:~n"
    "    ~s~n"
    ?notify_us_msg,
    [I,Original,New]
   ).

%%==============================================================================

msg(after_timeout_tip) ->
  "You can use e.g. '--after_timeout 5000' to treat after timeouts that exceed"
    " some threshold (here 4999ms) as 'infinity'.~n";
msg(assertions_only_filter) ->
  "Only assertion failures are considered abnormal exits ('--assertions_only').~n";
msg(assertions_only_use) ->
  "A process exited with reason '{{assert*,_}, _}'. If you want to see only"
    " this kind of error you can use the '--assertions_only' option.~n";
msg(depth_bound_reached) ->
  "An interleaving reached the depth bound. This can happen if a test has an"
    " infinite execution. Concuerror is not sound for testing programs with"
    " infinite executions. Consider limiting the size of the test or increasing"
    " the bound ('-h depth_bound').~n";
msg(maybe_receive_loop) ->
  "The trace contained more than ~w receive timeout events"
    " (receive statements that executed their 'after' clause). Concuerror by"
    " default treats 'after' clauses as always possible, so a 'receive loop'"
    " using a timeout can lead to an infinite execution. "
    ++ msg(after_timeout_tip);
msg(signal) ->
  "An abnormal exit signal was sent to a process. This is probably the worst"
    " thing that can happen race-wise, as any other side-effecting"
    " operation races with the arrival of the signal. If the test produces"
    " too many interleavings consider refactoring your code.~n";
msg(show_races) ->
  "You can see pairs of racing instructions (in the report and"
    " '--graph') with '--show_races true'~n";
msg(shutdown) ->
  "A process exited with reason 'shutdown'. This may happen when a"
    " supervisor is terminating its children. You can use '--treat_as_normal"
    " shutdown' if this is expected behaviour.~n";
msg(sleep_set_block) ->
  "Some interleavings were 'sleep-set blocked'. This is expected, since you are"
    " not using '--dpor optimal', but indicates wasted effort.~n";
msg(stop_first_error) ->
  "Stop testing on first error. (Check '-h keep_going').~n";
msg(timeout) ->
  "A process exited with reason '{timeout, ...}'. This may happen when a"
    " call to a gen_server (or similar) does not receive a reply within some"
    " timeout (5000ms by default). "
    ++ msg(after_timeout_tip);
msg(treat_as_normal) ->
  "Some abnormal exit reasons were treated as normal ('--treat_as_normal').~n".
