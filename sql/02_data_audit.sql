-- 02_data_audit.sql
--
-- What is wrong with the raw data, and how big each problem is. Every section here
-- matches an entry in the data issues log, which records what was done about it.
-- Most problems are fixed once in 03_clean_layer.sql; the rest can't be fixed in the
-- data and are worked around wherever they matter.
--
-- Read only. Everything comes from ecomrl.raw.


-- ---------------------------------------------------------------------------
-- 1. Orders that aren't real orders
-- ---------------------------------------------------------------------------
-- 01_load_and_checks.sql found 140 orders with no lines on them and orders worth a
-- single cent. Looking at who placed the small ones:

select
  c.email,
  count(*) as orders,
  round(sum(o.net_revenue_usd), 2) as revenue_usd,
  min(date(o.order_ts_utc)) as first_order,
  max(date(o.order_ts_utc)) as last_order
from `ecomrl.raw.orders` o
join `ecomrl.raw.customers` c on c.customer_id = o.customer_id
where o.net_revenue_usd < 15
group by c.email
order by orders desc;

-- Result: 13 accounts, every one on tandf-test.com: qa.test0 to qa.test9, one
-- qa.test3+books, webteam.checkout and staff.order. 140 orders between them, spread
-- from October 2022 to September 2025. These are staff and QA checks of the checkout,
-- not customers.


-- Does the staff domain catch exactly those orders and nothing else?

select
  countif(c.email like '%@tandf-test.com') as staff_orders,
  round(sum(if(c.email like '%@tandf-test.com', o.net_revenue_usd, 0)), 2) as staff_order_value,
  countif(c.email like '%@tandf-test.com' and i.order_id is not null) as staff_orders_with_lines,
  countif(c.email not like '%@tandf-test.com' and i.order_id is null) as real_orders_with_no_lines,
  countif(c.email not like '%@tandf-test.com' and o.net_revenue_usd < 15) as real_orders_under_15
from `ecomrl.raw.orders` o
join `ecomrl.raw.customers` c on c.customer_id = o.customer_id
left join (select distinct order_id from `ecomrl.raw.order_items`) i on i.order_id = o.order_id;

-- Result: 140 staff orders worth $634.41. None of them has order lines, every real
-- order does, and no real order is under $15. So the domain is a clean rule: dropping
-- tandf-test.com accounts drops exactly these 140 orders and nothing else.


-- The test orders also show up in the affiliate network and in GA4.

select
  (select count(*) from `ecomrl.raw.affiliates` where starts_with(order_id, 'T')) as affiliate_transactions,
  (select round(sum(if(status != 'reversed', commission_usd, 0)), 2)
     from `ecomrl.raw.affiliates` where starts_with(order_id, 'T')) as commission_still_owed,
  (select round(sum(if(status = 'reversed', commission_usd, 0)), 2)
     from `ecomrl.raw.affiliates` where starts_with(order_id, 'T')) as commission_reversed,
  (select count(distinct ecommerce.transaction_id) from `ecomrl.raw.events`
     where event_name = 'purchase' and starts_with(ecommerce.transaction_id, 'T')) as orders_tracked_in_ga4,
  (select count(*) from `ecomrl.raw.events`
     where event_name = 'purchase' and starts_with(ecommerce.transaction_id, 'T')) as ga4_purchase_events;

-- Result: 25 affiliate transactions sit on staff orders, $6.88 of commission still
-- owed and $1.00 reversed. GA4 tracked 42 of the staff orders, with 43 purchase events.
-- Both drop out once the orders are dropped.


-- ---------------------------------------------------------------------------
-- 2. The same person with two accounts
-- ---------------------------------------------------------------------------
-- Matching on a cleaned up version of the email address, three ways:
--   strict       lower case, plus tag removed (name+books@ becomes name@)
--   gmail only   as strict, and dots removed on gmail.com addresses
--   all dots     as strict, and dots removed on every domain
-- Gmail ignores dots in the part before the @, so on Gmail two addresses that differ
-- only by dots are one inbox. Other providers treat the dot as part of the address.

with keyed as (
  select
    email like '%@tandf-test.com' as is_staff,
    concat(lower(regexp_replace(split(email, '@')[offset(0)], r'\+.*$', '')), '@',
           lower(split(email, '@')[offset(1)])) as key_strict,
    concat(
      case
        when lower(split(email, '@')[offset(1)]) = 'gmail.com'
          then replace(lower(regexp_replace(split(email, '@')[offset(0)], r'\+.*$', '')), '.', '')
        else lower(regexp_replace(split(email, '@')[offset(0)], r'\+.*$', ''))
      end,
      '@', lower(split(email, '@')[offset(1)])) as key_gmail_only,
    concat(replace(lower(regexp_replace(split(email, '@')[offset(0)], r'\+.*$', '')), '.', ''), '@',
           lower(split(email, '@')[offset(1)])) as key_all_dots
  from `ecomrl.raw.customers`
)
select
  'all accounts' as accounts_in_scope,
  count(*) as accounts,
  count(*) - count(distinct key_strict) as duplicates_strict,
  count(*) - count(distinct key_gmail_only) as duplicates_gmail_only,
  count(*) - count(distinct key_all_dots) as duplicates_all_dots
from keyed
union all
select
  'staff accounts', count(*),
  count(*) - count(distinct key_strict),
  count(*) - count(distinct key_gmail_only),
  count(*) - count(distinct key_all_dots)
from keyed
where is_staff
union all
select
  'customer accounts', count(*),
  count(*) - count(distinct key_strict),
  count(*) - count(distinct key_gmail_only),
  count(*) - count(distinct key_all_dots)
from keyed
where not is_staff;

-- Result:
--                        accounts   strict   gmail only   all dots
--   all accounts           58,432      296          319        420
--   staff accounts             13        1            1          1
--   customer accounts      58,419      295          318        419
-- One pair is two staff accounts (qa.test3 and qa.test3+books), which is why the
-- figures for customers are one lower.


-- What separates the two addresses in each pair, on customer accounts.

with keyed as (
  select
    customer_id,
    email,
    lower(split(email, '@')[offset(1)]) = 'gmail.com' as is_gmail,
    concat(replace(lower(regexp_replace(split(email, '@')[offset(0)], r'\+.*$', '')), '.', ''), '@',
           lower(split(email, '@')[offset(1)])) as key_all_dots
  from `ecomrl.raw.customers`
  where email not like '%@tandf-test.com'
),
pairs as (
  select key_all_dots, min(email) as email_a, max(email) as email_b, logical_or(is_gmail) as is_gmail
  from keyed
  group by key_all_dots
  having count(*) = 2
)
select
  case
    when lower(email_a) = lower(email_b) then 'capitals only'
    when strpos(email_a, '+') > 0 or strpos(email_b, '+') > 0 then 'plus tag'
    else 'dots only'
  end as difference,
  if(is_gmail, 'gmail.com', 'other domains') as domain_type,
  count(*) as pairs
from pairs
group by difference, domain_type
order by difference, domain_type;

-- Result: all 419 pairs are two accounts, never three.
--   capitals only   gmail.com 20    other domains 124
--   plus tag        gmail.com 26    other domains 125
--   dots only       gmail.com 23    other domains 101
-- The gmail only rule catches the first two kinds everywhere and the dots on Gmail,
-- 318 pairs. It leaves the 101 dot-only pairs on other domains apart.


-- The pairs only the all dots rule would merge: dot-only differences off Gmail. Do the
-- two accounts look like the same person, and how much did they buy?

with keyed as (
  select
    c.customer_id,
    c.market,
    c.country,
    c.signup_date,
    concat(
      case
        when lower(split(c.email, '@')[offset(1)]) = 'gmail.com'
          then replace(lower(regexp_replace(split(c.email, '@')[offset(0)], r'\+.*$', '')), '.', '')
        else lower(regexp_replace(split(c.email, '@')[offset(0)], r'\+.*$', ''))
      end,
      '@', lower(split(c.email, '@')[offset(1)])) as key_gmail_only,
    concat(replace(lower(regexp_replace(split(c.email, '@')[offset(0)], r'\+.*$', '')), '.', ''), '@',
           lower(split(c.email, '@')[offset(1)])) as key_all_dots
  from `ecomrl.raw.customers` c
  where c.email not like '%@tandf-test.com'
),
extra_pairs as (
  select key_all_dots
  from keyed
  group by key_all_dots
  having count(*) = 2 and count(distinct key_gmail_only) = 2
),
pair_detail as (
  select
    k.key_all_dots,
    count(distinct k.market) as markets,
    count(distinct k.country) as countries,
    date_diff(date(max(k.signup_date)), date(min(k.signup_date)), day) as days_between_signups
  from keyed k
  join extra_pairs e on e.key_all_dots = k.key_all_dots
  group by k.key_all_dots
)
select
  (select count(*) from pair_detail) as pairs,
  (select countif(markets = 1 and countries = 1) from pair_detail) as same_market_and_country,
  (select countif(days_between_signups > 0) from pair_detail) as signed_up_on_different_days,
  (select count(*) from `ecomrl.raw.orders` o
     join keyed k on k.customer_id = o.customer_id
     join extra_pairs e on e.key_all_dots = k.key_all_dots) as orders_on_these_accounts,
  (select round(sum(o.net_revenue_usd), 2) from `ecomrl.raw.orders` o
     join keyed k on k.customer_id = o.customer_id
     join extra_pairs e on e.key_all_dots = k.key_all_dots) as revenue_before_refunds_usd;

-- Result: 101 pairs. In every one the two accounts share a market and a country and
-- were opened on different days. Between them they placed 331 orders worth $62,390.00.
-- So many of them are probably the same person, but on these providers an address with
-- and without dots can belong to two people, so nothing in the address proves it.


-- Does the choice of rule change the repeat rate? Repeat rate here is the share of
-- customers who ordered again within twelve months of their first order, counted only
-- on customers whose first order was on or before 30 September 2024, so everyone has
-- had a full twelve months.

with accounts as (
  select
    customer_id,
    concat(
      case
        when lower(split(email, '@')[offset(1)]) = 'gmail.com'
          then replace(lower(regexp_replace(split(email, '@')[offset(0)], r'\+.*$', '')), '.', '')
        else lower(regexp_replace(split(email, '@')[offset(0)], r'\+.*$', ''))
      end,
      '@', lower(split(email, '@')[offset(1)])) as key_gmail_only,
    concat(replace(lower(regexp_replace(split(email, '@')[offset(0)], r'\+.*$', '')), '.', ''), '@',
           lower(split(email, '@')[offset(1)])) as key_all_dots
  from `ecomrl.raw.customers`
  where email not like '%@tandf-test.com'
),
orders_by_rule as (
  select 'dots removed on gmail.com only' as matching_rule, a.key_gmail_only as person, o.order_ts_utc
  from `ecomrl.raw.orders` o
  join accounts a on a.customer_id = o.customer_id
  union all
  select 'dots removed everywhere', a.key_all_dots, o.order_ts_utc
  from `ecomrl.raw.orders` o
  join accounts a on a.customer_id = o.customer_id
),
with_first as (
  select
    matching_rule,
    person,
    order_ts_utc,
    min(order_ts_utc) over (partition by matching_rule, person) as first_order_ts
  from orders_by_rule
),
per_person as (
  select
    matching_rule,
    person,
    min(first_order_ts) as first_order_ts,
    count(*) as orders,
    countif(order_ts_utc < timestamp_add(first_order_ts, interval 365 day)) as orders_first_12m
  from with_first
  group by matching_rule, person
)
select
  matching_rule,
  count(*) as people,
  countif(date(first_order_ts) <= date '2024-09-30') as people_with_12_months,
  countif(date(first_order_ts) <= date '2024-09-30' and orders_first_12m > 1) as ordered_again_within_12m,
  round(100 * countif(date(first_order_ts) <= date '2024-09-30' and orders_first_12m > 1)
        / countif(date(first_order_ts) <= date '2024-09-30'), 2) as repeat_rate_pct,
  round(100 * countif(orders > 1) / count(*), 2) as ever_ordered_twice_pct
from per_person
group by matching_rule
order by matching_rule desc;

-- Result:
--                                    people   with 12 months   ordered again   repeat
--   dots removed on gmail.com only   58,101           36,569           7,175   19.62%
--   dots removed everywhere          58,000           36,538           7,159   19.59%
-- Ever ordered twice: 22.44 against 22.43 percent. Merging the extra 101 pairs moves
-- nothing that gets reported, so the clean layer uses the gmail only rule, which never
-- merges two addresses that could be different people.


-- ---------------------------------------------------------------------------
-- 3. Channel tags written several ways
-- ---------------------------------------------------------------------------

select
  utm_source,
  utm_medium,
  count(*) as orders,
  count(distinct utm_campaign) as campaigns
from `ecomrl.raw.orders`
group by utm_source, utm_medium
order by utm_source, utm_medium;

-- Result: 20 combinations. Meta arrives as facebook, Facebook, fb and meta_ads, with
-- paid_social and paid-social. Google paid search arrives as google and Google, with
-- cpc and CPC. Content partners come in as studyguide-blog with affiliate and as
-- academic-reads with referral (1,365 orders), so grouping by medium would put one of
-- them in referral.


select
  count(distinct utm_source) as sources_as_written,
  count(distinct lower(utm_source)) as sources_lower_cased,
  count(distinct utm_medium) as mediums_as_written,
  count(distinct lower(utm_medium)) as mediums_lower_cased,
  count(distinct utm_campaign) as campaigns_as_written,
  count(distinct lower(utm_campaign)) as campaigns_lower_cased
from `ecomrl.raw.orders`;

-- Result: 16 sources (14 once lower cased), 10 mediums (9), 24 campaigns (18).


-- Which campaigns arrive in two spellings.

select
  lower(utm_campaign) as campaign_lower_cased,
  string_agg(distinct utm_campaign, ' | ' order by utm_campaign) as spellings,
  count(*) as orders
from `ecomrl.raw.orders`
where utm_campaign is not null
group by campaign_lower_cased
having count(distinct utm_campaign) > 1
order by orders desc;

-- Result: six campaigns, all Meta, each in upper and lower case:
-- rtl_prospecting_us 5,324 orders, rtl_retargeting_us 2,500, rtl_prospecting_uk 2,410,
-- rtl_prospecting_row 2,016, rtl_retargeting_uk 1,143, rtl_retargeting_row 907.
-- Grouping by campaign as written splits each of them in two.


-- ---------------------------------------------------------------------------
-- 4. Ad spend isn't all in dollars
-- ---------------------------------------------------------------------------
-- Each ad account bills in its own currency and the export doesn't convert it.

select
  'google' as platform,
  g.market,
  g.currency,
  round(sum(g.cost), 2) as spend_as_billed,
  round(sum(g.cost * f.rate_to_usd), 2) as spend_usd
from `ecomrl.raw.google_ads` g
join `ecomrl.raw.fx` f on f.rate_date = g.report_date and f.currency = g.currency
group by g.market, g.currency
union all
select
  'meta',
  m.market,
  m.currency,
  round(sum(m.spend), 2),
  round(sum(m.spend * f.rate_to_usd), 2)
from `ecomrl.raw.meta_ads` m
join `ecomrl.raw.fx` f on f.rate_date = m.report_date and f.currency = m.currency
group by m.market, m.currency
order by platform, market;

-- Result:
--   google  ROW  USD  120,972.41  =  $120,972.41
--   google  UK   GBP  119,320.01  =  $153,581.06
--   google  US   USD  334,956.57  =  $334,956.57
--   meta    ROW  EUR  126,672.94  =  $130,343.95
--   meta    UK   GBP  122,858.63  =  $158,176.74
--   meta    US   USD  349,257.95  =  $349,257.95
-- UK spend in dollars is 28.7 percent higher than the number in the export. Taken as
-- dollars without converting, the UK would look cheaper to run than it really is.
-- These totals convert the unrounded daily cost. clean.ad_spend rounds each row to the
-- cent first, so its totals differ from these by under a dollar; whole dollars agree.


-- ---------------------------------------------------------------------------
-- 5. GA4 against the order system
-- ---------------------------------------------------------------------------

select
  count(*) as purchase_events,
  count(distinct ecommerce.transaction_id) as distinct_orders,
  count(*) - count(distinct ecommerce.transaction_id) as extra_events
from `ecomrl.raw.events`
where event_name = 'purchase';

-- Result: 28,464 purchase events for 27,947 orders, so 517 orders were sent twice.


-- When the repeated purchase events happened.

with repeated as (
  select ecommerce.transaction_id as transaction_id, min(event_date) as first_seen
  from `ecomrl.raw.events`
  where event_name = 'purchase'
  group by ecommerce.transaction_id
  having count(*) > 1
)
select substr(first_seen, 1, 6) as year_month, count(*) as orders_sent_twice
from repeated
group by year_month
order by year_month;

-- Result: 324 in January 2025 and 193 in February, none in any other month. Bunched
-- like that, it looks like a tagging fault in those weeks rather than random noise.
-- Anything counted from purchase events then is inflated; counting distinct order ids
-- avoids it.


-- Orders GA4 saw each month against orders the shop took, staff test orders left out
-- on both sides.

with ga4 as (
  select
    substr(event_date, 1, 6) as year_month,
    count(distinct ecommerce.transaction_id) as ga4_orders
  from `ecomrl.raw.events`
  where event_name = 'purchase'
    and not starts_with(ecommerce.transaction_id, 'T')
  group by year_month
),
shop as (
  select format_date('%Y%m', date(o.order_ts_utc)) as year_month, count(*) as shop_orders
  from `ecomrl.raw.orders` o
  join `ecomrl.raw.customers` c on c.customer_id = o.customer_id
  where date(o.order_ts_utc) >= date '2024-10-01'
    and c.email not like '%@tandf-test.com'
  group by year_month
)
select
  s.year_month,
  s.shop_orders,
  g.ga4_orders,
  round(100 * (s.shop_orders - g.ga4_orders) / s.shop_orders, 1) as pct_not_in_ga4
from shop s
left join ga4 g on g.year_month = s.year_month
order by s.year_month;

-- Result: GA4 misses 10.5 to 12.1 percent of orders every month, except May 2025 at
-- 17.2 percent. A steady gap like this usually comes from people declining or blocking
-- tracking, though the data itself doesn't show the cause. May is the odd one out.
--   Oct 10.9, Nov 11.5, Dec 11.8, Jan 12.1, Feb 11.9, Mar 10.5, Apr 11.0,
--   May 17.2, Jun 11.9, Jul 11.7, Aug 11.7, Sep 11.5


-- Days in the GA4 year with no events at all.

select day as day_with_no_events
from unnest(generate_date_array(date '2024-10-01', date '2025-09-30')) as day
where format_date('%Y%m%d', day) not in (select distinct event_date from `ecomrl.raw.events`)
order by day;

-- Result: 13 and 14 May 2025.


select event_date, count(*) as events
from `ecomrl.raw.events`
where event_date between '20250510' and '20250517'
group by event_date
order by event_date;

-- Result: 14,448 events on Monday 12 May, nothing on the 13th or 14th, 15,348 on the
-- 15th. The days either side are normal, so tracking was simply off for two days,
-- about 30,000 events by the look of the days around it. That explains May's bigger
-- gap above.


-- ---------------------------------------------------------------------------
-- 6. GA4 event times inside a session
-- ---------------------------------------------------------------------------
-- How far into its session each event happens.

with events as (
  select
    user_pseudo_id,
    (select p.value.int_value from unnest(event_params) as p where p.key = 'ga_session_id') as session_id,
    event_name,
    event_timestamp
  from `ecomrl.raw.events`
),
starts as (
  select user_pseudo_id, session_id, min(event_timestamp) as start_ts
  from events
  where event_name = 'session_start'
  group by user_pseudo_id, session_id
)
select
  e.event_name,
  count(*) as events,
  min((e.event_timestamp - s.start_ts) / 1000000) as fewest_seconds_in,
  max((e.event_timestamp - s.start_ts) / 1000000) as most_seconds_in,
  count(distinct e.event_timestamp - s.start_ts) as different_timings
from events e
join starts s on s.user_pseudo_id = e.user_pseudo_id and s.session_id = e.session_id
group by e.event_name
order by fewest_seconds_in;

-- Result: every event sits at a fixed number of seconds after its session started.
--   page_view       12, 52, 92 or 132 seconds
--   view_item       40, 95 or 150
--   add_to_cart     150
--   begin_checkout  210
--   purchase        260 (261 for the repeated events)
-- So the timestamps in this export say which session an event belongs to and in what
-- order things happened, but not how long anything took. Time on site and time to
-- checkout can't be measured from it.


-- The purchase event against the time the order system stamped on the same order.

with purchases as (
  select ecommerce.transaction_id as transaction_id, min(event_timestamp) as event_ts
  from `ecomrl.raw.events`
  where event_name = 'purchase'
  group by ecommerce.transaction_id
),
gaps as (
  select timestamp_diff(timestamp_micros(p.event_ts), o.order_ts_utc, second) as seconds_after_order
  from purchases p
  join `ecomrl.raw.orders` o on o.order_id = p.transaction_id
),
with_median as (
  select seconds_after_order, percentile_cont(seconds_after_order, 0.5) over () as median_seconds
  from gaps
)
select
  count(*) as orders,
  countif(seconds_after_order < 0) as event_before_order,
  countif(seconds_after_order between 0 and 59) as event_within_a_minute_after,
  min(seconds_after_order) as earliest,
  max(seconds_after_order) as latest,
  any_value(median_seconds) as median
from with_median;

-- Result: on 26,902 of 27,947 orders the GA4 purchase event is stamped before the
-- order system's time for the same order, by up to 2,980 seconds; the median is 1,480
-- seconds (about 25 minutes) before. The order system's timestamps are the ones to
-- trust. Any comparison of GA4 event times with another system's clock, such as the
-- affiliate network's click times, has to allow for this.


-- ---------------------------------------------------------------------------
-- 7. Who comes back to the site
-- ---------------------------------------------------------------------------

with events as (
  select
    user_pseudo_id,
    user_id,
    event_name,
    device.category as device_category,
    geo.country as country,
    (select p.value.int_value from unnest(event_params) as p where p.key = 'ga_session_id') as session_id
  from `ecomrl.raw.events`
),
browsers as (
  select
    user_pseudo_id,
    logical_or(user_id is not null) as ever_logged_in,
    logical_or(event_name = 'purchase') as ever_bought,
    count(distinct session_id) as sessions,
    count(distinct device_category) as device_types,
    count(distinct country) as countries
  from events
  group by user_pseudo_id
)
select
  ever_logged_in,
  ever_bought,
  count(*) as browsers,
  countif(sessions > 1) as came_back,
  round(100 * countif(sessions > 1) / count(*), 1) as pct_came_back,
  max(sessions) as most_sessions,
  countif(device_types > 1) as seen_on_two_device_types,
  countif(countries > 1) as seen_in_two_countries
from browsers
group by ever_logged_in, ever_bought
order by ever_logged_in, ever_bought;

-- Result:
--   never logged in, never bought   1,205,300 browsers, 841 came back (0.1 percent),
--                                    at most 2 sessions
--   logged in, never bought             3,026 browsers, 1,568 came back (51.8 percent)
--   logged in and bought               25,525 browsers, 14,693 came back (57.6 percent)
-- No browser bought without logging in, and browsers that never logged in almost never
-- came back. So repeat visits in this data come from logged in users only. Journeys
-- can be built for buyers, but there is very little to compare them with among people
-- who didn't buy.
-- A GA4 browser id normally stays on one device, yet 4,959 browsers show two device
-- types across their sessions and 3,570 two countries. Nothing here reads device or
-- country across sessions, so it doesn't affect any figure.


-- Purchases against the account that placed the order.

with purchases as (
  select
    ecommerce.transaction_id as transaction_id,
    min(user_id) as user_id,
    min(device.category) as device_category,
    min(ecommerce.purchase_revenue_in_usd) as revenue_usd
  from `ecomrl.raw.events`
  where event_name = 'purchase'
  group by ecommerce.transaction_id
)
select
  count(*) as orders_in_ga4,
  countif(p.user_id is null) as bought_while_logged_out,
  countif(p.user_id = o.customer_id) as logged_in_as_the_ordering_account,
  countif(p.device_category = o.device) as same_device_as_the_order,
  countif(abs(p.revenue_usd - o.net_revenue_usd) < 0.005) as same_revenue_as_the_order
from purchases p
join `ecomrl.raw.orders` o on o.order_id = p.transaction_id;

-- Result: all 27,947 orders GA4 saw were bought logged in, as the account that placed
-- the order, on the same device type, with the same revenue as the order system before
-- refunds.


-- ---------------------------------------------------------------------------
-- 8. Refunds
-- ---------------------------------------------------------------------------
-- A refund lands days or weeks after the order. The ad platforms count the sale when it
-- happens and never take it back.

select
  count(*) as refunds,
  count(distinct r.order_id) as orders_refunded,
  round(sum(r.refund_amount_usd), 2) as refunded_usd,
  round(100 * count(distinct r.order_id)
        / (select count(*) from `ecomrl.raw.orders` where not starts_with(order_id, 'T')), 2)
    as pct_of_real_orders,
  countif(abs(r.refund_amount_usd - o.net_revenue_usd) < 0.005) as full_refunds,
  countif(r.refund_amount_usd < o.net_revenue_usd - 0.005) as part_refunds,
  countif(starts_with(r.order_id, 'T')) as on_staff_orders,
  min(date_diff(date(r.refund_date), date(o.order_ts_utc), day)) as fewest_days_after_order,
  max(date_diff(date(r.refund_date), date(o.order_ts_utc), day)) as most_days_after_order,
  countif(date(r.refund_date) > date '2025-09-30') as dated_after_30_september_2025
from `ecomrl.raw.refunds` r
join `ecomrl.raw.orders` o on o.order_id = r.order_id;

-- Result: 2,390 refunds, one per order, $388,384.75 in all, on 3.15 percent of real
-- orders. 1,961 refund the whole order and 429 part of it. None is on a staff order.
-- They come 4 to 44 days after the order. 32 are dated after 30 September 2025, the
-- last day of orders.


select
  r.refund_reason,
  count(*) as refunds,
  round(avg(date_diff(date(r.refund_date), date(o.order_ts_utc), day)), 1) as avg_days_after_order,
  round(sum(r.refund_amount_usd), 2) as refunded_usd
from `ecomrl.raw.refunds` r
join `ecomrl.raw.orders` o on o.order_id = r.order_id
group by r.refund_reason
order by refunded_usd desc;

-- Result: damaged in transit 581 refunds $95,082.70, no longer needed 519 $84,498.20,
-- ordered by mistake 515 $84,022.01, wrong edition 418 $65,248.52, late delivery 357
-- $59,533.32. Every reason averages about 24 days after the order.


-- Because refunds take weeks to come through, the newest orders haven't had their
-- refunds yet. Share of each month's orders refunded so far, for the last six months.

select
  format_date('%Y-%m', date(o.order_ts_utc)) as order_month,
  count(*) as orders,
  count(r.order_id) as refunded_so_far,
  round(100 * count(r.order_id) / count(*), 2) as pct_refunded
from `ecomrl.raw.orders` o
left join `ecomrl.raw.refunds` r on r.order_id = o.order_id
where date(o.order_ts_utc) >= date '2025-04-01'
  and not starts_with(o.order_id, 'T')
group by order_month
order by order_month;

-- Result: April to August between 2.86 and 3.62 percent refunded, September 1.88. The
-- latest orders still have refunds to come, so revenue after refunds for the last few
-- weeks is a little high and will come down.


-- ---------------------------------------------------------------------------
-- 9. What the affiliate network is charging for
-- ---------------------------------------------------------------------------
-- Coupon sites and content sites sit in the same table. How long before the order the
-- partner click came, and what the commission was. Staff test orders left out.

with t as (
  select
    a.partner_type,
    a.commission_usd,
    a.order_value_usd,
    timestamp_diff(o.order_ts_utc, a.click_ts, second) as seconds_click_to_order
  from `ecomrl.raw.affiliates` a
  join `ecomrl.raw.orders` o on o.order_id = a.order_id
  where not starts_with(a.order_id, 'T')
),
with_median as (
  select *, percentile_cont(seconds_click_to_order, 0.5) over (partition by partner_type) as median_seconds
  from t
)
select
  partner_type,
  count(*) as transactions,
  round(100 * sum(commission_usd) / sum(order_value_usd), 2) as commission_pct_of_order,
  round(100 * countif(seconds_click_to_order < 600) / count(*), 1) as pct_within_10_minutes,
  any_value(median_seconds) as median_seconds,
  min(seconds_click_to_order) as shortest_seconds,
  max(seconds_click_to_order) as longest_seconds,
  round(sum(commission_usd), 2) as commission_usd
from with_median
group by partner_type
order by partner_type;

-- Result:
--   content  2,751 transactions, 10.0 percent commission, 2.7 percent within 10
--            minutes of the order, median 7,380 seconds (about 2 hours), $46,717.67
--   coupon  14,593 transactions, 8.0 percent commission, 69.8 percent within 10
--            minutes, median 435 seconds (about 7 minutes), $184,417.98
-- Every click is between 20 seconds and just under 4 hours before its order. Content
-- partners send readers who buy later; coupon clicks mostly land minutes before the
-- order.


-- What the network says about each order, against the order itself.

select
  count(*) as transactions,
  count(distinct a.order_id) as orders,
  countif(abs(a.order_value_usd - o.net_revenue_usd) < 0.005) as order_value_matches_revenue_before_refunds,
  countif(a.click_ts > o.order_ts_utc) as click_after_the_order
from `ecomrl.raw.affiliates` a
join `ecomrl.raw.orders` o on o.order_id = a.order_id;

-- Result: 17,369 transactions on 17,369 different orders, so never two on one order.
-- The value the network claims against is the order's revenue before refunds every
-- time, and no click comes after its order.


-- Coupon commission on orders that the order's own tags credit to another channel.
-- A coupon click a few minutes before the order often comes from someone already shopping
-- who went looking for a discount code; 06_reconciliation_attribution.sql section 5 tests
-- this against GA4 session start times. All statuses included.

select
  count(*) as coupon_transactions,
  countif(o.utm_medium != 'affiliate') as on_orders_tagged_to_another_medium,
  round(100 * countif(o.utm_medium != 'affiliate') / count(*), 1) as pct,
  round(sum(if(o.utm_medium != 'affiliate', a.commission_usd, 0)), 2) as commission_on_those_orders
from `ecomrl.raw.affiliates` a
join `ecomrl.raw.orders` o on o.order_id = a.order_id
where a.partner_type = 'coupon'
  and not starts_with(a.order_id, 'T');

-- Result: 10,024 of the 14,593 coupon transactions (68.7 percent) are on orders tagged
-- to another medium, carrying $131,193.03 of commission. How much of that a business
-- should be paying for is worked through in 06_reconciliation_attribution.sql.


-- Commission still owed on orders that were later refunded.

select
  a.status,
  count(*) as transactions,
  round(sum(a.commission_usd), 2) as commission_usd
from `ecomrl.raw.affiliates` a
join `ecomrl.raw.refunds` r on r.order_id = a.order_id
group by a.status
order by a.status;

-- Result: 545 transactions are on refunded orders. The network reversed 15 of them
-- ($222.49). The other 530 are still approved (514, $7,687.06) or pending (16, $216.08):
-- $7,903.14 of commission on sales that were handed back.


-- Does the partner named by the network match the source tag on the order?

select
  a.partner_id,
  a.partner_type,
  o.utm_source,
  count(*) as transactions
from `ecomrl.raw.affiliates` a
join `ecomrl.raw.orders` o on o.order_id = a.order_id
where o.utm_medium = 'affiliate' or o.utm_campaign = 'content_partners'
group by a.partner_id, a.partner_type, o.utm_source
order by a.partner_type, a.partner_id, o.utm_source;

-- Result: no. Each coupon partner's orders are split about evenly between the sources
-- dealfinder and coupons-site, and each content partner's between academic-reads and
-- studyguide-blog. voucherhub, student-codes and phd-toolkit never appear as a source,
-- and coupons-site isn't a partner in the network. The partner type always matches the
-- channel, so coupon against content can be compared, but individual partners can't be
-- tied to their tags.


-- ---------------------------------------------------------------------------
-- 10. Order lines against order totals, to the cent
-- ---------------------------------------------------------------------------

with by_order as (
  select order_id, sum(line_total_usd) as line_value
  from `ecomrl.raw.order_items`
  group by order_id
),
gaps as (
  select
    o.order_id,
    o.item_count,
    o.discount_usd > 0 as had_discount,
    round(o.net_revenue_usd - b.line_value, 2) as gap_usd
  from `ecomrl.raw.orders` o
  join by_order b on b.order_id = o.order_id
)
select
  count(*) as orders,
  countif(gap_usd != 0) as orders_with_a_gap,
  countif(gap_usd = 0.01) as lines_a_cent_under,
  countif(gap_usd = -0.01) as lines_a_cent_over,
  countif(gap_usd = 0.02) as lines_two_cents_under,
  countif(gap_usd = -0.02) as lines_two_cents_over,
  countif(abs(gap_usd) > 0.02) as more_than_two_cents,
  countif(gap_usd != 0 and had_discount) as gaps_on_discounted_orders,
  countif(gap_usd != 0 and item_count > 1) as gaps_on_orders_with_several_lines,
  round(sum(gap_usd), 2) as total_gap_usd
from gaps;

-- Result: 2,512 of 75,918 orders have lines that don't add up exactly to the order.
-- 1,452 are a cent under, 1,052 a cent over, 4 two cents under, 4 two cents over,
-- nothing more. All 2,512 are discounted orders, 2,430 of them with several lines,
-- which points to the discount being rounded line by line. Overall the lines come to
-- $4.00 less than the orders. Order totals are used for revenue; lines only for what
-- was bought.


-- ---------------------------------------------------------------------------
-- 11. Checked and found clean
-- ---------------------------------------------------------------------------

select
  countif(promo_code is not null and discount_usd = 0) as code_with_no_discount,
  countif(promo_code is null and discount_usd > 0) as discount_with_no_code,
  countif(discount_usd > gross_revenue_usd) as discount_above_order_value,
  countif(shipping_charged_usd < 0 or tax_usd < 0) as negative_charges
from `ecomrl.raw.orders`;

-- Result: 0, 0, 0, 0.


-- Every sale code used only while its sale was running, at the sale's discount.

select
  p.promo_name,
  p.discount_pct,
  count(*) as orders,
  countif(date(o.order_ts_utc) not between p.start_date and p.end_date) as used_outside_the_sale,
  round(100 * min(o.discount_usd / o.gross_revenue_usd), 1) as lowest_discount_pct,
  round(100 * max(o.discount_usd / o.gross_revenue_usd), 1) as highest_discount_pct
from `ecomrl.raw.orders` o
join `ecomrl.raw.promos` p on p.promo_code = o.promo_code
group by p.promo_name, p.discount_pct
order by p.promo_name;

-- Result: back_to_college 10,586 orders at 20 percent, black_friday 2,733 at 30,
-- mid_year 3,224 at 15, new_year 2,759 at 15. No code used outside its sale, and every
-- discount is the sale's percentage.


select
  countif(r.refund_amount_usd > o.net_revenue_usd + 0.005) as refund_above_order,
  countif(r.refund_date < o.order_ts_utc) as refund_before_order
from `ecomrl.raw.refunds` r
join `ecomrl.raw.orders` o on o.order_id = r.order_id;

-- Result: 0 and 0.


select
  countif(o.order_ts_utc < c.signup_date) as order_before_signup,
  countif(o.market != c.market) as order_market_not_account_market,
  countif(o.local_currency != case o.market when 'US' then 'USD' when 'UK' then 'GBP' else 'EUR' end)
    as currency_not_the_markets
from `ecomrl.raw.orders` o
join `ecomrl.raw.customers` c on c.customer_id = o.customer_id;

-- Result: 0, 0, 0. No order before its account was opened, every order in its
-- account's market, and every order in its market's currency.
