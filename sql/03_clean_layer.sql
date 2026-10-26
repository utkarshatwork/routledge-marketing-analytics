-- 03_clean_layer.sql
--
-- Builds the six tables in ecomrl.clean that every report and analysis reads from:
--
--   channel_map        each source, medium and campaign combination, and its channel
--   customer_accounts  each account, and the person it belongs to
--   customers          one row per person
--   orders             real orders only, with the person, channel, refunds and profit
--   ad_spend           Google and Meta spend in one table, in US dollars
--   sessions           GA4 events rolled up to one row per website session
--
-- Nothing in raw is changed. Each fix is made once, here, so no later query has to
-- remember it. The problems behind the fixes are in the data issues log, and the
-- queries that found them are in 02_data_audit.sql.
--
-- Run from top to bottom. Each table is followed by the checks run on it.


-- ---------------------------------------------------------------------------
-- 1. channel_map
-- ---------------------------------------------------------------------------
-- The same channel turns up spelled several ways: facebook, Facebook, fb and meta_ads,
-- cpc and CPC, paid_social and paid-social. One content partner also tags its links as
-- referral instead of affiliate. So instead of a long CASE copied into every query,
-- the rules sit in one lookup table, built from every combination that appears in
-- orders or in GA4. Orders and sessions then get classified by exactly the same rules.
--
-- Keys are lower cased, and a missing campaign becomes '(none)', so a join on them
-- never quietly drops a row because of a null.

create or replace table `ecomrl.clean.channel_map` as

with combinations as (
  select distinct
    lower(utm_source) as source_key,
    lower(utm_medium) as medium_key,
    lower(coalesce(utm_campaign, '(none)')) as campaign_key
  from `ecomrl.raw.orders`

  union distinct

  select distinct
    lower(coalesce(traffic_source.source, '(none)')),
    lower(coalesce(traffic_source.medium, '(none)')),
    lower(coalesce(traffic_source.name, '(none)'))
  from `ecomrl.raw.events`
  where event_name = 'session_start'
)

select
  source_key,
  medium_key,
  campaign_key,

  -- Paid search and paid social are checked first, because a paid click can carry a
  -- medium that would otherwise look like something else.
  case
    when medium_key in ('cpc', 'shopping') and source_key like 'google%' then
      case
        when campaign_key like '%nonbrand%' then 'google_nonbrand'
        when campaign_key like '%shopping%' then 'google_shopping'
        when campaign_key like '%brand%'    then 'google_brand'
        else 'google_paid_untagged'
      end
    when source_key in ('facebook', 'fb', 'meta_ads') then
      case
        when campaign_key like '%retargeting%' then 'meta_retargeting'
        when campaign_key like '%prospecting%' then 'meta_prospecting'
        else 'meta_untagged'
      end
    when medium_key = 'email' then 'email'
    -- affiliates are recognised by source tag as well as campaign, which is what
    -- catches the content partner traffic that arrives tagged as referral
    when campaign_key = 'coupon_partners'
      or source_key in ('dealfinder', 'coupons-site', 'student-codes', 'voucherhub') then 'affiliate_coupon'
    when campaign_key = 'content_partners'
      or source_key in ('studyguide-blog', 'academic-reads', 'phd-toolkit') then 'affiliate_content'
    when medium_key = 'organic' then 'organic_search'
    when medium_key = 'referral' then 'referral'
    when source_key = '(direct)' or medium_key = '(none)' then 'direct'
    else 'unassigned'
  end as channel,

  -- Only paid channels have ad spend behind them, so this is the split that cost per
  -- customer depends on.
  case
    when medium_key in ('cpc', 'shopping') and source_key like 'google%' then 'paid'
    when source_key in ('facebook', 'fb', 'meta_ads') then 'paid'
    when campaign_key in ('coupon_partners', 'content_partners')
      or source_key in ('dealfinder', 'coupons-site', 'student-codes', 'voucherhub',
                        'studyguide-blog', 'academic-reads', 'phd-toolkit') then 'affiliate'
    when medium_key = 'email' then 'owned'
    else 'organic'
  end as channel_group,

  -- Brand search is people typing the shop's name. Kept as its own flag because paying
  -- for someone who was already looking for us is a different thing from being found.
  campaign_key like '%brand%' and campaign_key not like '%nonbrand%' as is_brand_search,

  case
    when source_key like 'google%' and medium_key in ('cpc', 'shopping') then 'google'
    when source_key in ('facebook', 'fb', 'meta_ads') then 'meta'
    else null
  end as ad_platform

from combinations;


-- Anything left unassigned would mean a new source or medium has appeared that the
-- rules don't cover yet.

select
  countif(channel = 'unassigned') as unassigned_combinations,
  count(distinct channel) as channels,
  count(*) as combinations_mapped
from `ecomrl.clean.channel_map`;

-- Result: 50 combinations, 13 channels, none unassigned.


select channel, channel_group, count(*) as combinations
from `ecomrl.clean.channel_map`
group by channel, channel_group
order by channel;

-- Result: 13 channels in four groups.
--   paid       google_brand 3, google_nonbrand 3, google_shopping 6,
--              google_paid_untagged 2, meta_prospecting 9, meta_retargeting 6,
--              meta_untagged 4
--   affiliate  affiliate_coupon 4, affiliate_content 4
--   owned      email 4
--   organic    organic_search 2, referral 2, direct 1
-- The two untagged buckets are paid clicks whose campaign tag got lost on the way.


-- ---------------------------------------------------------------------------
-- 2. customer_accounts and customers
-- ---------------------------------------------------------------------------
-- Some people hold two accounts: the second address is the first one with a plus tag
-- (name+books@...), in different capitals, or with the dots taken out. Accounts are
-- matched on a key made from the address: lower cased, plus tag removed, and dots
-- removed on gmail.com only. Gmail ignores dots, so two Gmail addresses that differ
-- only by dots are one inbox. Outlook, Yahoo, Proton and the university domains treat
-- dots as part of the address, so those pairs are not merged. 02_data_audit.sql sizes
-- what that choice leaves out.
--
-- Staff and QA accounts on tandf-test.com are dropped before matching.
--
-- person_id is the lowest account id in each group. Every account keeps its own row in
-- customer_accounts, so any order can be traced back to the account that placed it.

create or replace table `ecomrl.clean.customer_accounts` as

with keyed as (
  select
    customer_id,
    email,
    market,
    country,
    marketing_opt_in,
    signup_date,
    concat(
      case
        when lower(split(email, '@')[offset(1)]) = 'gmail.com'
          then replace(lower(regexp_replace(split(email, '@')[offset(0)], r'\+.*$', '')), '.', '')
        else lower(regexp_replace(split(email, '@')[offset(0)], r'\+.*$', ''))
      end,
      '@',
      lower(split(email, '@')[offset(1)])
    ) as email_key
  from `ecomrl.raw.customers`
  where email not like '%@tandf-test.com'
)

select
  customer_id,
  email_key,
  min(customer_id) over (partition by email_key) as person_id,
  email,
  market,
  country,
  marketing_opt_in,
  signup_date
from keyed;


-- One row per person. Where two accounts disagree, market and country come from the
-- earliest account, and the person counts as opted in to marketing email if either
-- account opted in.

create or replace table `ecomrl.clean.customers` as

with per_person as (
  select
    email_key,
    count(*) as accounts_held,
    min(signup_date) as first_signup_date,
    logical_or(marketing_opt_in) as marketing_opt_in
  from `ecomrl.clean.customer_accounts`
  group by email_key
),

earliest_account as (
  select person_id, email_key, market, country
  from (
    select
      person_id, email_key, market, country,
      row_number() over (partition by email_key order by signup_date, customer_id) as account_rank
    from `ecomrl.clean.customer_accounts`
  )
  where account_rank = 1
)

select
  e.person_id,
  e.email_key,
  p.accounts_held,
  p.first_signup_date,
  e.market,
  e.country,
  p.marketing_opt_in
from earliest_account e
join per_person p on p.email_key = e.email_key;


select
  (select count(*) from `ecomrl.raw.customers`) as raw_accounts,
  (select count(*) from `ecomrl.clean.customer_accounts`) as accounts_kept,
  (select count(*) from `ecomrl.clean.customers`) as people,
  (select count(*) from `ecomrl.clean.customer_accounts`)
    - (select count(*) from `ecomrl.clean.customers`) as accounts_merged;

-- Result: 58,432 accounts in raw, 13 staff accounts dropped leaves 58,419, which
-- belong to 58,101 people. 318 accounts were merged into another.


-- How many accounts each person holds. Anyone with three or more would mean the
-- matching key is too loose.

select accounts_held, count(*) as people, countif(marketing_opt_in) as opted_in
from `ecomrl.clean.customers`
group by accounts_held
order by accounts_held;

-- Result: 57,783 people with one account and 318 with two. Nobody has three.
-- 37,183 people are opted in (36,917 plus 266), 64.0 percent.


-- ---------------------------------------------------------------------------
-- 3. orders
-- ---------------------------------------------------------------------------
-- One row per real order with everything later work needs on it: the person rather
-- than the account, the channel, refunds, affiliate commission and gross profit.
--
-- The 140 staff test orders drop out through the join to customer_accounts, which has
-- no staff accounts in it, so the rule that removes them lives in one place.
--
-- Two money columns, and the difference matters:
--   net_revenue_usd               after discount, before refunds (as the order system
--                                 stores it)
--   net_revenue_after_refund_usd  after discount and after refunds. This is the
--                                 revenue figure used in every report
--
-- Gross profit is net revenue after refunds, less the cost of the books, delivery,
-- payment fees and affiliate commission. Tax is not revenue and never enters. Ad spend
-- is not taken off here, because spend belongs to a channel and a day, not to an order.
--
-- Commission the affiliate network reversed has been clawed back, so it is not a cost.
-- Approved and pending commission both are: pending is still owed.

create or replace table `ecomrl.clean.orders` as

with refunds_by_order as (
  select order_id, sum(refund_amount_usd) as refunded_usd
  from `ecomrl.raw.refunds`
  group by order_id
),

commission_by_order as (
  select order_id, sum(if(status != 'reversed', commission_usd, 0)) as commission_usd
  from `ecomrl.raw.affiliates`
  group by order_id
)

select
  o.order_id,
  ca.person_id,
  o.customer_id as account_id,
  o.order_ts_utc,
  date(o.order_ts_utc) as order_date,
  -- weeks start on Monday
  date_trunc(date(o.order_ts_utc), week(monday)) as order_week,
  date_trunc(date(o.order_ts_utc), month) as order_month,
  o.market,

  cm.channel,
  cm.channel_group,
  cm.is_brand_search,
  cm.ad_platform,
  o.utm_campaign as campaign,
  o.device,

  o.gross_revenue_usd,
  o.discount_usd,
  o.net_revenue_usd,
  coalesce(r.refunded_usd, 0) as refunded_usd,
  o.net_revenue_usd - coalesce(r.refunded_usd, 0) as net_revenue_after_refund_usd,

  o.product_cost_usd,
  o.shipping_cost_usd,
  o.payment_fee_usd,
  coalesce(c.commission_usd, 0) as affiliate_commission_usd,

  o.net_revenue_usd
    - coalesce(r.refunded_usd, 0)
    - o.product_cost_usd
    - o.shipping_cost_usd
    - o.payment_fee_usd
    - coalesce(c.commission_usd, 0) as gross_profit_usd,

  o.promo_code,
  o.promo_code is not null as used_promo,
  o.item_count

from `ecomrl.raw.orders` o
join `ecomrl.clean.customer_accounts` ca on ca.customer_id = o.customer_id
join `ecomrl.clean.channel_map` cm
  on cm.source_key = lower(o.utm_source)
 and cm.medium_key = lower(o.utm_medium)
 and cm.campaign_key = lower(coalesce(o.utm_campaign, '(none)'))
left join refunds_by_order r on r.order_id = o.order_id
left join commission_by_order c on c.order_id = o.order_id;


-- Totals against raw: revenue before refunds set against raw less the staff orders,
-- and a count of any order left without a channel.

select
  count(*) as orders,
  countif(channel is null) as orders_with_no_channel,
  round(sum(net_revenue_usd), 2) as revenue_before_refunds_usd,
  round(sum(refunded_usd), 2) as refunded_usd,
  round(sum(net_revenue_after_refund_usd), 2) as net_revenue_usd,
  round(sum(affiliate_commission_usd), 2) as commission_usd,
  round(sum(gross_profit_usd), 2) as gross_profit_usd,
  round(100 * sum(gross_profit_usd) / sum(net_revenue_after_refund_usd), 1) as margin_pct
from `ecomrl.clean.orders`;

-- Result: 75,918 orders, all with a channel.
--   revenue before refunds  $12,296,260.18
--   refunds                    $388,384.75
--   net revenue             $11,907,875.43
--   affiliate commission       $227,336.14
--   gross profit             $7,421,060.08, a 62.3 percent margin on net revenue


select
  (select count(*) from `ecomrl.raw.orders`) as raw_orders,
  (select round(sum(net_revenue_usd), 2) from `ecomrl.raw.orders`) as raw_revenue_before_refunds_usd,
  (select count(*) from `ecomrl.raw.orders` where order_id not in
     (select order_id from `ecomrl.clean.orders`)) as orders_dropped,
  (select round(sum(net_revenue_usd), 2) from `ecomrl.raw.orders` where order_id not in
     (select order_id from `ecomrl.clean.orders`)) as revenue_dropped_usd;

-- Result: 76,058 orders in raw worth $12,296,894.59. The 140 dropped are the staff
-- test orders, $634.41 between them, and raw less that is exactly the $12,296,260.18
-- above.


-- Commission in clean.orders against what the affiliate network reported, and how
-- much of the gap is commission on the staff test orders that were dropped.

select
  round(sum(if(a.status != 'reversed', a.commission_usd, 0)), 2) as network_commission_standing,
  round(sum(if(a.status != 'reversed' and o.order_id is null, a.commission_usd, 0)), 2) as on_dropped_orders,
  countif(a.status != 'reversed' and o.order_id is null) as transactions_on_dropped_orders,
  (select round(sum(affiliate_commission_usd), 2) from `ecomrl.clean.orders`) as commission_in_clean_orders
from `ecomrl.raw.affiliates` a
left join `ecomrl.clean.orders` o on o.order_id = a.order_id;

-- Result: the network shows $227,343.02 still owed. $6.88 of it, on 24 transactions,
-- sits on the dropped staff orders, and $227,343.02 less $6.88 is the $227,336.14 in
-- clean.orders to the cent.


-- The people who held two accounts, and what they bought.

select
  count(distinct o.person_id) as people,
  count(*) as orders,
  round(sum(o.net_revenue_usd), 2) as revenue_before_refunds_usd
from `ecomrl.clean.orders` o
join `ecomrl.clean.customers` c on c.person_id = o.person_id
where c.accounts_held > 1;

-- Result: the 318 people with two accounts placed 1,068 orders worth $207,385.95
-- before refunds. Counted as separate customers, they would have been 318 extra
-- "new" customers.


select
  channel,
  channel_group,
  count(*) as orders,
  round(sum(net_revenue_after_refund_usd), 0) as net_revenue_usd,
  round(sum(gross_profit_usd), 0) as gross_profit_usd
from `ecomrl.clean.orders`
group by channel, channel_group
order by orders desc;

-- Result (orders, net revenue, gross profit):
--   organic_search        12,983   $2,092,535   $1,308,621
--   google_nonbrand       10,751   $1,759,199   $1,100,228
--   meta_prospecting       9,750   $1,336,413     $868,119
--   email                  7,517   $1,250,083     $779,808
--   direct                 7,113   $1,164,598     $723,204
--   google_brand           6,833   $1,106,500     $695,731
--   google_shopping        5,577     $838,683     $531,063
--   affiliate_coupon       4,569     $644,131     $373,702
--   meta_retargeting       4,550     $695,088     $443,647
--   affiliate_content      2,751     $449,752     $239,934
--   referral               2,749     $449,964     $280,232
--   google_paid_untagged     461      $77,225      $48,782
--   meta_untagged            314      $43,703      $27,989
-- affiliate_content has 2,751 orders, the same as the 2,751 content partner
-- transactions the network reported, so the partner tagged as referral is picked up.


-- ---------------------------------------------------------------------------
-- 4. ad_spend
-- ---------------------------------------------------------------------------
-- Google and Meta stacked into one table. Each ad account bills in its own currency
-- (UK in pounds, Meta's Rest of World account in euros), so every row is converted at
-- that day's rate from the finance rate table. Converting a monthly total at an average
-- rate would give a slightly different answer.
--
-- Google reports days in UTC and Meta in Pacific time, and that can't be undone after
-- the fact. Each row carries its week, so the two platforms can be compared by week,
-- where the few hours' difference stops mattering.
--
-- Meta's platform_conversions here is click purchases plus view purchases, as the
-- platform adds them up. Its revenue figure covers click purchases only.

create or replace table `ecomrl.clean.ad_spend` as

select
  'google' as platform,
  g.report_date,
  date_trunc(g.report_date, week(monday)) as report_week,
  g.market,
  g.campaign_name,
  cm.channel,
  g.currency as billing_currency,
  g.cost as spend_local,
  f.rate_to_usd,
  round(g.cost * f.rate_to_usd, 2) as spend_usd,
  g.impressions,
  g.clicks,
  g.conversions as platform_conversions,
  round(g.conversion_value * f.rate_to_usd, 2) as platform_revenue_usd,
  g.reporting_timezone

from `ecomrl.raw.google_ads` g
join `ecomrl.raw.fx` f
  on f.rate_date = g.report_date
 and f.currency = g.currency
-- campaign names in the ad accounts are the same strings the clicks are tagged with,
-- so the channel map classifies spend the same way it classifies orders
left join `ecomrl.clean.channel_map` cm
  on cm.campaign_key = lower(g.campaign_name)
 and cm.source_key = 'google'
 and cm.medium_key = 'cpc'

union all

select
  'meta',
  m.report_date,
  date_trunc(m.report_date, week(monday)),
  m.market,
  m.campaign_name,
  cm.channel,
  m.currency,
  m.spend,
  f.rate_to_usd,
  round(m.spend * f.rate_to_usd, 2),
  m.impressions,
  m.clicks,
  m.purchases_7d_click + m.purchases_1d_view,
  round(m.purchase_value_7d_click * f.rate_to_usd, 2),
  m.reporting_timezone

from `ecomrl.raw.meta_ads` m
join `ecomrl.raw.fx` f
  on f.rate_date = m.report_date
 and f.currency = m.currency
left join `ecomrl.clean.channel_map` cm
  on cm.campaign_key = lower(m.campaign_name)
 and cm.source_key = 'facebook'
 and cm.medium_key = 'paid_social';


select
  platform,
  count(*) as rows_loaded,
  countif(channel is null) as rows_with_no_channel,
  round(sum(spend_usd), 2) as spend_usd,
  round(sum(platform_conversions), 1) as conversions_claimed
from `ecomrl.clean.ad_spend`
group by platform
order by platform;

-- Result: Google 9,864 rows, $609,509.99, 29,086.2 conversions claimed. Meta 19,728
-- rows, $637,778.95, 23,457.3 purchases claimed (clicks and views together). Every row
-- has a channel. $1,247,288.94 in total.


-- What the conversion changes, by billing currency.

select
  billing_currency,
  round(sum(spend_local), 2) as spend_as_billed,
  round(sum(spend_usd), 2) as spend_usd,
  round(100 * (sum(spend_usd) / sum(spend_local) - 1), 1) as pct_higher_in_usd
from `ecomrl.clean.ad_spend`
group by billing_currency
order by billing_currency;

-- Result:
--   EUR  126,672.94 billed  =  $130,343.87, 2.9 percent more in dollars
--   GBP  242,178.64 billed  =  $311,758.14, 28.7 percent more in dollars
--   USD  $805,186.93, unchanged
-- Left in pounds, UK spend would look about 22 percent smaller than it really is.


-- ---------------------------------------------------------------------------
-- 5. sessions
-- ---------------------------------------------------------------------------
-- GA4 exports one row per event with the useful values nested inside. This rolls them
-- up to one row per session, so nothing after this needs UNNEST.
--
-- A GA4 session id is only unique within one browser, so the session key is the
-- browser id and the session id joined together.
--
-- Traffic source is recorded on every event but belongs to the session, so it's taken
-- with min() rather than grouped on. Grouping on it would split a session in two if one
-- event disagreed.
--
-- In January and February 2025 some purchases were sent twice. Taking the order id
-- once per session, rather than counting purchase events, keeps those out.

create or replace table `ecomrl.clean.sessions` as

with events_with_session as (
  select
    concat(user_pseudo_id, '-', cast(
      (select p.value.int_value from unnest(event_params) as p where p.key = 'ga_session_id')
      as string)) as session_key,
    user_pseudo_id,
    user_id,
    event_name,
    event_timestamp,
    parse_date('%Y%m%d', event_date) as event_day,
    lower(coalesce(traffic_source.source, '(none)')) as source_key,
    lower(coalesce(traffic_source.medium, '(none)')) as medium_key,
    lower(coalesce(traffic_source.name, '(none)')) as campaign_key,
    device.category as device,
    geo.country as country,
    ecommerce.transaction_id as order_id,
    ecommerce.purchase_revenue_in_usd as revenue_usd
  from `ecomrl.raw.events`
),

by_session as (
  select
    session_key,
    user_pseudo_id,
    min(user_id) as user_id,
    min(event_day) as session_date,
    min(event_timestamp) as session_start_ts,
    min(source_key) as source_key,
    min(medium_key) as medium_key,
    min(campaign_key) as campaign_key,
    min(device) as device,
    min(country) as country,

    count(*) as events,
    countif(event_name = 'page_view') as page_views,
    countif(event_name = 'view_item') as item_views,
    countif(event_name = 'add_to_cart') as add_to_carts,
    countif(event_name = 'begin_checkout') as checkouts,
    countif(event_name = 'purchase') as purchases,

    min(if(event_name = 'purchase', order_id, null)) as order_id,
    max(if(event_name = 'purchase', revenue_usd, null)) as revenue_usd
  from events_with_session
  group by session_key, user_pseudo_id
)

select
  s.session_key,
  s.user_pseudo_id,
  s.user_id,
  s.session_date,
  date_trunc(s.session_date, week(monday)) as session_week,
  timestamp_micros(s.session_start_ts) as session_start_ts,

  cm.channel,
  cm.channel_group,
  cm.is_brand_search,
  s.source_key as source,
  s.medium_key as medium,
  nullif(s.campaign_key, '(none)') as campaign,

  s.device,
  s.country,
  case when s.country = 'United States' then 'US'
       when s.country = 'United Kingdom' then 'UK'
       else 'ROW' end as market,

  s.events,
  s.page_views,
  s.item_views,
  s.add_to_carts,
  s.checkouts,
  s.purchases > 0 as converted,
  s.order_id,
  s.revenue_usd

from by_session s
left join `ecomrl.clean.channel_map` cm
  on cm.source_key = s.source_key
 and cm.medium_key = s.medium_key
 and cm.campaign_key = s.campaign_key;


select
  count(*) as sessions,
  countif(channel is null) as sessions_with_no_channel,
  count(distinct session_date) as days,
  countif(converted) as converting_sessions,
  count(distinct order_id) as distinct_orders,
  round(100 * countif(converted) / count(*), 2) as conversion_rate_pct
from `ecomrl.clean.sessions`;

-- Result: 1,264,269 sessions over 363 days, all with a channel. 27,947 converted,
-- carrying 27,947 different order ids, so no session holds a repeated purchase.
-- Conversion rate 2.21 percent.


-- The funnel, counted in sessions that reached each step.

select
  count(*) as sessions,
  countif(item_views > 0) as viewed_item,
  countif(add_to_carts > 0) as added_to_cart,
  countif(checkouts > 0) as reached_checkout,
  countif(converted) as purchased
from `ecomrl.clean.sessions`;

-- Result: 1,264,269 sessions, 852,687 viewed a book, 167,534 added to cart, 94,217
-- reached checkout, 27,947 bought.


-- Orders GA4 recorded that are not in clean.orders. The staff test orders were dropped
-- from orders, but the website still tracked them.

select
  count(*) as sessions_with_an_unmatched_order,
  countif(s.order_id like 'T%') as of_those_staff_test_orders
from `ecomrl.clean.sessions` s
left join `ecomrl.clean.orders` o on o.order_id = s.order_id
where s.order_id is not null and o.order_id is null;

-- Result: 42 sessions, and all 42 are staff test orders. Every other order GA4 saw is
-- in clean.orders, so GA4 and the order system compare cleanly through this join.


-- ---------------------------------------------------------------------------
-- 6. Do the market labels line up?
-- ---------------------------------------------------------------------------
-- The reporting tables join spend, orders and sessions on date, channel and market. If
-- one source wrote Rest of World differently, the same day and channel would split into
-- two half rows and the totals would still add up, so this has to be checked directly.

select 'orders' as source, market, count(*) as row_count
from `ecomrl.clean.orders` group by market
union all
select 'ad_spend', market, count(*)
from `ecomrl.clean.ad_spend` group by market
union all
select 'sessions', market, count(*)
from `ecomrl.clean.sessions` group by market
union all
select 'customers', market, count(*)
from `ecomrl.clean.customers` group by market
order by source, market;

-- Result: US, UK and ROW in all four, nothing else.
--   orders     US 41,812    UK 19,012    ROW 15,094    (75,918)
--   ad_spend   US 9,864     UK 9,864     ROW 9,864     (29,592)
--   sessions   US 694,570   UK 316,960   ROW 252,739   (1,264,269)
--   customers  US 31,907    UK 14,632    ROW 11,562    (58,101)
