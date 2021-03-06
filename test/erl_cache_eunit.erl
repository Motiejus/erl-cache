-module(erl_cache_eunit).

-include_lib("eunit/include/eunit.hrl").
-include("erl_cache.hrl").
-include_lib("decorator_pt/include/decorator_pt.hrl").

-ifdef(TEST).
-export([is_error/1]).
-endif.

-define(TEST_CACHE, s1).
-define(TEST_CACHE2, s2).

setup() ->
    Old = application:get_env(erl_cache, cache_servers),
    ok = application:set_env(erl_cache, cache_servers,
                             [{?TEST_CACHE, [{wait_for_refresh, false}]}]),
    ok = erl_cache:start(),
    error_logger:tty(false),
    [fun () -> application:stop(erl_cache) end,
     fun () -> case Old of
                    undefined -> application:unset_env(erl_cache, wait_for_refresh);
                    {ok, Val} -> application:set_env(erl_cache, wait_for_refresh, Val)
                end
        end,
     fun () -> error_logger:tty(true) end
    ].

cleanup(Funs) ->
    lists:foreach(fun (F) -> F() end, Funs).

get_set_evict_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
            {"Start/Stop cache servers", fun start_stop_caches/0},
            {"Catch faulty options in get and set", fun wrong_opts_get_set/0},
            {"Default get, set, evict and stats", fun default_get_set_evict/0},
            {"Get and set with undefined refresh callback", fun refresh_undefined/0},
            {"Get and set with refresh overdue_async_mfa", fun refresh_overdue_async_mfa/0},
            {"Get and set with refresh overdue_sync_closure", fun refresh_overdue_sync_closure/0},
            {"Get and set with error values", fun get_set_error/0},
            {"Refresh with error", fun refresh_with_error/0},
            {"Stats after basic operations", fun stats/0},
            {"Evict interval cache cleanup + correct stats", fun evict_interval/0},
            {"Parse transform basic usage", fun parse_transform/0}
    ]}.

%% Test Sets

start_stop_caches() ->
    ?assertEqual({error, {invalid, cache_name}}, erl_cache:start_cache(?TEST_CACHE, [])),
    ?assertMatch({error, {invalid, _}}, erl_cache:start_cache(?TEST_CACHE2, [{validity, some}])),
    ?assertEqual(ok, erl_cache:start_cache(?TEST_CACHE2, [{evict_interval, 1}])),
    StartedServers = erl_cache:list_cache_servers(),
    ?assertEqual(true, lists:member(?TEST_CACHE, StartedServers)),
    ?assertEqual(true, lists:member(?TEST_CACHE2, StartedServers)),
    ?assertEqual({error, {invalid, cache_name}}, erl_cache:start_cache(?TEST_CACHE2, [])),
    ?assertEqual({error, {invalid, cache_name}}, erl_cache:stop_cache(no_known_cache)),
    ?assertEqual(ok, erl_cache:stop_cache(?TEST_CACHE2)),
    ?assertEqual([?TEST_CACHE], erl_cache:list_cache_servers()).

wrong_opts_get_set() ->
    ?assertEqual({error, {invalid, evict}}, set_in_cache(key, value, [{evict, -1}])),
    ?assertEqual({error, {invalid, validity}},
                 set_in_cache(key, value, [{evict, 0}, {validity, 0}])),
    ?assertEqual({error, {invalid, wait_for_refresh}},
                 get_from_cache(key, [{wait_for_refresh, 1}])),
    ?assertEqual({error, {invalid, wait_until_done}},
                 set_in_cache(key, value, [{wait_until_done, "true"}])),
    ?assertEqual({error, {invalid, refresh_callback}},
                 set_in_cache(key, value, [{refresh_callback, myfun}])),
    ?assertEqual({error, {invalid, refresh_callback}},
                 set_in_cache(key, value, [{refresh_callback, {mymodule, myfun}}])).

default_get_set_evict() ->
    ?assertEqual({error, not_found}, get_from_cache(test_key, [])),
    ?assertEqual(ok, set_in_cache(test_key, <<"test_value">>)),
    ?assertEqual({ok, <<"test_value">>}, get_from_cache(test_key, [], 1)),
    ?assertEqual({ok, <<"test_value">>}, get_from_cache(test_key)),
    ?assertEqual(ok, set_in_cache(test_key2, foo, [{wait_until_done, true}])),
    ?assertEqual({ok, foo}, get_from_cache(test_key2)),
    ?assertEqual(ok, evict_from_cache(test_key)),
    ?assertEqual({error, {invalid, cache_name}}, erl_cache:evict(nowhere, test_key)),
    ?assertEqual({error, not_found}, get_from_cache(test_key, [], 1)),
    ?assertEqual(ok, evict_from_cache(test_key2, [{wait_until_done, true}])),
    ?assertEqual({error, not_found}, get_from_cache(test_key2, [])).

refresh_undefined() ->
    SetOpts = [{refresh_callback, undefined}, {validity, 50}, {evict, 300}],
    ?assertEqual({error, not_found}, get_from_cache(test_key, [], 1)),
    TestValue = os:timestamp(),
    ?assertEqual(ok, set_in_cache(test_key, TestValue, SetOpts, 1)),
    ?assertEqual({ok, TestValue}, get_from_cache(test_key, [], 1)),
    % This get should hit the value in overdue and shouldn't refresh it
    ?assertEqual({ok, TestValue}, get_from_cache(test_key,
                                                 [{refresh_function, {os, timestamp}}], 50)),
    % At this point the value should have been evicted
    ?assertEqual({error, not_found}, get_from_cache(test_key, [], 300)).

refresh_overdue_async_mfa() ->
    SetOpts = [{refresh_callback, {os, timestamp, []}}, {validity, 50}, {evict, 300}],
    ?assertEqual({error, not_found}, get_from_cache(test_key, [], 1)),
    TestValue = os:timestamp(),
    ?assertEqual(ok, set_in_cache(test_key, TestValue, SetOpts, 1)),
    ?assertEqual({ok, TestValue}, get_from_cache(test_key, [], 1)),
    % This get should hit the value in overdue and refresh it
    ?assertMatch({ok, TestValue}, get_from_cache(test_key, [{wait_for_refresh, false}], 50)),
    % The value should have been asynchronously refreshed
    ?assertMatch({ok, T} when is_tuple(T) andalso T/=TestValue,
                 get_from_cache(test_key, [{wait_for_refresh, false}], 10)),
    % At this point the value should have been evicted
    ?assertEqual({error, not_found}, get_from_cache(test_key, [], 400)).

refresh_overdue_sync_closure() ->
    SetOpts = [{refresh_callback, fun() -> os:timestamp() end},
               {validity, 50}, {evict, 300}],
    ?assertEqual({error, not_found}, get_from_cache(test_key, [], 1)),
    TestValue = os:timestamp(),
    ?assertEqual(ok, set_in_cache(test_key, TestValue, SetOpts, 1)),
    ?assertEqual({ok, TestValue}, get_from_cache(test_key, [], 1)),
    % This get should hit the value in overdue and wait for the refresh
    {ok, UpdatedValue} = get_from_cache(test_key, [{wait_for_refresh, true}], 50),
    ?assertMatch(T when is_tuple(T) andalso T/=TestValue, UpdatedValue),
    % Since it has just been refreshed, the updated value should be there
    ?assertMatch({ok, UpdatedValue},
                 get_from_cache(test_key, [{wait_for_refresh, false}], 10)),
    % At this point the value should have been evicted
    ?assertEqual({error, not_found}, get_from_cache(test_key, [], 350)).

get_set_error() ->
    set_in_cache(foo, bar, [{validity, 30}, {evict, 100}]),
    set_in_cache(foo2, error, [{validity, 30}, {evict, 100},
                               {error_validity, 1}, {wait_until_done, true}], 1),
    ?assertEqual({ok, bar}, get_from_cache(foo, [])),
    ?assertEqual({error, not_found}, get_from_cache(foo2, [])),
    set_in_cache(foo3, wrong, [{is_error_callback, {?MODULE, is_error, []}},
                               {error_validity, 1}, {wait_until_done, true}], 1),
    set_in_cache(foo4, error, [{is_error_callback, {?MODULE, is_error, []}},
                               {error_validity, 1}, {wait_until_done, true}], 1),
    ?assertEqual({error, not_found}, get_from_cache(foo3, [])),
    ?assertEqual({ok, error}, get_from_cache(foo4, [])).

is_error(wrong) -> true;
is_error(_) -> false.

refresh_with_error() ->
    set_in_cache(foo, bar, [{validity, 100}, {evict, 300}, {wait_until_done, true},
                            {refresh_callback, fun () -> error end}, {wait_for_refresh, true}]),
    ?assertEqual({ok, bar}, get_from_cache(foo, [])),
    % After 200ms, the value should be overdue. We should be still getting the original value, since
    % the refresh returns an error
    ?assertEqual({ok, bar}, get_from_cache(foo, [], 200)),
    % Since the refresh didn't update the validity, after 400ms the value should have been evicted
    ?assertEqual({error, not_found}, get_from_cache(foo, [], 200)).

stats() ->
    get_from_cache(foo),
    set_in_cache(foo, bar, [{validity, 30}, {evict, 100}]),
    set_in_cache(foo2, bar, [{validity, 1}, {evict, 1}]),
    set_in_cache(foo3, bar, [{validity, 1}, {evict, 1}]),
    get_from_cache(foo, [], 1),
    get_from_cache(foo, [], 1),
    get_from_cache(foo, [], 1),
    get_from_cache(foo, [], 50),
    get_from_cache(foo, [], 1),
    evict_from_cache(foo),
    get_from_cache(foo2),
    timer:sleep(100),
    Stats = stats_from_cache(),
    ?assertEqual({error, {invalid, cache_name}}, erl_cache:get_stats(no_known_cache)),
    ?assertEqual(3, proplists:get_value(set, Stats)),
    ?assertEqual(10, proplists:get_value(total_ops, Stats)),
    ?assertEqual(3, proplists:get_value(hit, Stats)),
    ?assertEqual(2, proplists:get_value(overdue, Stats)),
    ?assertEqual(1, proplists:get_value(miss, Stats)),
    % foo is manually evicted, foo2 and foo3 are not yet evicted despite foo2 miss (evict_interval)
    ?assertEqual(1, proplists:get_value(evict, Stats)),
    ?assertEqual(2, proplists:get_value(entries, Stats)),
    ?assertMatch(N when is_integer(N) andalso N>0, proplists:get_value(memory, Stats)).

evict_interval() ->
    Opts = [{evict_interval, 500}, {validity, 200}, {evict, 0}, {wait_until_done, true}],
    ?assertEqual(ok, erl_cache:start_cache(?TEST_CACHE2, Opts)),
    erl_cache:set(?TEST_CACHE2, foo, bar),
    erl_cache:set(?TEST_CACHE2, foo2, baz, [{validity, 3000}]),
    ?assertEqual({ok, bar}, erl_cache:get(?TEST_CACHE2, foo)),
    ?assertEqual({ok, baz}, erl_cache:get(?TEST_CACHE2, foo2)),
    timer:sleep(500),
    ?assertEqual({error, not_found}, erl_cache:get(?TEST_CACHE2, foo)),
    ?assertEqual({ok, baz}, erl_cache:get(?TEST_CACHE2, foo2)),
    Stats = erl_cache:get_stats(?TEST_CACHE2),
    ?assertEqual(1, proplists:get_value(evict, Stats)),
    ?assertEqual(1, proplists:get_value(entries, Stats)),
    ?assertEqual(7, proplists:get_value(total_ops, Stats)),
    ?assertEqual(ok, erl_cache:stop_cache(?TEST_CACHE2)).

parse_transform() ->
    {Time1, ok} = timer:tc(fun  () -> wait(1000) end),
    {Time2, ok} = timer:tc(fun  () -> wait(1000) end),
    timer:sleep(1000),
    {Time3, ok} = timer:tc(fun  () -> wait(1000) end),
    ?assertMatch(N when N>1000000, Time1),
    ?assertMatch(N when N<1000000, Time2),
    ?assertMatch(N when N>1000000, Time3).

%% Internal functions

set_in_cache(K, V) ->
    apply(erl_cache, set, [?TEST_CACHE, K, V]).
set_in_cache(K, V, Opts) ->
    set_in_cache(K, V, Opts, 0).
set_in_cache(K, V, Opts, 0) ->
    apply(erl_cache, set, [?TEST_CACHE, K, V, Opts]);
set_in_cache(K, V, Opts, SleepAfter) ->
    apply(erl_cache, set, [?TEST_CACHE, K, V, Opts]),
    timer:sleep(SleepAfter).

get_from_cache(K) ->
    apply(erl_cache, get, [?TEST_CACHE, K]).
get_from_cache(K, Opts) ->
    get_from_cache(K, Opts, 0).
get_from_cache(K, Opts, 0) ->
    apply(erl_cache, get, [?TEST_CACHE, K, Opts]);
get_from_cache(K, Opts, SleepBefore) ->
    timer:sleep(SleepBefore),
    apply(erl_cache, get, [?TEST_CACHE, K, Opts]).

evict_from_cache(K) ->
    apply(erl_cache, evict, [?TEST_CACHE, K]).
evict_from_cache(K, Opts) ->
    apply(erl_cache, evict, [?TEST_CACHE, K, Opts]).

stats_from_cache() ->
    apply(erl_cache, get_stats, [?TEST_CACHE]).

?CACHE(?TEST_CACHE, [{validity, 1000}, {evict, 1000}, {wait_until_done, true}, {wait_for_refresh, true}]).
wait(Time) ->
    timer:sleep(Time),
    ok.
