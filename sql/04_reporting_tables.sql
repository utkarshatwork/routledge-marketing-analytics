-- 04_reporting_tables.sql
--
-- Builds the four tables in ecomrl.clean that the Power BI report reads:
--
--   channel_daily      one row per day, channel and market: spend, orders, revenue,
--                      profit, new customers and sessions
--   funnel_daily       one row per day, channel, market and device, from GA4 sessions
--   campaign_weekly    one row per week, market, channel and paid campaign
--   weekly_health      one row per week of the GA4 year, with flags for weeks where
--                      the tracking or the conversion rate looks wrong
--
-- After the tables come two looks at Meta, because the report raised both: what Meta
-- Prospecting's clicks have cost over time, and where Meta visitors drop out of the
-- funnel.
--
-- A few rules hold all the way through:
--   - Last click. An order belongs to the channel recorded on the order at checkout.
--   - A customer is a person (person_id), not an account. A new customer is counted on
--     the day, channel and market of their first order.
--   - net_revenue_after_refund_usd is net revenue, after discounts and refunds, and is
--     the revenue figure every report uses. net_revenue_usd in channel_daily is revenue
--     before refunds, kept so totals can be tied back to the order system.
--   - Rates are always worked out from summed parts, never by averaging a rate column.
--
-- Reads the clean tables from 03_clean_layer.sql, plus raw.events and raw.promos in
-- two places that say why. Run from top to bottom.


-- ---------------------------------------------------------------------------
-- 1. channel_daily
-- ---------------------------------------------------------------------------
-- Where spend meets orders. Three sources go in, and each can exist without the
-- others: a channel can spend on a day it sells nothing, organic search sells with no
-- spend at all, and GA4 sessions only start in October 2024. So they are joined with
-- full outer joins. An inner join would quietly drop exactly the days worth looking at.
--
-- Sessions are left null before October 2024 rather than set to zero. No data is not
-- the same as no traffic.
--
-- Each person's first order is found by numbering their orders by time, with order_id
-- breaking a tie on the same timestamp so the answer never changes between runs.
-- campaign_weekly below uses the same rule.

create or replace table `ecomrl.clean.channel_daily` as

with first_orders as (
  select order_id
  from (
    select
      order_id,
      row_number() over (partition by person_id order by order_ts_utc, order_id) as order_rank
    from `ecomrl.clean.orders`
  )
  where order_rank = 1
),

spend as (
  select
    report_date as date,
    channel,
    market,
    sum(spend_usd) as spend_usd,
    sum(impressions) as impressions,
    sum(clicks) as clicks,
    sum(platform_conversions) as platform_conversions,
    sum(platform_revenue_usd) as platform_revenue_usd
  from `ecomrl.clean.ad_spend`
  group by report_date, channel, market
),

orders as (
  select
    o.order_date as date,
    o.channel,
    o.market,
    count(*) as orders,
    sum(o.net_revenue_usd) as net_revenue_usd,
    sum(o.refunded_usd) as refunded_usd,
    sum(o.net_revenue_after_refund_usd) as net_revenue_after_refund_usd,
    sum(o.gross_profit_usd) as gross_profit_usd,
    sum(o.affiliate_commission_usd) as affiliate_commission_usd,
    sum(o.discount_usd) as discount_usd,
    countif(o.used_promo) as orders_with_promo,
    countif(f.order_id is not null) as new_customers
  from `ecomrl.clean.orders` o
  left join first_orders f on f.order_id = o.order_id
  group by o.order_date, o.channel, o.market
),

sessions as (
  select
    session_date as date,
    channel,
    market,
    count(*) as sessions,
    countif(converted) as converting_sessions
  from `ecomrl.clean.sessions`
  group by session_date, channel, market
)

select
  coalesce(s.date, o.date, w.date) as date,
  date_trunc(coalesce(s.date, o.date, w.date), week(monday)) as week,
  date_trunc(coalesce(s.date, o.date, w.date), month) as month,
  coalesce(s.channel, o.channel, w.channel) as channel,
  coalesce(s.market, o.market, w.market) as market,

  coalesce(s.spend_usd, 0) as spend_usd,
  coalesce(s.impressions, 0) as impressions,
  coalesce(s.clicks, 0) as clicks,
  coalesce(s.platform_conversions, 0) as platform_conversions,
  coalesce(s.platform_revenue_usd, 0) as platform_revenue_usd,

  coalesce(o.orders, 0) as orders,
  coalesce(o.net_revenue_usd, 0) as net_revenue_usd,
  coalesce(o.refunded_usd, 0) as refunded_usd,
  coalesce(o.net_revenue_after_refund_usd, 0) as net_revenue_after_refund_usd,
  coalesce(o.gross_profit_usd, 0) as gross_profit_usd,
  coalesce(o.affiliate_commission_usd, 0) as affiliate_commission_usd,
  coalesce(o.discount_usd, 0) as discount_usd,
  coalesce(o.orders_with_promo, 0) as orders_with_promo,
  coalesce(o.new_customers, 0) as new_customers,

  w.sessions,
  w.converting_sessions

from spend s
full outer join orders o
  on o.date = s.date
 and o.channel = s.channel
 and o.market = s.market
full outer join sessions w
  on w.date = coalesce(s.date, o.date)
 and w.channel = coalesce(s.channel, o.channel)
 and w.market = coalesce(s.market, o.market);


-- The joins mustn't lose or add anything, so every total is put next to the table it
-- came from. The last column counts people straight from clean.orders, as a second way
-- of getting to the new customer total.

select
  count(*) as rows_built,
  sum(orders) as orders,
  round(sum(net_revenue_usd), 2) as revenue_before_refunds_usd,
  round(sum(net_revenue_after_refund_usd), 2) as net_revenue_after_refunds,
  round(sum(gross_profit_usd), 2) as gross_profit_usd,
  round(sum(affiliate_commission_usd), 2) as affiliate_commission_usd,
  round(sum(spend_usd), 2) as spend_usd,
  sum(new_customers) as new_customers,
  sum(sessions) as sessions,
  (select count(distinct person_id) from `ecomrl.clean.orders`) as people_in_orders
from `ecomrl.clean.channel_daily`;

-- Result: 34,356 rows. 75,918 orders, $12,296,260.18 before refunds, $11,907,875.43 of
-- net revenue and $7,421,060.08 of gross profit, all equal to clean.orders to the cent.
-- $227,336.14 of affiliate commission and $1,247,288.94 of spend, both equal to their
-- sources. 58,101 new customers, one for each of the 58,101 people in clean.orders, and
-- 1,264,269 sessions.


-- What each channel cost and what it brought back, on last click. Cost per new
-- customer and the two return figures are left blank for channels with no spend,
-- because they can't be worked out, not because they are zero.

select
  channel,
  round(sum(spend_usd), 0) as spend_usd,
  sum(new_customers) as new_customers,
  sum(orders) as orders,
  round(sum(net_revenue_after_refund_usd), 0) as net_revenue_after_refunds,
  round(sum(gross_profit_usd), 0) as gross_profit_usd,
  round(if(sum(spend_usd) > 0, safe_divide(sum(spend_usd), sum(new_customers)), null), 2)
    as cost_per_new_customer,
  round(safe_divide(sum(net_revenue_after_refund_usd), nullif(sum(spend_usd), 0)), 2) as internal_roas,
  round(safe_divide(sum(gross_profit_usd) - sum(spend_usd), nullif(sum(spend_usd), 0)), 2)
    as profit_return_on_spend
from `ecomrl.clean.channel_daily`
group by channel
order by spend_usd desc, net_revenue_after_refunds desc;

-- Result (spend, new customers, cost per new customer, internal ROAS, profit return on
-- spend):
--   meta_prospecting   $512,242   9,750   $52.54    2.61   0.69
--   google_nonbrand    $331,980   9,514   $34.89    5.30   2.31
--   google_shopping    $200,064   5,577   $35.87    4.19   1.65
--   meta_retargeting   $125,537   3,150   $39.85    5.54   2.53
--   google_brand        $77,465   4,968   $15.59   14.28   7.98
-- The other eight channels have no spend, so those three columns come back blank. On
-- last click, brand search returns the most per dollar and Meta Prospecting the least.
-- Last click hands brand search the whole order even when the person found the shop
-- some other way first, so that ranking needs checking under other attribution rules.


-- ---------------------------------------------------------------------------
-- 2. funnel_daily
-- ---------------------------------------------------------------------------
-- Sessions counted at each step of the funnel: viewed a book, added to cart, reached
-- checkout, bought. GA4 only, so October 2024 onwards.
--
-- conversion_rate_pct is there for reading a single row. Anything that adds rows up
-- has to sum sessions_purchased and sessions and divide, not average this column.

create or replace table `ecomrl.clean.funnel_daily` as
select
  session_date as date,
  date_trunc(session_date, week(monday)) as week,
  channel,
  channel_group,
  market,
  device,

  count(*) as sessions,
  countif(item_views > 0) as sessions_viewed_item,
  countif(add_to_carts > 0) as sessions_added_to_cart,
  countif(checkouts > 0) as sessions_reached_checkout,
  countif(converted) as sessions_purchased,
  sum(coalesce(revenue_usd, 0)) as revenue_usd,

  round(100 * safe_divide(countif(converted), count(*)), 3) as conversion_rate_pct
from `ecomrl.clean.sessions`
group by session_date, date_trunc(session_date, week(monday)), channel, channel_group, market, device;


select
  count(*) as rows_built,
  min(date) as first_date,
  max(date) as last_date,
  count(distinct date) as days_covered,
  sum(sessions) as sessions,
  sum(sessions_purchased) as purchases
from `ecomrl.clean.funnel_daily`;

-- Result: 39,721 rows covering 363 days, 1 October 2024 to 30 September 2025. 1,264,269
-- sessions and 27,947 purchases, both equal to clean.sessions. The two days missing are
-- 13 and 14 May 2025, when GA4 recorded nothing.


-- The funnel for the whole GA4 year, each step as a share of the step before it.

select
  sum(sessions) as sessions,
  round(100 * sum(sessions_viewed_item) / sum(sessions), 1) as session_to_view_pct,
  round(100 * sum(sessions_added_to_cart) / sum(sessions_viewed_item), 1) as view_to_cart_pct,
  round(100 * sum(sessions_reached_checkout) / sum(sessions_added_to_cart), 1) as cart_to_checkout_pct,
  round(100 * sum(sessions_purchased) / sum(sessions_reached_checkout), 1) as checkout_to_purchase_pct,
  round(100 * sum(sessions_purchased) / sum(sessions), 2) as conversion_pct
from `ecomrl.clean.funnel_daily`;

-- Result: 67.4 percent of sessions viewed a book, 19.6 percent of those added one to the
-- cart, 56.2 percent of those reached checkout and 29.7 percent of those bought. Overall,
-- 2.21 percent of sessions ended in a purchase.


-- ---------------------------------------------------------------------------
-- 3. campaign_weekly
-- ---------------------------------------------------------------------------
-- Performance by paid campaign, so the report can go below channel level.
--
-- Weekly rather than daily because Google reports its days in UTC and Meta in Pacific
-- time, while orders are in UTC. A Meta day starts seven or eight hours after an order
-- day, so spend and orders don't line up day by day. Over a week the difference
-- washes out.
--
-- Paid campaigns only, because CTR, cost per click and cost per order need spend. Paid
-- orders whose campaign tag got lost can't be tied to a campaign. They stay in
-- channel_daily under google_paid_untagged and meta_untagged, so paid totals should
-- always come from channel_daily, not from this table.
--
-- Campaigns are matched on the lower cased name, because six Meta campaigns arrive
-- in two spellings and would otherwise be split in half. Every GROUP BY below names
-- the expression in full, so the lower cased name is what gets grouped.

create or replace table `ecomrl.clean.campaign_weekly` as

with spend as (
  select
    report_week as week,
    market,
    channel,
    platform,
    lower(campaign_name) as campaign,
    sum(spend_usd) as spend_usd,
    sum(impressions) as impressions,
    sum(clicks) as clicks,
    sum(platform_conversions) as platform_conversions,
    sum(platform_revenue_usd) as platform_revenue_usd
  from `ecomrl.clean.ad_spend`
  group by report_week, market, channel, platform, lower(campaign_name)
),

first_orders as (
  select order_id
  from (
    select
      order_id,
      row_number() over (partition by person_id order by order_ts_utc, order_id) as order_rank
    from `ecomrl.clean.orders`
  )
  where order_rank = 1
),

orders as (
  select
    o.order_week as week,
    o.market,
    o.channel,
    o.ad_platform as platform,
    lower(o.campaign) as campaign,
    count(*) as orders,
    countif(f.order_id is not null) as new_customers,
    sum(o.net_revenue_after_refund_usd) as net_revenue_after_refund_usd,
    sum(o.gross_profit_usd) as gross_profit_usd
  from `ecomrl.clean.orders` o
  left join first_orders f on f.order_id = o.order_id
  where o.channel_group = 'paid'
    and o.campaign is not null
  group by o.order_week, o.market, o.channel, o.ad_platform, lower(o.campaign)
)

select
  coalesce(s.week, o.week) as week,
  coalesce(s.market, o.market) as market,
  coalesce(s.channel, o.channel) as channel,
  coalesce(s.platform, o.platform) as platform,
  coalesce(s.campaign, o.campaign) as campaign,

  coalesce(s.spend_usd, 0) as spend_usd,
  coalesce(s.impressions, 0) as impressions,
  coalesce(s.clicks, 0) as clicks,
  coalesce(s.platform_conversions, 0) as platform_conversions,
  coalesce(s.platform_revenue_usd, 0) as platform_revenue_usd,

  coalesce(o.orders, 0) as orders,
  coalesce(o.new_customers, 0) as new_customers,
  coalesce(o.net_revenue_after_refund_usd, 0) as net_revenue_after_refund_usd,
  coalesce(o.gross_profit_usd, 0) as gross_profit_usd

-- full outer join for the same reason as channel_daily: a campaign can spend in a
-- week it sells nothing
from spend s
full outer join orders o
  on o.week = s.week
 and o.market = s.market
 and o.channel = s.channel
 and o.campaign = s.campaign;


-- Totals against their sources. Spend against ad_spend, orders and revenue against
-- the tagged paid orders in clean.orders, and new customers against the five tagged
-- paid channels in channel_daily.

select
  round(sum(spend_usd), 2) as spend_usd,
  (select round(sum(spend_usd), 2) from `ecomrl.clean.ad_spend`) as spend_in_ad_spend,

  sum(orders) as orders,
  (select count(*) from `ecomrl.clean.orders`
   where channel_group = 'paid' and campaign is not null) as tagged_paid_orders,

  round(sum(net_revenue_after_refund_usd), 2) as net_revenue_after_refunds,
  (select round(sum(net_revenue_after_refund_usd), 2) from `ecomrl.clean.orders`
   where channel_group = 'paid' and campaign is not null) as tagged_paid_net_revenue,

  sum(new_customers) as new_customers,
  (select sum(new_customers) from `ecomrl.clean.channel_daily`
   where channel in ('google_brand', 'google_nonbrand', 'google_shopping',
                     'meta_prospecting', 'meta_retargeting')) as new_customers_in_channel_daily
from `ecomrl.clean.campaign_weekly`;

-- Result: $1,247,288.94 of spend on both sides. 37,461 orders and $5,735,882.61 of net
-- revenue, equal to the paid orders that carry a campaign tag. 32,959 new customers, the
-- same as channel_daily gives for the five tagged paid channels. The 775 paid orders with
-- no campaign tag are in channel_daily only.


-- The grain, one row per week, market, channel and campaign with nothing repeated, and
-- whether every campaign shows up on both sides. A campaign with spend but no orders
-- at all, or orders but no spend at all, would mean the names didn't line up between
-- the ad accounts and the tags.

with by_campaign as (
  select
    campaign,
    sum(spend_usd) as total_spend_usd,
    sum(orders) as total_orders
  from `ecomrl.clean.campaign_weekly`
  group by campaign
)

select
  (select count(*) from `ecomrl.clean.campaign_weekly`) as rows_built,
  (select count(*) - count(distinct concat(cast(week as string), market, channel, campaign))
   from `ecomrl.clean.campaign_weekly`) as duplicate_rows,
  count(*) as campaigns,
  countif(total_orders = 0) as campaigns_with_spend_but_no_orders,
  countif(total_spend_usd = 0) as campaigns_with_orders_but_no_spend
from by_campaign;

-- Result: 2,370 rows with no duplicates. 15 campaigns, every one with both spend and
-- orders.


-- The campaign view itself, all three years.
--   ctr_pct        clicks over impressions
--   cpc            spend over clicks
--   cpa            spend over orders, on last click
--   internal_roas  net revenue after refunds over spend
--   platform_roas  what the platform says it earned, over spend

select
  platform,
  channel,
  campaign,
  round(sum(spend_usd), 0) as spend_usd,
  round(100 * safe_divide(sum(clicks), sum(impressions)), 2) as ctr_pct,
  round(safe_divide(sum(spend_usd), sum(clicks)), 2) as cpc,
  sum(orders) as orders,
  round(safe_divide(sum(spend_usd), sum(orders)), 2) as cpa,
  round(safe_divide(sum(net_revenue_after_refund_usd), sum(spend_usd)), 2) as internal_roas,
  round(safe_divide(sum(platform_revenue_usd), sum(spend_usd)), 2) as platform_roas
from `ecomrl.clean.campaign_weekly`
group by platform, channel, campaign
order by spend_usd desc;

-- Result (spend, CTR, cost per click, orders, cost per order, internal ROAS, platform
-- ROAS):
--   rtl_prospecting_us         $280,480    1.07%   $0.71   5,324   $52.68    2.60   3.33
--   rtl_nonbrand_us_alwayson   $181,872    4.48%   $1.54   5,892   $30.87    5.28   6.36
--   rtl_prospecting_uk         $126,362    1.06%   $0.72   2,410   $52.43    2.62   3.37
--   rtl_shopping_us_alwayson   $110,235    2.73%   $1.09   3,078   $35.81    4.19   5.02
--   rtl_prospecting_row        $105,401    1.06%   $0.72   2,016   $52.28    2.63   3.32
--   rtl_nonbrand_uk_alwayson    $83,362    4.50%   $1.55   2,701   $30.86    5.33   6.37
--   rtl_retargeting_us          $68,778    1.83%   $0.64   2,500   $27.51    5.57   7.10
--   rtl_nonbrand_row_alwayson   $66,747    4.49%   $1.55   2,158   $30.93    5.32   6.43
--   rtl_shopping_uk_alwayson    $50,820    2.74%   $1.10   1,410   $36.04    4.18   5.06
--   rtl_brand_us_alwayson       $42,849   10.69%   $0.98   3,769   $11.37   14.40  17.26
--   rtl_shopping_row_alwayson   $39,009    2.72%   $1.10   1,089   $35.82    4.20   5.03
--   rtl_retargeting_uk          $31,815    1.80%   $0.66   1,143   $27.83    5.54   7.17
--   rtl_retargeting_row         $24,943    1.76%   $0.67     907   $27.50    5.45   7.05
--   rtl_brand_uk_alwayson       $19,399   10.79%   $1.00   1,722   $11.27   14.12  17.10
--   rtl_brand_row_alwayson      $15,217   10.77%   $1.00   1,342   $11.34   14.16  17.01
-- Inside each channel the three markets perform almost the same, so the differences
-- that matter are between channels, not between markets. Every campaign's platform ROAS
-- is above its internal ROAS: Google campaigns claim about a fifth more than the order
-- system finds, Meta campaigns about 28 percent more.


-- ---------------------------------------------------------------------------
-- 4. weekly_health
-- ---------------------------------------------------------------------------
-- A weekly check on the GA4 year, 1 October 2024 to 30 September 2025, that flags
-- any week where a measure moves outside its normal range. Four measures:
--
--   days_with_data     days of GA4 data in the week, against days in the window
--   capture_rate       orders GA4 saw, over orders the order system recorded
--   events_per_order   GA4 purchase events over the distinct orders they carry
--   conversion_rate    purchasing sessions over sessions
--
-- Each is a ratio or a count against the calendar, so the academic year mostly
-- cancels out. Raw volumes like sessions per week would flag every term start.
--
-- Normal is the median of each ratio over complete weeks. The median rather than the
-- average, because broken weeks would pull an average towards themselves. A week is
-- flagged when it sits further from normal than:
--
--   capture_rate       10 percent either way
--   events_per_order   5 percent above
--   conversion_rate    20 percent either way
--
-- The tolerances are a judgement call and sit here so they are easy to change.
--
-- raw.events is read for one thing only. clean.sessions already keeps one order per
-- session, so purchases that GA4 sent twice can only be seen in the raw events.

create or replace table `ecomrl.clean.weekly_health` as

with calendar as (
  -- every day in the window, whether or not GA4 has data for it. A missing day has
  -- no rows in any GA4 table, so the only way to find it is to start from a calendar
  select
    d as day,
    date_trunc(d, week(monday)) as week
  from unnest(generate_date_array(date '2024-10-01', date '2025-09-30')) as d
),

ga4_days as (
  select distinct session_date as day
  from `ecomrl.clean.sessions`
),

completeness as (
  select
    c.week,
    count(*) as days_in_window,
    count(g.day) as days_with_data
  from calendar c
  left join ga4_days g on g.day = c.day
  group by c.week
),

sessions_weekly as (
  select
    session_week as week,
    count(*) as sessions,
    countif(converted) as purchasing_sessions
  from `ecomrl.clean.sessions`
  group by session_week
),

ga4_orders as (
  -- only orders that exist in the order system, so the staff test orders GA4 tracked
  -- don't count as orders it saw
  select
    s.session_week as week,
    count(distinct s.order_id) as ga4_orders
  from `ecomrl.clean.sessions` s
  join `ecomrl.clean.orders` o on o.order_id = s.order_id
  group by s.session_week
),

system_orders as (
  select
    order_week as week,
    count(*) as system_orders
  from `ecomrl.clean.orders`
  where order_date between date '2024-10-01' and date '2025-09-30'
  group by order_week
),

purchase_events as (
  select
    date_trunc(parse_date('%Y%m%d', event_date), week(monday)) as week,
    count(*) as purchase_events,
    count(distinct ecommerce.transaction_id) as purchased_orders
  from `ecomrl.raw.events`
  where event_name = 'purchase'
  group by date_trunc(parse_date('%Y%m%d', event_date), week(monday))
),

weekly as (
  select
    c.week,
    c.days_in_window,
    c.days_with_data,
    s.sessions,
    s.purchasing_sessions,
    g.ga4_orders,
    so.system_orders,
    p.purchase_events,
    p.purchased_orders,
    safe_divide(s.purchasing_sessions, s.sessions) as conversion_rate,
    safe_divide(g.ga4_orders, so.system_orders) as capture_rate,
    safe_divide(p.purchase_events, p.purchased_orders) as events_per_order
  from completeness c
  left join sessions_weekly s on s.week = c.week
  left join ga4_orders g on g.week = c.week
  left join system_orders so on so.week = c.week
  left join purchase_events p on p.week = c.week
),

normal as (
  -- medians over complete weeks only, so the part weeks at either end of the window
  -- and weeks with missing days can't shift what normal looks like
  select distinct
    percentile_cont(conversion_rate, 0.5) over () as conversion_rate_normal,
    percentile_cont(capture_rate, 0.5) over () as capture_rate_normal,
    percentile_cont(events_per_order, 0.5) over () as events_per_order_normal
  from weekly
  where days_with_data = 7
)

select
  w.week,
  w.days_in_window,
  w.days_with_data,
  w.sessions,
  w.purchasing_sessions,
  w.ga4_orders,
  w.system_orders,
  w.purchase_events,
  w.purchased_orders,

  round(w.conversion_rate, 5) as conversion_rate,
  round(n.conversion_rate_normal, 5) as conversion_rate_normal,
  round(w.capture_rate, 4) as capture_rate,
  round(n.capture_rate_normal, 4) as capture_rate_normal,
  round(w.events_per_order, 4) as events_per_order,
  round(n.events_per_order_normal, 4) as events_per_order_normal,

  -- the window starts and ends on a Tuesday, so the first and last weeks are short
  -- by design. Missing days are measured against days in the window, not against 7
  w.days_with_data < w.days_in_window as flag_missing_days,
  abs(w.capture_rate / n.capture_rate_normal - 1) > 0.10 as flag_capture_rate,
  w.events_per_order / n.events_per_order_normal - 1 > 0.05 as flag_duplicate_purchases,
  abs(w.conversion_rate / n.conversion_rate_normal - 1) > 0.20 as flag_conversion_rate

from weekly w
cross join normal n;


select
  count(*) as weeks,
  min(week) as first_week,
  max(week) as last_week,
  sum(days_in_window) as days_in_window,
  sum(days_with_data) as days_with_data,
  sum(sessions) as sessions,
  sum(purchasing_sessions) as purchasing_sessions
from `ecomrl.clean.weekly_health`;

-- Result: 53 weeks, from the week of 30 September 2024 to the week of 29 September 2025.
-- 363 of the 365 days have data. 1,264,269 sessions and 27,947 purchasing sessions, equal
-- to clean.sessions.


-- What a normal week looks like.

select distinct
  conversion_rate_normal,
  capture_rate_normal,
  events_per_order_normal
from `ecomrl.clean.weekly_health`;

-- Result: a normal week converts 2.204 percent of sessions, GA4 sees 88.47 percent of the
-- orders the order system records, and each order fires exactly one purchase event.


-- The weeks that were flagged, and what for.

select
  week,
  days_with_data,
  days_in_window,
  capture_rate,
  events_per_order,
  conversion_rate,
  array_to_string([
    if(flag_missing_days, 'missing days', null),
    if(flag_capture_rate, 'capture rate', null),
    if(flag_duplicate_purchases, 'duplicate purchases', null),
    if(flag_conversion_rate, 'conversion rate', null)
  ], ', ') as flagged_for
from `ecomrl.clean.weekly_health`
where flag_missing_days
   or flag_capture_rate
   or flag_duplicate_purchases
   or flag_conversion_rate
order by week;

-- Result: nine weeks flagged.
--   20 Jan, 27 Jan, 3 Feb 2025     duplicate purchases: 1.34, 1.37 and 1.31 events per order
--   12 May 2025                    missing days (5 of 7) and a capture rate of 0.611
--   19 May, 9, 16, 23, 30 Jun 2025 conversion rate only, between 2.695 and 2.882 percent
-- In the five conversion weeks every day has data, the capture rate is normal and each
-- order fires once, so the tracking looks healthy and the higher conversion looks real.


-- The conversion flags in May and June came with healthy tracking, so the first thing
-- to rule out was the mid-year sale, which ran 20 May to 10 June 2025. This lists
-- every week from mid April to the end of July with the days a sale was running and
-- the share of orders that used a code. If the flagged weeks were the sale weeks, the
-- sale would explain them.

with sale_days as (
  select
    date_trunc(d, week(monday)) as week,
    count(p.promo_name) as sale_days,
    string_agg(distinct p.promo_name order by p.promo_name) as sale
  from unnest(generate_date_array(date '2025-04-14', date '2025-08-03')) as d
  left join `ecomrl.raw.promos` p
    on d between p.start_date and p.end_date
  group by date_trunc(d, week(monday))
),

codes as (
  select
    order_week as week,
    round(100 * countif(used_promo) / count(*), 1) as pct_orders_with_code
  from `ecomrl.clean.orders`
  where order_week between date '2025-04-14' and date '2025-07-28'
  group by order_week
)

select
  h.week,
  h.flag_conversion_rate,
  round(100 * h.conversion_rate, 3) as conversion_pct,
  round(100 * h.conversion_rate_normal, 3) as normal_conversion_pct,
  s.sale_days,
  s.sale,
  c.pct_orders_with_code
from `ecomrl.clean.weekly_health` h
join sale_days s on s.week = h.week
join codes c on c.week = h.week
where h.week between date '2025-04-14' and date '2025-07-28'
order by h.week;

-- Result: the sale doesn't line up with the flags. The two full sale weeks, 26 May and 2
-- June (7 sale days each, about two thirds of orders on a code), were not flagged, at
-- 2.435 and 2.385 percent. Three flagged weeks, 16, 23 and 30 June, came after the sale had
-- ended, with no sale days and no codes used. What lifted conversion in June is still an
-- open question.


-- ---------------------------------------------------------------------------
-- 5. Meta Prospecting: what its clicks cost over time
-- ---------------------------------------------------------------------------
-- Cost per click, CTR and cost per thousand impressions (CPM) by quarter, all three
-- years. If cost per click rises while CTR holds, CPM shows whether the auction itself
-- got dearer. A week counts in the quarter its Monday falls in, and the first and
-- last quarters are part quarters, so read the rates rather than the spend.

select
  date_trunc(week, quarter) as quarter,
  round(sum(spend_usd), 0) as spend_usd,
  round(100 * safe_divide(sum(clicks), sum(impressions)), 3) as ctr_pct,
  round(safe_divide(sum(spend_usd), sum(clicks)), 3) as cpc,
  round(1000 * safe_divide(sum(spend_usd), sum(impressions)), 2) as cpm,
  sum(orders) as orders,
  round(100 * safe_divide(sum(orders), sum(clicks)), 2) as click_to_order_pct,
  round(safe_divide(sum(spend_usd), sum(orders)), 2) as cpa,
  round(safe_divide(sum(net_revenue_after_refund_usd), sum(spend_usd)), 2) as internal_roas
from `ecomrl.clean.campaign_weekly`
where channel = 'meta_prospecting'
group by date_trunc(week, quarter)
order by quarter;

-- Result: cost per click rose from $0.631 in October to December 2022 to $0.784 in July
-- to September 2025, about 24 percent, while CTR stayed between 1.05 and 1.08 percent
-- in every full quarter.
-- CPM rose from $6.75 to $8.41 over the same quarters, so the clicks got dearer because
-- the impressions did. Cost per order did not follow. It moves between $48 and $61 a
-- quarter with no trend, because the share of clicks that became orders rose too: 1.36,
-- 1.49 and 1.62 percent in July to September of 2023, 2024 and 2025. If that gain
-- stalls, cost per order will start to follow cost per click up. The first row is the
-- week of 26 September 2022, which holds only 1 and 2 October.


-- ---------------------------------------------------------------------------
-- 6. Meta visitors and checkout
-- ---------------------------------------------------------------------------
-- The report's funnel page shows Meta traffic reaching checkout and then not buying
-- far more often than any other traffic. Four queries look at where that happens.
-- Channel families are the same as on the report: Google, Meta, Affiliate, and Owned
-- and organic for everything else.
--
-- First, every family by device over the GA4 year. If checkout breaks inside the
-- Facebook and Instagram in-app browser, the gap would sit on mobile and mostly
-- disappear on desktop.

with tagged as (
  select
    *,
    case
      when channel like 'google%' then 'Google'
      when channel like 'meta%' then 'Meta'
      when channel like 'affiliate%' then 'Affiliate'
      else 'Owned and organic'
    end as family
  from `ecomrl.clean.funnel_daily`
)

select
  family,
  device,
  sum(sessions) as sessions,
  round(100 * sum(sessions) / sum(sum(sessions)) over (partition by family), 1)
    as pct_of_family_sessions,
  round(100 * safe_divide(sum(sessions_added_to_cart), sum(sessions_viewed_item)), 1) as view_to_cart_pct,
  round(100 * safe_divide(sum(sessions_reached_checkout), sum(sessions_added_to_cart)), 1)
    as cart_to_checkout_pct,
  round(100 * safe_divide(sum(sessions_purchased), sum(sessions_reached_checkout)), 1)
    as checkout_to_purchase_pct,
  round(100 * safe_divide(sum(sessions_purchased), sum(sessions)), 2) as conversion_pct
from tagged
group by family, device
order by family, device;

-- Result: Meta visitors who reach checkout buy 18.4 percent of the time on desktop, 14.2
-- on mobile and 16.2 on tablet. Every other family is between 40.4 and 42.5 percent on
-- desktop, 34.3 and 35.3 on mobile, and 35.8 and 41.0 on tablet. Meta is just as far
-- behind on desktop as on mobile, so the in-app browser doesn't look like the cause.
-- Every family splits about the same way by device: 35 percent desktop, 58 mobile, 7
-- tablet.


-- Inside Meta: prospecting, retargeting and untagged, by device. All three land people
-- through the same apps, so if the browser were the cause, all three would show it.

select
  channel,
  device,
  sum(sessions) as sessions,
  round(100 * safe_divide(sum(sessions_reached_checkout), sum(sessions_added_to_cart)), 1)
    as cart_to_checkout_pct,
  round(100 * safe_divide(sum(sessions_purchased), sum(sessions_reached_checkout)), 1)
    as checkout_to_purchase_pct,
  round(100 * safe_divide(sum(sessions_purchased), sum(sessions)), 2) as conversion_pct
from `ecomrl.clean.funnel_daily`
where channel like 'meta%'
group by channel, device
order by channel, device;

-- Result (checkout to purchase on desktop, mobile, tablet):
--   meta_prospecting   14.8, 11.4, 13.0 percent
--   meta_retargeting   32.6, 26.0, 28.7 percent
--   meta_untagged      19.0, 17.5, 19.6 percent
-- Retargeting reaches people through the same apps but buys at checkout about twice as
-- often as prospecting. So the browser does not look like the cause; why prospecting
-- visitors leave is still open.


-- Has it always been like this, or did it start on a date? A gap that opens in one
-- month would point to a release that broke something.

select
  date_trunc(date, month) as month,
  round(100 * safe_divide(
    sum(if(channel like 'meta%', sessions_purchased, 0)),
    sum(if(channel like 'meta%', sessions_reached_checkout, 0))), 1) as meta_pct,
  round(100 * safe_divide(
    sum(if(channel like 'meta%' and device = 'mobile', sessions_purchased, 0)),
    sum(if(channel like 'meta%' and device = 'mobile', sessions_reached_checkout, 0))), 1)
    as meta_mobile_pct,
  round(100 * safe_divide(
    sum(if(channel like 'meta%' and device = 'desktop', sessions_purchased, 0)),
    sum(if(channel like 'meta%' and device = 'desktop', sessions_reached_checkout, 0))), 1)
    as meta_desktop_pct,
  round(100 * safe_divide(
    sum(if(channel not like 'meta%', sessions_purchased, 0)),
    sum(if(channel not like 'meta%', sessions_reached_checkout, 0))), 1) as others_pct
from `ecomrl.clean.funnel_daily`
group by date_trunc(date, month)
order by month;

-- Result: Meta's checkout to purchase sits between 13.9 and 18.0 percent in every month,
-- and every other family's between 35.4 and 42.8. The gap is there from October 2024 and
-- never closes, so it doesn't look like a release that broke something on a date.


-- Are Meta visitors really not buying, or is GA4 just not seeing them buy? If the
-- purchase tag failed to fire for Meta visitors, the order system would hold orders
-- GA4 missed and Meta's capture rate would sit well below everyone else's. That would
-- be a tracking fix. If the capture rate is normal, the missing purchases look like real
-- lost orders.
--
-- Built from the order system, with each order's own channel and device, so both sides
-- of the ratio describe the same orders. GA4 year only.

with system_orders as (
  select
    order_id,
    case
      when channel like 'google%' then 'Google'
      when channel like 'meta%' then 'Meta'
      when channel like 'affiliate%' then 'Affiliate'
      else 'Owned and organic'
    end as family,
    device
  from `ecomrl.clean.orders`
  where order_date between date '2024-10-01' and date '2025-09-30'
),

ga4_orders as (
  select distinct order_id
  from `ecomrl.clean.sessions`
  where converted and order_id is not null
)

select
  s.family,
  s.device,
  count(*) as system_orders,
  countif(g.order_id is not null) as ga4_orders,
  round(safe_divide(countif(g.order_id is not null), count(*)), 3) as capture_rate
from system_orders s
left join ga4_orders g on g.order_id = s.order_id
group by s.family, s.device
order by s.family, s.device;

-- Result: GA4 sees between 86.7 and 88.2 percent of Meta's orders on each device, against
-- 87.5 to 88.7 percent for every other family. Meta orders are tracked normally, so the
-- purchases missing at checkout look like real lost orders rather than a tracking gap.
