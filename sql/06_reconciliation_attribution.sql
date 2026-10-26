-- 06_reconciliation_attribution.sql
--
-- Builds four tables in ecomrl.clean for three questions that keep coming up. Why do
-- Google, Meta, GA4 and the order system all give different numbers, and which one
-- should we use? Who deserves the credit for an order when a customer touched several
-- channels on the way? And what is the affiliate network actually being paid for?
--
--   platform_weekly         one row per week and ad platform: what Google and Meta
--                           claim, next to the paid orders the business recorded
--   journey_touches         one row per session in the 30 days before each order GA4
--                           saw, with its share of the credit under four attribution
--                           rules
--   order_journeys          one row per order from 1 October 2024, with what GA4 saw
--                           and which platforms could have claimed it
--   affiliate_transactions  one row per affiliate transaction on a real order
--
-- A few rules hold all the way through:
--   - The order system is the truth for orders and revenue, and last click (the
--     channel recorded on the order) is how an order is credited.
--   - Net revenue is after discounts and refunds. The platforms claim revenue before
--     refunds, so their claims are compared with revenue before refunds and the
--     refunds are shown as a separate step.
--   - Google and Meta are compared by week, never by day, because Meta reports its
--     days on Pacific time and everything else is on UTC.
--   - Untagged Google and Meta orders belong to their platform here. They are paid
--     clicks that lost their campaign tag, and the platforms count them.
--
-- Reads the clean tables from 03_clean_layer.sql, channel_daily from
-- 04_reporting_tables.sql (one check) and customer_value from 05_customer_value.sql.
-- Run from top to bottom. The walk from platform claims down to real orders is drawn
-- in the reconciliation notebook from these tables.


-- ---------------------------------------------------------------------------
-- 1. platform_weekly
-- ---------------------------------------------------------------------------
-- What each platform says it did, next to what the order system recorded, week by
-- week for all three years.
--
-- Meta reports purchases after a click and purchases after only seeing an ad in two
-- separate columns, and clean.ad_spend adds them together. The split is read from
-- raw.meta_ads, because keeping the two apart is the first step in reconciling Meta.
-- Spend, Google conversions and claimed revenue come from clean.ad_spend, already in
-- dollars at each day's rate.
--
-- A calendar of weeks is the spine, so a week with spend and no orders, or orders and
-- no spend, still gets its row.

create or replace table `ecomrl.clean.platform_weekly` as

with weeks as (
  select week, platform
  from unnest(generate_date_array(date '2022-09-26', date '2025-09-29', interval 1 week)) as week
  cross join unnest(['google', 'meta']) as platform
),

spend as (
  select
    report_week as week,
    platform,
    sum(spend_usd) as spend_usd,
    sum(clicks) as clicks,
    sum(platform_conversions) as platform_conversions,
    sum(platform_revenue_usd) as platform_revenue_usd
  from `ecomrl.clean.ad_spend`
  group by report_week, platform
),

meta_split as (
  select
    date_trunc(report_date, week(monday)) as week,
    sum(purchases_7d_click) as click_conversions,
    sum(purchases_1d_view) as view_conversions
  from `ecomrl.raw.meta_ads`
  group by date_trunc(report_date, week(monday))
),

paid_orders as (
  -- ad_platform is google or meta on every paid order, tagged or untagged
  select
    order_week as week,
    ad_platform as platform,
    count(*) as orders,
    sum(net_revenue_usd) as revenue_before_refunds_usd,
    sum(refunded_usd) as refunded_usd,
    sum(net_revenue_after_refund_usd) as net_revenue_usd,
    sum(gross_profit_usd) as gross_profit_usd
  from `ecomrl.clean.orders`
  where ad_platform is not null
  group by order_week, ad_platform
)

select
  w.week,
  w.platform,
  -- the 51 complete weeks inside the GA4 export, 7 October 2024 to 28 September 2025.
  -- The reconciliation uses these, because part of it needs GA4
  w.week between date '2024-10-07' and date '2025-09-22' as in_reconciliation_period,
  -- the three weeks GA4 sent some purchases twice
  w.week in (date '2025-01-20', date '2025-01-27', date '2025-02-03') as duplicate_event_week,

  coalesce(s.spend_usd, 0) as spend_usd,
  coalesce(s.clicks, 0) as clicks,
  -- Google reports one conversion figure, all from clicks. Meta's is split
  case when w.platform = 'google' then coalesce(s.platform_conversions, 0)
       else coalesce(m.click_conversions, 0) end as platform_click_conversions,
  case when w.platform = 'google' then 0
       else coalesce(m.view_conversions, 0) end as platform_view_conversions,
  -- what the platform says those conversions were worth. For Meta this covers click
  -- purchases only; Meta puts no value on purchases after a view
  coalesce(s.platform_revenue_usd, 0) as platform_revenue_usd,

  coalesce(o.orders, 0) as orders,
  coalesce(o.revenue_before_refunds_usd, 0) as revenue_before_refunds_usd,
  coalesce(o.refunded_usd, 0) as refunded_usd,
  -- net revenue after refunds, despite the short name
  coalesce(o.net_revenue_usd, 0) as net_revenue_usd,
  coalesce(o.gross_profit_usd, 0) as gross_profit_usd

from weeks w
left join spend s on s.week = w.week and s.platform = w.platform
left join meta_split m on m.week = w.week and w.platform = 'meta'
left join paid_orders o on o.week = w.week and o.platform = w.platform;


-- Platform totals over the three years. Spend can be set against the clean.ad_spend
-- total from 03_clean_layer.sql.

select
  platform,
  count(*) as weeks,
  round(sum(spend_usd), 2) as spend_usd,
  sum(orders) as orders,
  round(sum(revenue_before_refunds_usd), 2) as revenue_before_refunds_usd,
  round(sum(net_revenue_usd), 2) as net_revenue_after_refunds,
  round(sum(platform_revenue_usd), 2) as platform_revenue_usd,
  round(sum(platform_click_conversions), 1) as click_conversions,
  round(sum(platform_view_conversions), 1) as view_conversions
from `ecomrl.clean.platform_weekly`
group by rollup (platform)
order by platform is null, platform;

-- Result: 158 weeks for each platform, 316 rows. Spend is $609,509.99 on Google and
-- $637,778.95 on Meta, $1,247,288.94 in all, the same total 03_clean_layer.sql gives for
-- clean.ad_spend. 23,622 Google and 14,614 Meta paid orders, 38,236 together, with
-- $6,039,668.53 of revenue before refunds and $5,856,811.48 of net revenue
-- ($3,781,607.46 and $2,075,204.02). Google claims $4,453,888.72 of revenue
-- from 29,086.2 conversions. Meta claims $2,601,953.06 from 17,849.1 purchases after a
-- click, and counts another 5,608.2 purchases after only a view, which it puts no value on.


-- Whether the Meta split adds back to the total in clean.ad_spend. Then each platform's
-- claimed revenue over the net revenue the order system found on its orders.

select
  round(
    (select sum(platform_click_conversions + platform_view_conversions)
     from `ecomrl.clean.platform_weekly` where platform = 'meta')
    - (select sum(platform_conversions)
       from `ecomrl.clean.ad_spend` where platform = 'meta'), 2) as meta_split_difference,
  round(sum(if(platform = 'google', platform_revenue_usd, 0))
        / sum(if(platform = 'google', net_revenue_usd, 0)), 3) as google_claim_over_actual,
  round(sum(if(platform = 'meta', platform_revenue_usd, 0))
        / sum(if(platform = 'meta', net_revenue_usd, 0)), 3) as meta_claim_over_actual,
  round(sum(platform_revenue_usd) / sum(net_revenue_usd), 3) as all_claim_over_actual
from `ecomrl.clean.platform_weekly`;

-- Result: the Meta split adds back to clean.ad_spend exactly, a difference of 0. For every
-- dollar of net revenue the order system finds on a platform's orders, Google claims
-- $1.178, Meta $1.254 and the two together $1.205. The platforms claim revenue before
-- refunds, so part of the gap is refunds. The rest is worked through step by step in the
-- reconciliation notebook.


-- The 51 reconciliation weeks against channel_daily, which is built by a different
-- script from the same orders. The reconciliation has to end on the same paid orders
-- and revenue the dashboard shows.

with pw as (
  select
    sum(orders) as orders,
    sum(revenue_before_refunds_usd) as revenue_before_refunds_usd,
    sum(refunded_usd) as refunded_usd,
    sum(net_revenue_usd) as net_revenue_after_refunds,
    sum(spend_usd) as spend_usd
  from `ecomrl.clean.platform_weekly`
  where in_reconciliation_period
),

cd as (
  select
    sum(orders) as orders,
    sum(net_revenue_after_refund_usd) as net_revenue_after_refunds,
    sum(spend_usd) as spend_usd
  from `ecomrl.clean.channel_daily`
  where week between date '2024-10-07' and date '2025-09-22'
    and (starts_with(channel, 'google_') or starts_with(channel, 'meta_'))
)

select
  pw.orders as paid_orders,
  cd.orders as paid_orders_in_channel_daily,
  round(pw.revenue_before_refunds_usd, 2) as revenue_before_refunds_usd,
  round(pw.refunded_usd, 2) as refunded_usd,
  round(pw.net_revenue_after_refunds, 2) as net_revenue_after_refunds,
  round(cd.net_revenue_after_refunds, 2) as net_revenue_in_channel_daily,
  round(pw.spend_usd, 2) as spend_usd,
  round(cd.spend_usd, 2) as spend_in_channel_daily
from pw
cross join cd;

-- Result: 15,280 paid orders over the 51 weeks, $2,438,753.18 before refunds, $74,271.36
-- refunded and $2,364,481.82 of net revenue, on $489,212.69 of spend. channel_daily gives
-- the same orders, net revenue and spend, so the reconciliation ends on the figures the
-- dashboard shows.


-- In January and February 2025 GA4 sent some purchases twice. If the Google and Meta
-- tags fired on the same broken event, their claims per order would jump in exactly
-- those three weeks. Each flagged week next to the range of the 48 ordinary weeks in
-- the reconciliation period.

with weekly as (
  select
    platform,
    week,
    duplicate_event_week,
    safe_divide(platform_click_conversions, orders) as claims_per_order
  from `ecomrl.clean.platform_weekly`
  where in_reconciliation_period
),

ordinary as (
  select distinct
    platform,
    percentile_cont(claims_per_order, 0.5) over (partition by platform) as ordinary_median,
    min(claims_per_order) over (partition by platform) as ordinary_min,
    max(claims_per_order) over (partition by platform) as ordinary_max
  from weekly
  where not duplicate_event_week
)

select
  w.platform,
  w.week,
  round(w.claims_per_order, 3) as claims_per_order,
  round(n.ordinary_median, 3) as ordinary_median,
  round(n.ordinary_min, 3) as ordinary_min,
  round(n.ordinary_max, 3) as ordinary_max
from weekly w
join ordinary n on n.platform = w.platform
where w.duplicate_event_week
order by w.platform, w.week;

-- Result: Google's three flagged weeks claim 1.233, 1.232 and 1.228 conversions per order,
-- against an ordinary range of 1.229 to 1.235 (median 1.231), so the last one sits just
-- below it. Meta's claim 1.226, 1.220 and 1.220, inside 1.215 to 1.227 (median 1.221). No
-- flagged week sits above the ordinary range, so the purchases GA4 sent twice don't look
-- like they reached the ad platforms.


-- ---------------------------------------------------------------------------
-- 2. journey_touches
-- ---------------------------------------------------------------------------
-- A journey is every session the same person had in the 30 days up to and including
-- the session they bought in. 30 days is Google's usual click window, which makes it a fair
-- lookback for comparing rules.
--
-- A GA4 visitor id is a browser, not a person, so a journey on visitor id alone stops
-- at the edge of one device. Any browser where the person logged in is linked to them
-- through user_id and the account map, and the browser they bought on is always
-- linked. That is as far as a GA4 export can go.
--
-- Only orders GA4 saw can have a journey: 27,947 purchasing sessions, less the 42
-- staff test orders that are not in clean.orders.
--
-- The four rules, for a journey of n sessions:
--   last click      all the credit to the session they bought in
--   first click     all the credit to the first session
--   linear          1 / n to every session
--   position based  40 percent to the first, 40 to the last and the middle 20 split
--                   evenly. A one session journey keeps all of it, and two sessions
--                   get half each

create or replace table `ecomrl.clean.journey_touches` as

with converting as (
  -- the session each real order was placed in
  select
    s.order_id,
    s.session_key as converting_session_key,
    s.user_pseudo_id as converting_visitor,
    s.session_start_ts as converting_session_start_ts,
    o.person_id,
    o.order_ts_utc,
    o.order_week,
    o.channel as order_channel,
    o.net_revenue_after_refund_usd,
    o.gross_profit_usd
  from `ecomrl.clean.sessions` s
  join `ecomrl.clean.orders` o on o.order_id = s.order_id
  where s.converted
),

visitor_person as (
  -- every browser a person was seen logged in on, plus the one they bought on
  select distinct s.user_pseudo_id, ca.person_id
  from `ecomrl.clean.sessions` s
  join `ecomrl.clean.customer_accounts` ca on ca.customer_id = s.user_id

  union distinct

  select converting_visitor, person_id
  from converting
),

touches as (
  select
    c.order_id,
    c.person_id,
    c.order_ts_utc,
    c.order_week,
    c.order_channel,
    c.net_revenue_after_refund_usd,
    c.gross_profit_usd,
    s.session_key,
    s.user_pseudo_id,
    s.user_pseudo_id != c.converting_visitor as from_another_browser,
    s.session_start_ts,
    s.channel as touch_channel,
    s.channel_group as touch_channel_group,
    s.session_key = c.converting_session_key as is_converting_session,
    timestamp_diff(c.order_ts_utc, s.session_start_ts, second) / 86400 as days_before_order
  from converting c
  join visitor_person vp on vp.person_id = c.person_id
  join `ecomrl.clean.sessions` s on s.user_pseudo_id = vp.user_pseudo_id
  where s.session_start_ts <= c.converting_session_start_ts
    and s.session_start_ts >= timestamp_sub(c.converting_session_start_ts, interval 30 day)
),

numbered as (
  select
    *,
    -- the session they bought in sorts last, even against a session that started in
    -- the same second, so last click always lands on it
    row_number() over (
      partition by order_id
      order by session_start_ts, is_converting_session, session_key) as touch_number,
    count(*) over (partition by order_id) as touches_in_journey
  from touches
)

select
  order_id,
  person_id,
  order_ts_utc,
  order_week,
  order_channel,
  net_revenue_after_refund_usd,
  gross_profit_usd,
  session_key,
  user_pseudo_id,
  from_another_browser,
  session_start_ts,
  round(days_before_order, 4) as days_before_order,
  touch_channel,
  touch_channel_group,
  is_converting_session,
  touch_number,
  touches_in_journey,

  if(touch_number = touches_in_journey, 1.0, 0.0) as credit_last_click,
  if(touch_number = 1, 1.0, 0.0) as credit_first_click,
  1.0 / touches_in_journey as credit_linear,
  case
    when touches_in_journey = 1 then 1.0
    when touches_in_journey = 2 then 0.5
    when touch_number = 1 or touch_number = touches_in_journey then 0.4
    else 0.2 / (touches_in_journey - 2)
  end as credit_position_based

from numbered;


-- One journey per GA4 order, the session they bought in always last, and every rule
-- handing out exactly one order's worth of credit per journey.

with per_order as (
  select
    order_id,
    countif(is_converting_session) as converting_sessions,
    max(if(is_converting_session, touch_number, null)) as converting_position,
    max(touches_in_journey) as touches,
    sum(credit_last_click) as last_click,
    sum(credit_first_click) as first_click,
    sum(credit_linear) as linear,
    sum(credit_position_based) as position_based
  from `ecomrl.clean.journey_touches`
  group by order_id
)

select
  (select count(*) from `ecomrl.clean.journey_touches`) as sessions_in_journeys,
  count(*) as orders,
  countif(converting_sessions != 1) as orders_without_one_converting_session,
  countif(converting_position != touches) as converting_session_not_last,
  countif(abs(last_click - 1) > 1e-9 or abs(first_click - 1) > 1e-9
       or abs(linear - 1) > 1e-9 or abs(position_based - 1) > 1e-9) as credit_not_adding_to_one,
  round(sum(last_click), 1) as last_click_total,
  round(sum(first_click), 1) as first_click_total,
  round(sum(linear), 1) as linear_total,
  round(sum(position_based), 1) as position_based_total
from per_order;

-- Result: 51,375 sessions in the journeys of 27,905 orders. Every order has exactly one
-- session it was bought in, that session is always last, and under each of the four rules
-- every journey hands out exactly one order of credit, 27,905 in all.


-- How long the journeys are, and how many reached a second browser through a login.
-- If nearly every journey were one session, every rule would give nearly the same
-- answer.

select
  case when touches_in_journey >= 5 then '5 or more'
       else cast(touches_in_journey as string) end as sessions_in_journey,
  count(distinct order_id) as orders,
  round(100 * count(distinct order_id) / sum(count(distinct order_id)) over (), 1) as pct_of_orders,
  count(distinct if(from_another_browser, order_id, null)) as orders_using_another_browser
from `ecomrl.clean.journey_touches`
group by
  case when touches_in_journey >= 5 then '5 or more'
       else cast(touches_in_journey as string) end
order by sessions_in_journey;

-- Result (orders, share of orders):
--   1 session     12,886   46.2%
--   2 sessions     7,585   27.2%
--   3 sessions     6,455   23.1%
--   4 sessions       953    3.4%
--   5 or more         26    0.1%
-- More than half the journeys have two or more sessions, so the rules have room to
-- disagree. A login linked a second browser into the journey on only 3 orders.


-- Last click in GA4 means the channel of the session they bought in. If that agrees
-- with the channel on the order, the attribution comparison can be read straight
-- across to the dashboard.

select
  countif(touch_channel = order_channel) as orders_agreeing,
  count(*) as orders,
  round(100 * countif(touch_channel = order_channel) / count(*), 2) as pct_agreeing
from `ecomrl.clean.journey_touches`
where is_converting_session;

-- Result: 27,343 of 27,905 orders agree, 97.99 percent.


-- The orders where they disagree, by pair.

select
  order_channel,
  touch_channel as ga4_session_channel,
  count(*) as orders
from `ecomrl.clean.journey_touches`
where is_converting_session and touch_channel != order_channel
group by order_channel, touch_channel
order by orders desc, order_channel, ga4_session_channel;

-- Result: 562 orders in 10 pairs. Every pair is Google on both sides or Meta on both
-- sides, with a tagged campaign on one side and the untagged bucket on the other. The
-- largest is meta_untagged on the order against meta_prospecting in GA4, 83 orders. At
-- platform level GA4 and the order system agree on every order.


-- ---------------------------------------------------------------------------
-- 3. order_journeys
-- ---------------------------------------------------------------------------
-- One row per order placed from 1 October 2024, when the GA4 export starts, to 30
-- September 2025. Orders GA4 missed are kept with their journey columns empty,
-- because the orders GA4 missed are part of the answer.
--
-- Two flags model what each platform could claim from the journey:
--   google_click_30d  a Google paid session in the 30 days before the order, inside
--                     Google's default 30 day click window
--   meta_click_7d     a Meta session in the 7 days before the order, inside Meta's
--                     default 7 day click window
-- Neither platform can see the other, so both can claim the same order, and neither
-- knows when an order came back through email or organic search.

create or replace table `ecomrl.clean.order_journeys` as

with ga4_purchases as (
  -- purchase events per order, the ones sent twice included on purpose: they are
  -- part of why GA4 and the order system differ
  select
    ecommerce.transaction_id as order_id,
    count(*) as ga4_purchase_events
  from `ecomrl.raw.events`
  where event_name = 'purchase'
  group by ecommerce.transaction_id
),

journey as (
  select
    order_id,
    max(touches_in_journey) as touches_in_journey,
    count(distinct touch_channel) as channels_in_journey,
    logical_or(from_another_browser) as used_another_browser,
    max(if(touch_number = 1, touch_channel, null)) as first_touch_channel,
    max(if(is_converting_session, touch_channel, null)) as last_touch_channel,
    logical_or(starts_with(touch_channel, 'google_') and days_before_order <= 30) as google_click_30d,
    logical_or(starts_with(touch_channel, 'meta_') and days_before_order <= 7) as meta_click_7d
  from `ecomrl.clean.journey_touches`
  group by order_id
)

select
  o.order_id,
  o.person_id,
  o.order_ts_utc,
  o.order_date,
  o.order_week,
  o.market,
  o.channel,
  o.channel_group,
  o.is_brand_search,
  o.ad_platform,
  o.net_revenue_usd as revenue_before_refunds_usd,
  o.refunded_usd,
  o.net_revenue_after_refund_usd,
  o.gross_profit_usd,

  coalesce(g.ga4_purchase_events, 0) as ga4_purchase_events,
  g.order_id is not null as seen_in_ga4,
  j.order_id is not null as has_journey,
  j.touches_in_journey,
  j.channels_in_journey,
  j.used_another_browser,
  j.first_touch_channel,
  j.last_touch_channel,
  coalesce(j.google_click_30d, false) as google_click_30d,
  coalesce(j.meta_click_7d, false) as meta_click_7d

from `ecomrl.clean.orders` o
left join ga4_purchases g on g.order_id = o.order_id
left join journey j on j.order_id = o.order_id
where o.order_date between date '2024-10-01' and date '2025-09-30';


-- Two routes into GA4, set against each other: seen_in_ga4 comes from the raw
-- purchase events, has_journey from clean.sessions.

select
  count(*) as orders,
  countif(seen_in_ga4) as seen_in_ga4,
  countif(has_journey) as with_journey,
  countif(seen_in_ga4 != has_journey) as disagreements,
  sum(ga4_purchase_events) as ga4_purchase_events,
  sum(ga4_purchase_events) - countif(seen_in_ga4) as duplicate_events,
  round(countif(seen_in_ga4) / count(*), 3) as capture_rate
from `ecomrl.clean.order_journeys`;

-- Result: 31,692 orders in the GA4 year. 27,905 were seen by GA4, the same 27,905 by both
-- routes, so 0 disagreements. They carry 28,421 purchase events, so 516 were sent twice.
-- GA4 saw 88.1 percent of the orders the order system recorded.


-- What the platforms could claim, on the orders GA4 saw. A row per platform for paid
-- orders and per channel group for the rest, with how many of its orders had a Google
-- click in the last 30 days and a Meta click in the last 7.

select
  coalesce(ad_platform, channel_group) as credited_to,
  count(*) as orders,
  countif(google_click_30d) as google_could_claim,
  countif(meta_click_7d) as meta_could_claim,
  countif(google_click_30d and meta_click_7d) as both_could_claim
from `ecomrl.clean.order_journeys`
where has_journey
group by coalesce(ad_platform, channel_group)
order by orders desc, credited_to;

-- Result (orders, Google could claim, Meta could claim, both could claim):
--   organic     8,382   1,847   1,010   249
--   google      8,247   8,247     987   987
--   meta        5,479     604   5,479   604
--   owned       3,308     994     581   150
--   affiliate   2,489     698     133     0
-- Every Google paid order had a Google click inside the window and every Meta paid order
-- a Meta click, so the journeys agree with the paid credit. The orders the organic group
-- won (organic search, direct and referral) are the biggest pool the platforms could also
-- claim: 1,847 had a Google click and 1,010 a Meta click.


-- ---------------------------------------------------------------------------
-- 4. Attribution under four rules
-- ---------------------------------------------------------------------------
-- No new table: journey_touches already carries every rule's credit.
--
-- Orders credited to each channel under each rule. Where a channel gains under first
-- click, it is opening journeys that another channel closes.

select
  touch_channel as channel,
  round(sum(credit_last_click), 2) as last_click,
  round(sum(credit_first_click), 2) as first_click,
  round(sum(credit_linear), 2) as linear,
  round(sum(credit_position_based), 2) as position_based,
  round(100 * (sum(credit_first_click) / nullif(sum(credit_last_click), 0) - 1), 1) as first_vs_last_pct
from `ecomrl.clean.journey_touches`
group by touch_channel
order by last_click desc, channel;

-- Result (orders credited under last click, first click, linear, position based, and the
-- change from last click to first click):
--   organic_search        4,550   6,735   5,831.24   5,747.66    +48.0%
--   google_nonbrand       3,562   5,493   4,704.87   4,628.04    +54.2%
--   meta_prospecting      3,472   6,290   5,122.87   5,016.65    +81.2%
--   email                 3,308   2,313   2,718.31   2,760.56    -30.1%
--   direct                2,843   1,076   1,808.23   1,874.14    -62.2%
--   google_brand          2,499     654   1,416.63   1,485.36    -73.8%
--   google_shopping       2,021   1,225   1,558.73   1,586.53    -39.4%
--   meta_retargeting      1,887     233     915.87     978.90    -87.7%
--   affiliate_coupon      1,609     339     857.02     908.65    -78.9%
--   referral                989     702     822.12     832.07    -29.0%
--   affiliate_content       880   2,560   1,861.29   1,799.64   +190.9%
--   google_paid_untagged    165     159     163.83     163.10     -3.6%
--   meta_untagged           120     126     124.00     123.70     +5.0%
-- Affiliate content, Meta Prospecting and Google Non Brand gain the most under first
-- click: they tend to open journeys. Meta Retargeting, affiliate coupon and Google Brand
-- lose the most: they tend to close journeys that something else opened.


-- The same in net revenue after refunds and gross profit. Every rule only moves credit
-- between channels, so each column has to add to the same total.

select
  touch_channel as channel,
  round(sum(net_revenue_after_refund_usd * credit_last_click), 0) as revenue_last_click,
  round(sum(net_revenue_after_refund_usd * credit_first_click), 0) as revenue_first_click,
  round(sum(net_revenue_after_refund_usd * credit_linear), 0) as revenue_linear,
  round(sum(net_revenue_after_refund_usd * credit_position_based), 0) as revenue_position_based,
  round(sum(gross_profit_usd * credit_last_click), 0) as profit_last_click,
  round(sum(gross_profit_usd * credit_first_click), 0) as profit_first_click,
  round(sum(gross_profit_usd * credit_linear), 0) as profit_linear,
  round(sum(gross_profit_usd * credit_position_based), 0) as profit_position_based
from `ecomrl.clean.journey_touches`
group by rollup (touch_channel)
order by revenue_last_click desc, channel;

-- Result: every rule credits the same $4,442,205 of net revenue and $2,771,238 of gross
-- profit, so the rules only move credit around. Gross profit by channel under last click
-- and position based:
--   organic_search        $466,929   $580,289
--   google_nonbrand       $364,376   $472,747
--   email                 $349,321   $289,646
--   meta_prospecting      $315,061   $478,299
--   direct                $295,844   $191,984
--   google_brand          $255,969   $148,995
--   google_shopping       $192,261   $148,878
--   meta_retargeting      $189,059    $97,314
--   affiliate_coupon      $133,837    $75,206
--   referral              $102,054    $86,810
--   affiliate_content      $78,579   $173,274
--   google_paid_untagged   $17,208    $16,339
--   meta_untagged          $10,739    $11,458
-- Under first click Meta Prospecting rises to $610,930 and Google Brand falls to $60,797.


-- Brand search is someone typing the shop's name. Where did the journeys that ended in
-- a brand search session begin? A one session journey begins and ends with brand
-- search, so it shows as google_brand.

select
  first_touch_channel,
  count(*) as orders,
  round(100 * count(*) / sum(count(*)) over (), 1) as pct_of_brand_orders,
  countif(touches_in_journey > 1) as multi_session_journeys
from `ecomrl.clean.order_journeys`
where has_journey and last_touch_channel = 'google_brand'
group by first_touch_channel
order by orders desc, first_touch_channel;

-- Result: 2,499 orders were bought in a brand search session. 400 of them (16.0 percent)
-- were brand search alone, every one a single session. The rest began somewhere else:
--   google_nonbrand       439   17.6%
--   organic_search        433   17.3%
--   affiliate_content     419   16.8%
--   email                 400   16.0%
--   meta_prospecting      383   15.3%
--   meta_untagged          13    0.5%
--   google_paid_untagged   11    0.4%
--   direct                  1    0.0%
-- So 84.0 percent of brand search orders started on another channel. A lot of what brand
-- search gets credited with looks like people who already knew the shop.


-- ---------------------------------------------------------------------------
-- 5. affiliate_transactions
-- ---------------------------------------------------------------------------
-- Every transaction the affiliate network reported, joined to the real order it
-- claims and, where GA4 saw it, to the session the order was placed in.
--
-- Three things decide whether a commission paid for anything:
--   credited_to                   whether the order system credits the order to this
--                                 kind of partner, to the other kind, or to another
--                                 channel entirely
--   seconds_click_to_order        how long before the order the partner click came
--   session_started_before_click  whether the person was already in the session they
--                                 bought in when they clicked the partner link, which
--                                 points to someone part way through a purchase going
--                                 to look for a code
--
-- GA4 stamps the events inside a session at fixed offsets from its start, so the time
-- of a step like reaching checkout can't be compared with the partner's click time. The
-- session start can, because it always falls before the order time.
--
-- The inner join to clean.orders drops the 25 transactions on staff test orders, which
-- carried $6.88 of commission still standing.

create or replace table `ecomrl.clean.affiliate_transactions` as

with converting as (
  select order_id, session_start_ts, channel as session_channel
  from `ecomrl.clean.sessions`
  where converted
),

refunds as (
  select order_id, min(refund_date) as first_refund_ts
  from `ecomrl.raw.refunds`
  group by order_id
)

select
  a.transaction_id,
  a.partner_id,
  a.partner_type,
  a.status,
  a.commission_usd,
  -- reversed commission was clawed back, so it is not a cost
  if(a.status != 'reversed', a.commission_usd, 0) as commission_standing_usd,
  a.order_value_usd as network_order_value_usd,
  a.click_ts,

  o.order_id,
  o.person_id,
  o.order_ts_utc,
  o.order_date,
  o.market,
  o.device,
  o.channel as order_channel,
  o.channel_group as order_channel_group,
  case
    when o.channel = concat('affiliate_', a.partner_type) then 'this partner type'
    when o.channel_group = 'affiliate' then 'the other partner type'
    else 'another channel'
  end as credited_to,
  o.order_id = cv.first_order_id as is_first_order,

  timestamp_diff(o.order_ts_utc, a.click_ts, second) as seconds_click_to_order,
  case
    when timestamp_diff(o.order_ts_utc, a.click_ts, second) < 60 then '1. under 1 minute'
    when timestamp_diff(o.order_ts_utc, a.click_ts, second) < 600 then '2. 1 to 10 minutes'
    when timestamp_diff(o.order_ts_utc, a.click_ts, second) < 3600 then '3. 10 to 60 minutes'
    when timestamp_diff(o.order_ts_utc, a.click_ts, second) < 86400 then '4. 1 to 24 hours'
    else '5. over 24 hours'
  end as click_to_order_band,

  o.net_revenue_usd as revenue_before_refunds_usd,
  o.refunded_usd,
  o.net_revenue_after_refund_usd,
  o.gross_profit_usd,
  o.refunded_usd > 0 as order_refunded,
  date_diff(date(r.first_refund_ts), o.order_date, day) as days_order_to_refund,

  c.order_id is not null as seen_in_ga4,
  c.session_channel,
  c.session_start_ts as converting_session_start_ts,
  c.session_start_ts < a.click_ts as session_started_before_click

from `ecomrl.raw.affiliates` a
join `ecomrl.clean.orders` o on o.order_id = a.order_id
join `ecomrl.clean.customer_value` cv on cv.person_id = o.person_id
left join converting c on c.order_id = o.order_id
left join refunds r on r.order_id = o.order_id;


-- Every transaction accounted for, and commission still standing equal to
-- clean.orders to the cent.

select
  partner_type,
  count(*) as transactions,
  countif(status = 'reversed') as reversed,
  round(sum(if(status = 'reversed', commission_usd, 0)), 2) as reversed_usd,
  round(sum(commission_standing_usd), 2) as commission_standing_usd,
  (select round(sum(affiliate_commission_usd), 2) from `ecomrl.clean.orders`)
    as commission_in_clean_orders,
  (select count(*) from `ecomrl.raw.affiliates`) as transactions_in_raw
from `ecomrl.clean.affiliate_transactions`
group by rollup (partner_type)
order by partner_type is null, partner_type;

-- Result: 17,344 transactions, 2,751 content and 14,593 coupon. Raw holds 17,369; the
-- other 25 are on staff test orders. 304 were reversed, $3,799.51 clawed back. Commission
-- still standing is $45,941.56 for content and $181,394.58 for coupon, $227,336.14 in
-- all, equal to clean.orders to the cent.


-- Coupon partners against content partners, side by side. The median is exact.

with medians as (
  select distinct
    partner_type,
    percentile_cont(cast(seconds_click_to_order as float64), 0.5) over (partition by partner_type)
      as median_seconds_click_to_order
  from `ecomrl.clean.affiliate_transactions`
)

select
  t.partner_type,
  count(*) as transactions,
  round(sum(t.commission_standing_usd), 2) as commission_standing_usd,
  round(100 * sum(t.commission_usd) / sum(t.network_order_value_usd), 1) as commission_rate_pct,
  round(100 * countif(t.seconds_click_to_order < 600) / count(*), 1) as pct_within_10_min,
  any_value(m.median_seconds_click_to_order) as median_seconds_click_to_order,
  round(100 * countif(t.credited_to = 'this partner type') / count(*), 1) as pct_credited_to_this_type,
  round(100 * countif(t.is_first_order) / count(*), 1) as pct_first_orders,
  round(avg(t.net_revenue_after_refund_usd), 2) as avg_order_value_after_refunds,
  round(100 * countif(t.order_refunded) / count(*), 1) as pct_orders_refunded
from `ecomrl.clean.affiliate_transactions` t
join medians m on m.partner_type = t.partner_type
group by t.partner_type
order by t.partner_type;

-- Result (coupon, then content):
--   commission rate              8.0% and 10.0% of order value
--   clicks within 10 minutes     69.8% and 2.7%
--   median click to order        435 seconds (7.25 minutes) and 7,380 seconds (123 minutes)
--   credited to that type        31.3% and 100.0%
--   first orders                 77.9% and 100.0%
--   average order after refunds  $153.17 and $163.49
--   orders refunded              3.1% and 3.3%
-- Coupon clicks mostly land a few minutes before the order, and on more than two thirds
-- of coupon transactions last click gives the order to another channel. Content clicks
-- come hours before, and every content order is credited to content.


-- How long before the order the partner click came, in bands.

select
  partner_type,
  click_to_order_band,
  count(*) as transactions,
  round(100 * count(*) / sum(count(*)) over (partition by partner_type), 1) as pct_of_type,
  round(sum(commission_standing_usd), 2) as commission_standing_usd
from `ecomrl.clean.affiliate_transactions`
group by partner_type, click_to_order_band
order by partner_type, click_to_order_band;

-- Result (share of each type's transactions):
--   coupon   under 1 minute 4.5%, 1 to 10 minutes 65.3%, 10 to 60 minutes 6.8%,
--            1 to 24 hours 23.4%
--   content  under 1 minute none, 1 to 10 minutes 2.7%, 10 to 60 minutes 20.4%,
--            1 to 24 hours 77.0%
-- No click came more than 24 hours before its order.


-- Commission travels with the order in clean.orders, so it sits on whichever channel
-- last click credited. This splits standing commission by that channel.

select
  partner_type,
  order_channel,
  count(*) as transactions,
  round(sum(commission_standing_usd), 2) as commission_standing_usd,
  round(100 * sum(commission_standing_usd)
        / sum(sum(commission_standing_usd)) over (partition by partner_type), 1) as pct_of_type_commission
from `ecomrl.clean.affiliate_transactions`
group by partner_type, order_channel
order by partner_type, commission_standing_usd desc, order_channel;

-- Result: all 2,751 content transactions are on affiliate_content orders. Of the coupon
-- commission still standing, $52,451.63 (28.9 percent, 4,569 transactions) is on orders
-- credited to affiliate_coupon. The other 71.1 percent, $128,942.95 on 10,024
-- transactions, is on orders last click gives to another channel: organic search
-- $25,324.83, Google Non Brand $20,614.53, Meta Prospecting $15,616.97, email $14,789.41,
-- direct $14,237.14, Google Brand $13,449.18, Google Shopping $9,920.27, Meta Retargeting
-- $7,643.73, referral $5,657.04 and the two untagged buckets $973.22 and $716.63.


-- On the transactions whose order GA4 saw: had the person already started the session
-- they bought in when they clicked the partner link?

select
  partner_type,
  credited_to,
  count(*) as transactions,
  countif(seen_in_ga4) as transactions_seen_in_ga4,
  countif(seen_in_ga4 and session_started_before_click) as session_started_before_click,
  round(100 * safe_divide(countif(seen_in_ga4 and session_started_before_click),
                          countif(seen_in_ga4)), 1) as pct_session_started_before_click
from `ecomrl.clean.affiliate_transactions`
group by partner_type, credited_to
order by partner_type, credited_to;

-- Result (transactions GA4 saw, and the share where the session had already started):
--   coupon on an order credited to another channel   3,728   94.8%
--   coupon on an order credited to coupon             1,609   10.8%
--   content                                             880   11.8%
-- When a coupon click comes on an order another channel won, the person was nearly
-- always already in the session they bought in. That looks like shoppers part way
-- through a purchase going off to find a code, rather than coupon sites bringing them in.


-- Commission still standing on orders that were later refunded, and how long after the
-- order the refund came.

select
  partner_type,
  count(*) as transactions,
  round(sum(commission_standing_usd), 2) as commission_standing_usd,
  round(avg(days_order_to_refund), 1) as avg_days_to_refund,
  min(days_order_to_refund) as fewest_days_to_refund,
  max(days_order_to_refund) as most_days_to_refund,
  countif(days_order_to_refund > 30) as refunded_after_30_days
from `ecomrl.clean.affiliate_transactions`
where order_refunded and status != 'reversed'
group by rollup (partner_type)
order by partner_type is null, partner_type;

-- Result: 530 transactions with $7,903.14 still standing are on orders that were later
-- refunded, 443 coupon ($6,132.28) and 87 content ($1,770.86). The refunds came 4 to 44
-- days after the order, 23.8 days on average, and 190 of them more than 30 days after.


-- What two changes to the commission terms would have saved over the three years, from
-- commission still standing:
--   Pay on credit   pay coupon partners only on orders the order system credits to them
--   Refund hold     hold commission for 45 days after the order and drop it if the order
--                   is refunded in that time. Every refund here came within 44 days, so
--                   this catches every refunded order
--   Both together   the two at once, each transaction counted once

select
  round(sum(if(partner_type = 'coupon' and credited_to != 'this partner type',
               commission_standing_usd, 0)), 2) as pay_on_credit,
  round(sum(if(order_refunded, commission_standing_usd, 0)), 2) as refund_hold,
  round(sum(if((partner_type = 'coupon' and credited_to != 'this partner type') or order_refunded,
               commission_standing_usd, 0)), 2) as both_together,
  round(sum(commission_standing_usd), 2) as commission_standing_total
from `ecomrl.clean.affiliate_transactions`;

-- Result: Pay on credit would have saved $128,942.95 and Refund hold $7,903.14. Together
-- they come to $132,606.99 of the $227,336.14 still standing, 58.3 percent, or about
-- $44,202 a year over the three years. Together is $4,239.10 less than the two added up,
-- because that much is coupon commission on refunded orders another channel won, which
-- both terms cover. Content partners are touched only by Refund hold, on the $1,770.86
-- standing on their refunded orders.
