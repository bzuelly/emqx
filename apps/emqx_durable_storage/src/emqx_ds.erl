%%--------------------------------------------------------------------
%% Copyright (c) 2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------
-module(emqx_ds).

-include_lib("stdlib/include/ms_transform.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

%% API:
-export([ensure_shard/2]).
%%   Messages:
-export([message_store/2, message_store/1, message_stats/0]).
%%   Iterator:
-export([iterator_update/2, iterator_next/1, iterator_stats/0]).
%%   Session:
-export([
    session_open/1,
    session_drop/1,
    session_suspend/1,
    session_add_iterator/2,
    session_get_iterator_id/2,
    session_del_iterator/2,
    session_stats/0
]).

%% internal exports:
-export([]).

-export_type([
    message_id/0,
    message_stats/0,
    message_store_opts/0,
    session_id/0,
    replay/0,
    replay_id/0,
    iterator_id/0,
    iterator/0,
    shard/0,
    topic/0,
    time/0
]).

-include("emqx_ds_int.hrl").

%%================================================================================
%% Type declarations
%%================================================================================

%% Currently, this is the clientid.  We avoid `emqx_types:clientid()' because that can be
%% an atom, in theory (?).
-type session_id() :: binary().

-type iterator() :: term().

-type iterator_id() :: binary().

%%-type session() :: #session{}.

-type message_store_opts() :: #{}.

-type message_stats() :: #{}.

-type message_id() :: binary().

%% Parsed topic:
-type topic() :: list(binary()).

-type shard() :: binary().

%% Timestamp
%% Earliest possible timestamp is 0.
%% TODO granularity?  Currently, we should always use micro second, as that's the unit we
%% use in emqx_guid.  Otherwise, the iterators won't match the message timestamps.
-type time() :: non_neg_integer().

-type replay_id() :: binary().

-type replay() :: {
    _TopicFilter :: emqx_topic:words(),
    _StartTime :: time()
}.

%%================================================================================
%% API funcions
%%================================================================================

-spec ensure_shard(shard(), emqx_ds_storage_layer:options()) ->
    ok | {error, _Reason}.
ensure_shard(Shard, Options) ->
    case emqx_ds_storage_layer_sup:start_shard(Shard, Options) of
        {ok, _Pid} ->
            ok;
        {error, {already_started, _Pid}} ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

%%--------------------------------------------------------------------------------
%% Message
%%--------------------------------------------------------------------------------
-spec message_store([emqx_types:message()], message_store_opts()) ->
    {ok, [message_id()]} | {error, _}.
message_store(_Msg, _Opts) ->
    %% TODO
    {error, not_implemented}.

-spec message_store([emqx_types:message()]) -> {ok, [message_id()]} | {error, _}.
message_store(Msg) ->
    %% TODO
    message_store(Msg, #{}).

-spec message_stats() -> message_stats().
message_stats() ->
    #{}.

%%--------------------------------------------------------------------------------
%% Session
%%--------------------------------------------------------------------------------

%% @doc Called when a client connects. This function looks up a
%% session or creates a new one if previous one couldn't be found.
%%
%% This function also spawns replay agents for each iterator.
%%
%% Note: session API doesn't handle session takeovers, it's the job of
%% the broker.
-spec session_open(emqx_types:clientid()) -> {_New :: boolean(), session_id()}.
session_open(ClientID) ->
    {atomic, Res} =
        mria:transaction(?DS_SHARD, fun() ->
            case mnesia:read(?SESSION_TAB, ClientID, write) of
                [#session{}] ->
                    {false, ClientID};
                [] ->
                    Session = #session{id = ClientID},
                    mnesia:write(?SESSION_TAB, Session, write),
                    {true, ClientID}
            end
        end),
    Res.

%% @doc Called when a client reconnects with `clean session=true' or
%% during session GC
-spec session_drop(emqx_types:clientid()) -> ok.
session_drop(ClientID) ->
    {atomic, ok} = mria:transaction(
        ?DS_SHARD,
        fun() ->
            %% TODO: ensure all iterators from this clientid are closed?
            mnesia:delete({?SESSION_TAB, ClientID})
        end
    ),
    ok.

%% @doc Called when a client disconnects. This function terminates all
%% active processes related to the session.
-spec session_suspend(session_id()) -> ok | {error, session_not_found}.
session_suspend(_SessionId) ->
    %% TODO
    ok.

%% @doc Called when a client subscribes to a topic. Idempotent.
-spec session_add_iterator(session_id(), emqx_topic:words()) ->
    {ok, iterator_id(), time(), _IsNew :: boolean()}.
session_add_iterator(DSSessionId, TopicFilter) ->
    IteratorRefId = {DSSessionId, TopicFilter},
    {atomic, Res} =
        mria:transaction(?DS_SHARD, fun() ->
            case mnesia:read(?ITERATOR_REF_TAB, IteratorRefId, write) of
                [] ->
                    {IteratorId, StartMS} = new_iterator_id(DSSessionId),
                    IteratorRef = #iterator_ref{
                        ref_id = IteratorRefId,
                        it_id = IteratorId,
                        start_time = StartMS
                    },
                    ok = mnesia:write(?ITERATOR_REF_TAB, IteratorRef, write),
                    ?tp(
                        ds_session_subscription_added,
                        #{iterator_id => IteratorId, session_id => DSSessionId}
                    ),
                    IsNew = true,
                    {ok, IteratorId, StartMS, IsNew};
                [#iterator_ref{it_id = IteratorId, start_time = StartMS}] ->
                    ?tp(
                        ds_session_subscription_present,
                        #{iterator_id => IteratorId, session_id => DSSessionId}
                    ),
                    IsNew = false,
                    {ok, IteratorId, StartMS, IsNew}
            end
        end),
    Res.

-spec session_get_iterator_id(session_id(), emqx_topic:words()) ->
    {ok, iterator_id()} | {error, not_found}.
session_get_iterator_id(DSSessionId, TopicFilter) ->
    IteratorRefId = {DSSessionId, TopicFilter},
    case mnesia:dirty_read(?ITERATOR_REF_TAB, IteratorRefId) of
        [] ->
            {error, not_found};
        [#iterator_ref{it_id = IteratorId}] ->
            {ok, IteratorId}
    end.

%% @doc Called when a client unsubscribes from a topic.
-spec session_del_iterator(session_id(), emqx_topic:words()) -> ok.
session_del_iterator(DSSessionId, TopicFilter) ->
    IteratorRefId = {DSSessionId, TopicFilter},
    {atomic, ok} =
        mria:transaction(?DS_SHARD, fun() ->
            mnesia:delete(?ITERATOR_REF_TAB, IteratorRefId, write)
        end),
    ok.

-spec session_stats() -> #{}.
session_stats() ->
    #{}.

%%--------------------------------------------------------------------------------
%% Iterator (pull API)
%%--------------------------------------------------------------------------------

%% @doc Called when a client acks a message
-spec iterator_update(iterator_id(), iterator()) -> ok.
iterator_update(_IterId, _Iter) ->
    %% TODO
    ok.

%% @doc Called when a client acks a message
-spec iterator_next(iterator()) -> {value, emqx_types:message(), iterator()} | none | {error, _}.
iterator_next(_Iter) ->
    %% TODO
    none.

-spec iterator_stats() -> #{}.
iterator_stats() ->
    #{}.

%%================================================================================
%% Internal functions
%%================================================================================

-spec new_iterator_id(session_id()) -> {iterator_id(), time()}.
new_iterator_id(DSSessionId) ->
    NowMS = erlang:system_time(microsecond),
    IteratorId = <<DSSessionId/binary, (emqx_guid:gen())/binary>>,
    {IteratorId, NowMS}.
