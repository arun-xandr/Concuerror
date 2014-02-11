%% -*- erlang-indent-level: 2 -*-

-module(concuerror_callback).

%% Interface to concuerror_inspect:
-export([instrumented/4]).

%% Interface to scheduler:
-export([spawn_first_process/1, start_first_process/2]).

%% Interface for resetting:
-export([process_top_loop/2]).

%%------------------------------------------------------------------------------

%% DEBUGGING SETTINGS

-define(flag(A), (1 bsl A)).

-define(builtin, ?flag(1)).
-define(non_builtin, ?flag(2)).
-define(receive_, ?flag(3)).
-define(receive_messages, ?flag(4)).
-define(stack, ?flag(5)).
-define(args, ?flag(6)).
-define(result, ?flag(7)).
-define(spawn, ?flag(8)).
-define(short_builtin, ?flag(9)).
-define(wait, ?flag(10)).
-define(send, ?flag(11)).
-define(exit, ?flag(12)).
-define(trap, ?flag(13)).
-define(undefined, ?flag(14)).
-define(heir, ?flag(15)).

-define(ACTIVE_FLAGS, [?undefined]).

%% -define(DEBUG, true).
-define(DEBUG_FLAGS, lists:foldl(fun erlang:'bor'/2, 0, ?ACTIVE_FLAGS)).

%%------------------------------------------------------------------------------

-include("concuerror.hrl").
-include("concuerror_callback.hrl").

-type concuerror_info() :: #concuerror_info{}.

%%------------------------------------------------------------------------------

-spec spawn_first_process(options()) -> pid().

spawn_first_process(Options) ->
  [AfterTimeout, EtsTables, Logger, Processes] =
    get_properties(['after-timeout', ets_tables, logger, processes], Options),
  InitialInfo =
    #concuerror_info{
       'after-timeout' = AfterTimeout,
       ets_tables = EtsTables,
       logger = Logger,
       processes = Processes,
       scheduler = self()
      },
  spawn_link(fun() -> process_top_loop(InitialInfo, "P") end).

get_properties(Props, PropList) ->
  get_properties(Props, PropList, []).

get_properties([], _, Acc) -> lists:reverse(Acc);
get_properties([Prop|Props], PropList, Acc) ->
  PropVal = proplists:get_value(Prop, PropList),
  get_properties(Props, PropList, [PropVal|Acc]).

-spec start_first_process(pid(), {atom(), atom(), [term()]}) -> ok.

start_first_process(Pid, {Module, Name, Args}) ->
  Pid ! {start, Module, Name, Args},
  ok.

%%------------------------------------------------------------------------------

-spec instrumented(Tag      :: instrumented_tags(),
                   Args     :: [term()],
                   Location :: term(),
                   Info     :: concuerror_info()) ->
                      {Return :: term(), NewInfo :: concuerror_info()}.

instrumented(call, [Module, Name, Args], Location, Info) ->
  Arity = length(Args),
  instrumented_aux(call, Module, Name, Arity, Args, Location, Info);
instrumented(apply, [Fun, Args], Location, Info) ->
  case is_function(Fun) of
    true ->
      Module = get_fun_info(Fun, module),
      Name = get_fun_info(Fun, name),
      Arity = get_fun_info(Fun, arity),
      case length(Args) =:= Arity of
        true -> instrumented_aux(apply, Module, Name, Arity, Args, Location, Info);
        false -> {doit, Info}
      end;
    false ->
      {doit, Info}
  end;
instrumented('receive', [PatternFun, Timeout], Location, Info) ->
  handle_receive(PatternFun, Timeout, Location, Info).

instrumented_aux(Tag, Module, Name, Arity, Args, Location, Info) ->
  case
    erlang:is_builtin(Module, Name, Arity) andalso
    not lists:member({Module, Name, Arity}, ?RACE_FREE_BIFS)
  of
    true  ->
      built_in(Module, Name, Arity, Args, Location, Info);
    false ->
      _Log = {Tag, Module, Name, Arity, Location},
      ?debug_flag(?non_builtin, _Log),
      ?debug_flag(?args, {args, Args}),
      NewInfo = Info,%append_stack(Log, Info),
      ok = concuerror_loader:load_if_needed(Module),
      {doit, NewInfo}
  end.

get_fun_info(Fun, Tag) ->
  {Tag, Info} = erlang:fun_info(Fun, Tag),
  Info.

%%------------------------------------------------------------------------------

%% Process dictionary has been restored here. No need to report such ops.
built_in(erlang, get, _Arity, Args, _Location, Info) ->
  {{didit, erlang:apply(erlang,get,Args)}, Info};
%% XXX: Check if its redundant (e.g. link to already linked)
built_in(Module, Name, Arity, Args, Location, Info) ->
  ?debug_flag(?short_builtin, {'built-in', Module, Name, Arity, Location}),
  %% {Stack, ResetInfo} = reset_stack(Info),
  %% ?debug_flag(?stack, {stack, Stack}),
  LocatedInfo = add_location_info(Location, Info),%ResetInfo),
  try
    %% XXX: TODO If replaying, inspect if original crashed and replay crash
    {Value, #concuerror_info{next_event = Event} = UpdatedInfo} =
      run_built_in(Module, Name, Arity, Args, LocatedInfo),
    ?debug_flag(?builtin, {'built-in', Module, Name, Arity, Value, Location}),
    ?debug_flag(?args, {args, Args}),
    ?debug_flag(?result, {args, Value}),
    EventInfo = #builtin_event{mfa = {Module, Name, Args}, result = Value},
    Notification = Event#event{event_info = EventInfo},
    NewInfo = notify(Notification, UpdatedInfo),
    {{didit, Value}, NewInfo}
  catch
    error:Reason ->
      #concuerror_info{scheduler = Scheduler} = Info,
      exit(Scheduler, {Reason, Module, Name, Arity, Location}),
      receive after infinity -> ok end;
    throw:{error, Reason} ->
      #concuerror_info{next_event = FEvent} = LocatedInfo,
      FEventInfo = #builtin_event{mfa = {Module, Name, Args}, crashed = true},
      FNotification = FEvent#event{event_info = FEventInfo},
      FNewInfo = notify(FNotification, LocatedInfo),
      FinalInfo =
        FNewInfo#concuerror_info{stacktop = {Module, Name, Args, Location}},
      {{error, Reason}, FinalInfo}
  end.

%% Special instruction running control (e.g. send to unknown -> wait for reply)
run_built_in(erlang, exit, 2, [Pid, Reason],
             #concuerror_info{
                next_event = #event{event_info = EventInfo} = Event
               } = Info) ->
  case EventInfo of
    %% Replaying...
    #builtin_event{result = OldResult} -> {OldResult, Info};
    %% New event...
    undefined ->
      Message =
        #message{data = {'EXIT', self(), Reason}, message_id = make_ref()},
      MessageEvent =
        #message_event{
           cause_label = Event#event.label,
           message = Message,
           recipient = Pid,
           type = exit_signal},
      NewEvent = Event#event{special = {message, MessageEvent}},
      {true, Info#concuerror_info{next_event = NewEvent}}
  end;

run_built_in(erlang, link, 1, [Pid], Info) ->
  #concuerror_info{links = Old, processes = Processes} = Info,
  case ets:lookup(Processes, Pid) =/= [] of
    false ->
      ?debug_flag(?undefined, {link_to_external, Pid}),
      throw({error, badarg});
    true ->
      Pid ! {link, self(), confirm},
      receive
        success ->
          NewInfo = Info#concuerror_info{links = ordsets:add_element(Pid, Old)},
          {true, NewInfo};
        failed ->
          throw({error, badarg})
      end
  end;
run_built_in(erlang, register, 2, [Name, Pid],
             #concuerror_info{processes = Processes} = Info) ->
  try
    true = is_atom(Name),
    true = is_pid(Pid) orelse is_port(Pid),
    [] = ets:match(Processes, ?process_name_pattern(Name)),
    ?process_name_none = ets:lookup_element(Processes, Pid, ?process_name),
    false = undefined =:= Name,
    true = ets:update_element(Processes, Pid, {?process_name, Name}),
    {true, Info}
  catch
    _:_ -> throw({error, badarg})
  end;
run_built_in(erlang, spawn, 3, [M, F, Args], Info) ->
  run_built_in(erlang, spawn_opt, 1, [{M, F, Args, []}], Info);
run_built_in(erlang, spawn_link, 3, [M, F, Args], Info) ->
  run_built_in(erlang, spawn_opt, 1, [{M, F, Args, [link]}], Info);
run_built_in(erlang, spawn_opt, 1, [{Module, Name, Args, SpawnOpts}], Info) ->
  #concuerror_info{next_event = Event, processes = Processes} = Info,
  #event{event_info = EventInfo} = Event,
  {Result, NewInfo} =
    case EventInfo of
      %% Replaying...
      #builtin_event{result = OldResult} -> {OldResult, Info};
      %% New event...
      undefined ->
        PassedInfo = init_concuerror_info(Info),
        Parent = self(),
        ?debug_flag(?spawn, {Parent, spawning_new, PassedInfo}),
        ParentSymbol = ets:lookup_element(Processes, Parent, ?process_symbolic),
        ChildId = ets:update_counter(Processes, Parent, {?process_children, 1}),
        ChildSymbol = io_lib:format("~s.~w",[ParentSymbol, ChildId]),
        P = spawn_link(fun() -> process_top_loop(PassedInfo, ChildSymbol) end),
        NewResult =
          case lists:member(monitor, SpawnOpts) of
            true -> {P, make_ref()};
            false -> P
          end,
        NewEvent = Event#event{special = {new, P}},
        {NewResult, Info#concuerror_info{next_event = NewEvent}}
    end,
  case lists:member(monitor, SpawnOpts) of
    true ->
      {Pid, Ref} = Result,
      Pid ! {start, Module, Name, Args},
      Pid ! {monitor, {Ref, self()}, no_confirm};
    false ->
      Pid = Result,
      Pid ! {start, Module, Name, Args}
  end,
  case lists:member(link, SpawnOpts) of
    true ->
      Pid ! {link, self(), no_confirm},
      self() ! {link, Pid, no_confirm};
    false ->
      ok
  end,
  {Result, NewInfo};
run_built_in(erlang, Send, 2, [Recipient, Message], Info)
  when Send =:= '!'; Send =:= 'send' ->
  run_built_in(erlang, send, 3, [Recipient, Message, []], Info);
run_built_in(erlang, send, 3, [Recipient, Message, _Options],
             #concuerror_info{
                next_event = #event{event_info = EventInfo} = Event
               } = Info) ->
  case EventInfo of
    %% Replaying...
    #builtin_event{result = OldResult} -> {OldResult, Info};
    %% New event...
    undefined ->
      ?debug_flag(?send, {send, Recipient, Message}),
      Pid =
        case is_pid(Recipient) of
          true -> Recipient;
          false ->
            {P, Info} = run_built_in(erlang, whereis, 1, [Recipient], Info),
            P
        end,
      case is_pid(Pid) of
        true ->
          MessageEvent =
            #message_event{
               cause_label = Event#event.label,
               message = #message{data = Message, message_id = make_ref()},
               recipient = Pid},
          NewEvent = Event#event{special = {message, MessageEvent}},
          ?debug_flag(?send, {send, successful}),
          {Message, Info#concuerror_info{next_event = NewEvent}};
        false -> throw({error,badarg})
      end
  end;
run_built_in(erlang, process_flag, 2, [trap_exit, Value],
             #concuerror_info{trap_exit = OldValue} = Info) ->
  ?debug_flag(?trap, {trap_exit_set, Value}),
  {OldValue, Info#concuerror_info{trap_exit = Value}};
run_built_in(erlang, unregister, 1, [Name],
             #concuerror_info{processes = Processes} = Info) ->
  try
    [[Pid]] = ets:match(Processes, ?process_name_pattern(Name)),
    true =
      ets:update_element(Processes, Pid, {?process_name, ?process_name_none}),
    {true, Info}
  catch
    _:_ -> throw({error, badarg})
  end;
run_built_in(erlang, whereis, 1, [Name],
             #concuerror_info{processes = Processes} = Info) ->
  case ets:match(Processes, ?process_name_pattern(Name)) of
    [] ->
      case whereis(Name) =:= undefined of
        true -> {undefined, Info};
        false -> error({system_process_not_wrapped, Name})
      end;
    [[Pid]] -> {Pid, Info}
  end;
run_built_in(ets, new, 2, [Name, Options], Info) ->
  #concuerror_info{
     ets_tables = EtsTables,
     next_event = #event{event_info = EventInfo},
     scheduler = Scheduler
    } = Info,
  Tid =
    case EventInfo of
      %% Replaying...
      #builtin_event{result = OldResult} -> OldResult;
      %% New event...
      undefined ->
        case concuerror_scheduler:ets_new(Scheduler, Name, Options) of
          {error, Reason} -> throw({error, Reason});
          {ok, Reply} -> Reply
        end
    end,
  Heir =
    case proplists:lookup(heir, Options) of
      none -> {heir, none};
      Other -> Other
    end,
  Update = [{?ets_heir, Heir}, {?ets_owner, self()}],
  ets:update_element(EtsTables, Tid, Update),
  ets:delete_all_objects(Tid),
  {Tid, Info};
run_built_in(ets, insert, 2, [Tid, _] = Args, Info) ->
  #concuerror_info{ets_tables = EtsTables} = Info,
  Owner = ets:lookup_element(EtsTables, Tid, ?ets_owner),
  case
    is_pid(Owner) andalso
    (Owner =:= self()
     orelse ets:lookup_element(EtsTables, Tid, ?ets_protection) =:= public)
  of
    true -> ok;
    false -> throw({error, badarg})
  end,
  {erlang:apply(ets, insert, Args), Info};
run_built_in(ets, lookup, 2, [Tid, _] = Args, Info) ->
  #concuerror_info{ets_tables = EtsTables} = Info,
  Owner = ets:lookup_element(EtsTables, Tid, ?ets_owner),
  case
    is_pid(Owner) andalso
    (Owner =:= self()
     orelse ets:lookup_element(EtsTables, Tid, ?ets_protection) =/= private)
  of
    true -> ok;
    false -> throw({error, badarg})
  end,
  {erlang:apply(ets, lookup, Args), Info};
run_built_in(ets, delete, 1, [Tid], Info) ->
  #concuerror_info{ets_tables = EtsTables} = Info,
  Owner = ets:lookup_element(EtsTables, Tid, ?ets_owner),
  case
    Owner =:= self()
  of
    true -> ok;
    false -> throw({error, badarg})
  end,
  Update = [{?ets_owner, none}],
  ets:update_element(EtsTables, Tid, Update),
  ets:delete_all_objects(Tid),
  {true, Info};
run_built_in(ets, give_away, 3, [Tid, Pid, GiftData],
             #concuerror_info{
                next_event = #event{event_info = EventInfo} = Event,
                processes = Processes
               } = Info) ->
  #concuerror_info{ets_tables = EtsTables} = Info,
  Owner = ets:lookup_element(EtsTables, Tid, ?ets_owner),
  Self = self(),
  case
    is_pid(Pid) andalso Owner =:= Self andalso Pid =/= Self
  of
    true -> ok;
    false -> throw({error, badarg})
  end,
  case ets:lookup(Processes, Pid) of
    [?process_pat_stat(Pid, Status)]
      when Status =/= exiting andalso Status =/= exited -> ok;
    _ -> throw({error, badarg})
  end,
  NewInfo =
    case EventInfo of
      %% Replaying. Keep original Message reference.
      #builtin_event{} -> Info;
      %% New event...
      undefined ->
        MessageEvent =
          #message_event{
             cause_label = Event#event.label,
             message =
               #message{
                  data = {'ETS-TRANSFER', Tid, Self, GiftData},
                  message_id = make_ref()},
             recipient = Pid},
        NewEvent = Event#event{special = {message, MessageEvent}},
        Info#concuerror_info{next_event = NewEvent}
    end,
  Update = [{?ets_owner, Pid}],
  true = ets:update_element(EtsTables, Tid, Update),
  {true, NewInfo};

%% For other built-ins check whether replaying has the same result:
run_built_in(Module, Name, Arity, Args, Info) ->
  #concuerror_info{next_event = #event{event_info = EventInfo}} = Info,
  NewResult = erlang:apply(Module, Name, Args),
  case EventInfo of
    %% Replaying...
    #builtin_event{result = OldResult} ->
      case OldResult =:= NewResult of
        true  -> {OldResult, Info};
        false ->
          #concuerror_info{logger = Logger} = Info,
          ?log(Logger, ?lwarn,
               "While re-running the program, a call to ~p:~p/~p with"
               " arguments:~n  ~p~nreturned a different result:~n"
               "Earlier result: ~p~n"
               "  Later result: ~p~n"
               "Concuerror cannot explore behaviours that depend on~n"
               "data that may differ on separate runs of the program.",
              [Module, Name, Arity, Args, OldResult, NewResult]),
          error(inconsistent_builtin_behaviour)
      end;
    undefined ->
      {NewResult, Info}
  end.

%%------------------------------------------------------------------------------

handle_receive(PatternFun, Timeout, Location, Info) ->
  %% No distinction between replaying/new as we have to clear the message from
  %% the queue anyway...
  {Match, ReceiveInfo} = has_matching_or_after(PatternFun, Timeout, Info),
  case Match of
    {true, MessageOrAfter} ->
      #concuerror_info{
         next_event = NextEvent,
         trap_exit = Trapping
        } = UpdatedInfo =
        add_location_info(Location, ReceiveInfo),
      ReceiveEvent =
        #receive_event{
           message = MessageOrAfter,
           patterns = PatternFun,
           timeout = Timeout,
           trapping = Trapping},
      {Special, CreateMessage} =
        case MessageOrAfter of
          #message{data = Data, message_id = Id} ->
            {{message_received, Id, PatternFun}, {ok, Data}};
          'after' -> {none, false}
        end,
      Notification =
        NextEvent#event{event_info = ReceiveEvent, special = Special},
      NewInfo = notify(Notification, UpdatedInfo),
      case CreateMessage of
        {ok, D} ->
          ?debug_flag(?receive_, {deliver, D}),
          self() ! D;
        false -> ok
      end,
      {skip_timeout, set_status(NewInfo, running)};
    false ->
      WaitingInfo = set_status(ReceiveInfo, waiting),
      NewInfo = notify({blocked, Location}, WaitingInfo),
      handle_receive(PatternFun, Timeout, Location, NewInfo)
  end.

has_matching_or_after(PatternFun, Timeout,
                      #concuerror_info{messages_new = NewMessages,
                                       messages_old = OldMessages} = Info) ->
  ?debug_flag(?receive_, {matching_or_after, [NewMessages, OldMessages]}),
  {Result, NewOldMessages} =
    fold_with_patterns(PatternFun, NewMessages, OldMessages),
  case Result =:= false of
    false ->
      {Result,
       Info#concuerror_info{
         messages_new = NewOldMessages,
         messages_old = queue:new()
        }
      };
    true ->
      case Timeout =/= infinity of
        true ->
          {{true, 'after'},
           Info#concuerror_info{
             messages_new = NewOldMessages,
             messages_old = queue:new()
            }
          };
        false ->
          {false,
           Info#concuerror_info{
             messages_new = queue:new(),
             messages_old = NewOldMessages}
          }
      end
  end.

fold_with_patterns(PatternFun, NewMessages, OldMessages) ->
  {Value, NewNewMessages} = queue:out(NewMessages),
  ?debug_flag(?receive_, {inspect, Value}),
  case Value of
    {value, #message{data = Data} = Message} ->
      case PatternFun(Data) of
        true  -> {{true, Message}, queue:join(OldMessages, NewNewMessages)};
        false ->
          NewOldMessages = queue:in(Message, OldMessages),
          fold_with_patterns(PatternFun, NewNewMessages, NewOldMessages)
      end;
    empty ->
      {false, OldMessages}
  end.

%%------------------------------------------------------------------------------

notify(Notification, #concuerror_info{scheduler = Scheduler} = Info) ->
  Scheduler ! Notification,
  process_loop(Info).

process_top_loop(#concuerror_info{processes = Processes} = Info, Symbolic) ->
  true = ets:insert(Processes, ?new_process(self(), Symbolic)),
  ?debug_flag(?wait, {top_waiting, self()}),
  receive
    {start, Module, Name, Args} ->
      ?debug_flag(?wait, {start, Module, Name, Args}),
      Running = set_status(Info, running),
      %% Wait for 1st event (= 'run') signal, accepting messages,
      %% links and monitors in the meantime.
      StartInfo = process_loop(Running),
      %% It is ok for this load to fail
      concuerror_loader:load_if_needed(Module),
      put(concuerror_info, StartInfo),
      try
        erlang:apply(Module, Name, Args),
        exit(normal)
      catch
        Class:Reason ->
          case get(concuerror_info) of
            #concuerror_info{escaped_pdict = Escaped} = EndInfo ->
              erase(),
              [put(K,V) || {K,V} <- Escaped],
              Stacktrace = fix_stacktrace(EndInfo),
              ?debug_flag(?exit, {exit, self(), Class, Reason, Stacktrace}),
              NewReason =
                case Class of
                  throw -> {{nocatch, Reason}, Stacktrace};
                  error -> {Reason, Stacktrace};
                  exit  -> Reason
                end,
              exiting(NewReason, Stacktrace, EndInfo);
            _ -> exit({process_crashed, Class, Reason})
          end
      end
  end.

process_loop(Info) ->
  ?debug_flag(?wait, {waiting, self()}),
  receive
    #event{event_info = EventInfo} = Event ->
      Status = Info#concuerror_info.status,
      case Status =:= exited of
        true ->
          notify(exited, Info);
        false ->
          NewInfo = Info#concuerror_info{next_event = Event},
          case EventInfo of
            undefined ->
              ?debug_flag(?wait, {waiting, exploring}),
              NewInfo;
            _OtherReplay ->
              ?debug_flag(?wait, {waiting, replaying}),
              NewInfo
          end
      end;
    {exit_signal, #message{data = {'EXIT', _From, Reason}} = Message} ->
      Scheduler = Info#concuerror_info.scheduler,
      Trapping = Info#concuerror_info.trap_exit,
      case is_active(Info) of
        true ->
          %% XXX: Verify that this is the correct behaviour
          %% NewInfo =
          %%   Info#concuerror_info{
          %%     links = ordsets:del_element(From, Info#concuerror_info.links)
          %%    },
          case Reason =:= kill of
            true ->
              ?debug_flag(?wait, {waiting, kill_signal}),
              Scheduler ! {trapping, Trapping},
              exiting(killed, [], Info);
            false ->
              case Trapping of
                true ->
                  ?debug_flag(?trap, {waiting, signal_trapped}),
                  self() ! {message, Message},
                  process_loop(Info);
                false ->
                  Scheduler ! {trapping, Trapping},
                  case Reason =:= normal of
                    true ->
                      ?debug_flag(?wait, {waiting, normal_signal_ignored}),
                      process_loop(Info);
                    false ->
                      ?debug_flag(?wait, {waiting, exiting_signal}),
                      exiting(Reason, [], Info)
                  end
              end
          end;
        false ->
          Scheduler ! {trapping, Trapping},
          process_loop(Info)
      end;
    {link, Pid, Confirm} ->
      ?debug_flag(?wait, {waiting, got_link}),
      NewInfo =
        case is_active(Info) of
          true ->
            case Confirm =:= confirm of
              true -> Pid ! success;
              false -> ok
            end,
            Old = Info#concuerror_info.links,
            Info#concuerror_info{links = ordsets:add_element(Pid, Old)};
          false ->
            Pid ! failed,
            Info
        end,
      process_loop(NewInfo);
    {message, Message} ->
      ?debug_flag(?wait, {waiting, got_message}),
      Scheduler = Info#concuerror_info.scheduler,
      Trapping = Info#concuerror_info.trap_exit,
      Scheduler ! {trapping, Trapping},
      case is_active(Info) of
        true ->
          ?debug_flag(?receive_, {message_enqueued, Message}),
          Old = Info#concuerror_info.messages_new,
          NewInfo =
            Info#concuerror_info{
              messages_new = queue:in(Message, Old)
             },
          process_loop(NewInfo);
        false ->
          ?debug_flag(?receive_, {message_ignored, Info#concuerror_info.status}),
          process_loop(Info)
      end;
    {monitor, {_Ref, Pid} = Monitor, Confirm} ->
      ?debug_flag(?wait, {waiting, got_monitor}),
      NewInfo =
        case is_active(Info) of
          true ->
            case Confirm =:= confirm of
              true -> Pid ! success;
              false -> ok
            end,
            Old = Info#concuerror_info.monitors,
            Info#concuerror_info{monitors = ordsets:add_element(Monitor, Old)};
          false ->
            Pid ! failed,
            Info
        end,
      process_loop(NewInfo);
    reset ->
      ?debug_flag(?wait, {waiting, reset}),
      NewInfo = #concuerror_info{processes = Processes} =
        init_concuerror_info(Info),
      erase(),
      Symbol = ets:lookup_element(Processes, self(), ?process_symbolic),
      erlang:hibernate(concuerror_callback, process_top_loop, [NewInfo, Symbol]);
    deadlock_poll ->
      Info
    %% {system, #event{actor = {_, Recipient}, event_info = EventInfo} = Event} ->
    %%   #message_event{message = Message, type = Type} = EventInfo,
    %%   #message{data = Data} = Message,
    %%   Recipient ! Data,
    %%   receive
    %%     ReplyData ->
    %%       ReplyMessage = #message{data = ReplyData, message_id = make_ref()},
    %%         MessageEvent =
    %%           #message_event{
    %%              cause_label = Label,
    %%              message = Message,
    %%              recipient = P},
    %%         add_message(MessageEvent, Acc)
  end.

%%------------------------------------------------------------------------------

exiting(Reason, Stacktrace, Info) ->
  %% XXX: The ordering of the following events has to be verified (e.g. R16B03):
  %% XXX:  - process marked as exiting, new messages are not delivered
  %% XXX:  - cancel timers
  %% XXX:  - transfer ets ownership and send message or delete table
  %% XXX:  - unregister name
  %% XXX:  - send link signals
  %% XXX:  - send monitor messages
  ?debug_flag(?exit, {going_to_exit, Reason}),
  LocatedInfo = #concuerror_info{next_event = Event} =
    add_location_info(exit, set_status(Info, exiting)),
  Notification =
    Event#event{
      event_info =
        #exit_event{
           reason = Reason,
           stacktrace = Stacktrace
          }
     },
  ExitInfo = add_location_info(exit, notify(Notification, LocatedInfo)),
  exiting_side_effects(ExitInfo#concuerror_info{exit_reason = Reason}).

exiting_side_effects(Info) ->
  FunFold = fun(Fun, Acc) -> Fun(Acc) end,
  FunList =
    [fun ets_ownership_exiting_events/1,
     fun registration_exiting_events/1,
     fun links_exiting_events/1,
     fun monitors_exiting_events/1],
  FinalInfo = #concuerror_info{next_event = Event} =
    lists:foldl(FunFold, Info, FunList),
  self() ! Event,
  process_loop(set_status(FinalInfo, exited)).

ets_ownership_exiting_events(Info) ->
  %% XXX:  - transfer ets ownership and send message or delete table
  %% XXX: Mention that order of deallocation/transfer is not monitored.
  #concuerror_info{ets_tables = EtsTables} = Info,
  case ets:match(EtsTables, ?ets_owner_to_tid_heir_pattern(self())) of
    [] -> Info;
    Tables ->
      Fold =
        fun([Tid, HeirSpec], InfoIn) ->
            MFArgs =
              case HeirSpec of
                {heir, none} ->
                  ?debug_flag(?heir, no_heir),
                  [ets, delete, [Tid]];
                {heir, Pid, Data} ->
                  ?debug_flag(?heir, {using_heir, Tid, HeirSpec}),
                  [ets, give_away, [Tid, Pid, Data]]
              end,
            case instrumented(call, MFArgs, exit, InfoIn) of
              {{didit, true}, NewInfo} -> NewInfo;
              _ ->
                ?debug_flag(?heir, {problematic_heir, Tid, HeirSpec}),
                {{didit, true}, NewInfo} =
                  instrumented(call, [ets, delete, [Tid]], exit, InfoIn),
                NewInfo
            end
        end,
      lists:foldl(Fold, Info, Tables)
  end.

registration_exiting_events(Info) ->
  #concuerror_info{processes = Processes} = Info,
  Name = ets:lookup_element(Processes, self(), ?process_name),
  case Name =:= ?process_name_none of
    true -> Info;
    false ->
      MFArgs = [erlang, unregister, [Name]],
      {{didit, true}, NewInfo} =
        instrumented(call, MFArgs, exit, Info),
      NewInfo
  end.

links_exiting_events(Info) ->
  #concuerror_info{links = Links} = Info,
  case Links =:= [] of
    true -> Info;
    false ->
      #concuerror_info{exit_reason = Reason} = Info,
      Fold =
        fun(Link, InfoIn) ->
            MFArgs = [erlang, exit, [Link, Reason]],
            {{didit, true}, NewInfo} =
              instrumented(call, MFArgs, exit, InfoIn),
            NewInfo
        end,
      lists:foldl(Fold, Info, Links)
  end.

monitors_exiting_events(Info) ->
  #concuerror_info{monitors = Monitors} = Info,
  case Monitors =:= [] of
    true -> Info;
    false ->
      #concuerror_info{exit_reason = Reason} = Info,
      Fold =
        fun({Ref, P}, InfoIn) ->
            MFArgs = [erlang, send, [P, {'DOWN', Ref, process, self(), Reason}]],
            {{didit, true}, NewInfo} =
              instrumented(call, MFArgs, exit, InfoIn),
            NewInfo
        end,
      lists:foldl(Fold, Info, Monitors)
  end.

%%------------------------------------------------------------------------------

init_concuerror_info(Info) ->
  #concuerror_info{
     'after-timeout' = AfterTimeout,
     ets_tables = EtsTables,
     logger = Logger,
     processes = Processes,
     scheduler = Scheduler
    } = Info,
  #concuerror_info{
     'after-timeout' = AfterTimeout,
     ets_tables = EtsTables,
     logger = Logger,
     processes = Processes,
     scheduler = Scheduler
    }.

%% reset_stack(#concuerror_info{stack = Stack} = Info) ->
%%   {Stack, Info#concuerror_info{stack = []}}.

%% append_stack(Value, #concuerror_info{stack = Stack} = Info) ->
%%   Info#concuerror_info{stack = [Value|Stack]}.

%%------------------------------------------------------------------------------

add_location_info(Location, #concuerror_info{next_event = Event} = Info) ->
  Info#concuerror_info{next_event = Event#event{location = Location}}.

set_status(#concuerror_info{processes = Processes} = Info, Status) ->
  true = ets:update_element(Processes, self(), {?process_status, Status}),
  Info#concuerror_info{status = Status}.

is_active(#concuerror_info{status = Status}) ->
  (Status =:= running) orelse (Status =:= waiting).

fix_stacktrace(#concuerror_info{stacktop = Top}) ->
  RemoveSelf = lists:keydelete(?MODULE, 1, erlang:get_stacktrace()),
  case lists:keyfind(concuerror_inspect, 1, RemoveSelf) of
    false -> RemoveSelf;
    _ ->
      RemoveInspect = lists:keydelete(concuerror_inspect, 1, RemoveSelf),
      [Top|RemoveInspect]
  end.