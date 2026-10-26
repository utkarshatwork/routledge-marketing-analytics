-- 01_load_and_checks.sql
--
-- Checks that the ten raw tables in ecomrl.raw loaded completely and hang together,
-- before anything is built on them. Nothing here changes data. Section 0 holds one
-- statement, commented out, that is only needed straight after a fresh load of the
-- GA4 files.
--
-- Tables: orders, order_items, customers, refunds, google_ads, meta_ads, affiliates,
-- fx, promos, and events (the GA4 export, loaded from four quarterly files into one
-- table).


-- ---------------------------------------------------------------------------
-- 0. GA4 events: put the nested columns back into the standard shape
-- ---------------------------------------------------------------------------
-- When the GA4 Parquet files are loaded through the BigQuery console, the lists inside
-- event_params and items can arrive wrapped one level deeper than usual
-- (event_params.list[].element.key instead of event_params[].key). UNNEST then fails
-- with "Values referenced in UNNEST must be arrays". The statement below rewrites the
-- table once into the standard GA4 export shape. No values change.
--
-- It is commented out so the file runs from top to bottom on a table that already has
-- the standard shape, where it would fail because event_params.list doesn't exist.
-- Use it only straight after loading the four GA4 files, and only if a query below
-- that reads event_params fails with that UNNEST error: take the "-- " off the start
-- of each line of the statement, run it on its own, then run the rest of the file.

-- create or replace table `ecomrl.raw.events` as
-- select
--   event_date,
--   event_timestamp,
--   event_name,
--   user_pseudo_id,
--   user_id,
--   device,
--   geo,
--   traffic_source,
--   array(
--     select as struct
--       p.element.key   as key,
--       p.element.value as value
--     from unnest(event_params.list) as p
--   ) as event_params,
--   array(
--     select as struct
--       i.element.item_id      as item_id,
--       i.element.item_name    as item_name,
--       i.element.price_in_usd as price_in_usd,
--       i.element.quantity     as quantity
--     from unnest(items.list) as i
--   ) as items,
--   ecommerce
-- from `ecomrl.raw.events`;


-- ---------------------------------------------------------------------------
-- 1. Row counts and date ranges
-- ---------------------------------------------------------------------------

select 'orders' as table_name, count(*) as row_count,
       cast(min(order_ts_utc) as date) as first_date,
       cast(max(order_ts_utc) as date) as last_date
from `ecomrl.raw.orders`
union all
select 'order_items', count(*), cast(null as date), cast(null as date)
from `ecomrl.raw.order_items`
union all
select 'customers', count(*), cast(min(signup_date) as date), cast(max(signup_date) as date)
from `ecomrl.raw.customers`
union all
select 'refunds', count(*), cast(min(refund_date) as date), cast(max(refund_date) as date)
from `ecomrl.raw.refunds`
union all
select 'google_ads', count(*), min(report_date), max(report_date)
from `ecomrl.raw.google_ads`
union all
select 'meta_ads', count(*), min(report_date), max(report_date)
from `ecomrl.raw.meta_ads`
union all
select 'affiliates', count(*), cast(min(click_ts) as date), cast(max(click_ts) as date)
from `ecomrl.raw.affiliates`
union all
select 'fx', count(*), min(rate_date), max(rate_date)
from `ecomrl.raw.fx`
union all
select 'promos', count(*), min(start_date), max(end_date)
from `ecomrl.raw.promos`
union all
select 'events', count(*), parse_date('%Y%m%d', min(event_date)), parse_date('%Y%m%d', max(event_date))
from `ecomrl.raw.events`
order by table_name;

-- Result:
--   affiliates      17,369   2022-10-01 to 2025-09-30
--   customers       58,432   2022-10-01 to 2025-09-30
--   events       6,009,850   2024-10-01 to 2025-09-30
--   fx               3,288   2022-10-01 to 2025-09-30
--   google_ads       9,864   2022-10-01 to 2025-09-30
--   meta_ads        19,728   2022-10-01 to 2025-09-30
--   order_items    134,284
--   orders          76,058   2022-10-01 to 2025-09-30
--   promos              12   2022-11-20 to 2025-09-24
--   refunds          2,390   2022-10-09 to 2025-10-09
-- Refunds run nine days past the last order, which is normal: a refund comes after
-- the order it belongs to.


-- The GA4 export covers one year. A day with no rows at all would only show up as a
-- gap in the count of days.

select
  count(*) as events,
  count(distinct event_date) as days_with_events,
  date_diff(parse_date('%Y%m%d', max(event_date)), parse_date('%Y%m%d', min(event_date)), day) + 1
    as days_in_range
from `ecomrl.raw.events`;

-- Result: 6,009,850 events on 363 days out of 365. Two days are missing completely.
-- Which two, and what they do to the numbers, is in 02_data_audit.sql.


-- Rolling the events up into sessions, the way the clean layer does, to make sure the
-- nested columns read properly.

select
  count(distinct concat(user_pseudo_id, '-', cast(session_id as string))) as sessions,
  count(distinct user_pseudo_id) as browsers
from (
  select
    user_pseudo_id,
    (select p.value.int_value from unnest(event_params) as p where p.key = 'ga_session_id') as session_id
  from `ecomrl.raw.events`
);

-- Result: 1,264,269 sessions from 1,233,851 browsers.


-- ---------------------------------------------------------------------------
-- 2. Keys: anything in twice
-- ---------------------------------------------------------------------------
-- A duplicated key nearly always means a file was loaded twice.

select 'orders: order_id' as key_checked, count(*) - count(distinct order_id) as duplicates
from `ecomrl.raw.orders`
union all
select 'customers: customer_id', count(*) - count(distinct customer_id)
from `ecomrl.raw.customers`
union all
select 'refunds: refund_id', count(*) - count(distinct refund_id)
from `ecomrl.raw.refunds`
union all
select 'affiliates: transaction_id', count(*) - count(distinct transaction_id)
from `ecomrl.raw.affiliates`
union all
select 'google_ads: day and campaign',
       count(*) - count(distinct concat(cast(report_date as string), campaign_id))
from `ecomrl.raw.google_ads`
union all
select 'meta_ads: day, campaign and ad set',
       count(*) - count(distinct concat(cast(report_date as string), campaign_name, adset_name))
from `ecomrl.raw.meta_ads`
union all
select 'fx: day and currency', count(*) - count(distinct concat(cast(rate_date as string), currency))
from `ecomrl.raw.fx`
union all
select 'promos: promo_code', count(*) - count(distinct promo_code)
from `ecomrl.raw.promos`
order by key_checked;

-- Result: 0 duplicates on all eight.


-- ---------------------------------------------------------------------------
-- 3. Do the tables join up
-- ---------------------------------------------------------------------------

select 'order_items with no order' as check_name, count(*) as rows_found
from `ecomrl.raw.order_items` i
left join `ecomrl.raw.orders` o on o.order_id = i.order_id
where o.order_id is null
union all
select 'refunds with no order', count(*)
from `ecomrl.raw.refunds` r
left join `ecomrl.raw.orders` o on o.order_id = r.order_id
where o.order_id is null
union all
select 'orders with no customer', count(*)
from `ecomrl.raw.orders` o
left join `ecomrl.raw.customers` c on c.customer_id = o.customer_id
where c.customer_id is null
union all
select 'affiliate transactions with no order', count(*)
from `ecomrl.raw.affiliates` a
left join `ecomrl.raw.orders` o on o.order_id = a.order_id
where o.order_id is null
union all
select 'orders with a promo code not in promos', count(*)
from `ecomrl.raw.orders` o
left join `ecomrl.raw.promos` p on p.promo_code = o.promo_code
where o.promo_code is not null and p.promo_code is null
union all
select 'orders with no order lines', count(*)
from `ecomrl.raw.orders` o
left join (select distinct order_id from `ecomrl.raw.order_items`) i on i.order_id = o.order_id
where i.order_id is null
order by check_name;

-- Result: 0 on everything except orders with no order lines, which is 140. An order
-- with nothing on it isn't a real order; 02_data_audit.sql shows what they are.


-- ---------------------------------------------------------------------------
-- 4. Empty values
-- ---------------------------------------------------------------------------

select
  count(*) as orders,
  countif(customer_id is null) as customer_id_empty,
  countif(order_ts_utc is null) as order_ts_empty,
  countif(net_revenue_usd is null) as net_revenue_empty,
  countif(device is null) as device_empty,
  countif(utm_source is null) as utm_source_empty,
  countif(utm_medium is null) as utm_medium_empty,
  countif(utm_campaign is null) as utm_campaign_empty,
  round(100 * countif(utm_campaign is null) / count(*), 1) as utm_campaign_empty_pct,
  countif(promo_code is null) as promo_code_empty,
  round(100 * countif(promo_code is null) / count(*), 1) as promo_code_empty_pct
from `ecomrl.raw.orders`;

-- Result: nothing empty except utm_campaign, on 24,033 orders (31.6 percent), and
-- promo_code, on 56,756 (74.6 percent). Both make sense: most orders aren't placed
-- in a sale, and organic and direct visits have no campaign to record.


select
  utm_medium,
  count(*) as orders,
  countif(utm_campaign is null) as no_campaign,
  round(100 * countif(utm_campaign is null) / count(*), 1) as pct_no_campaign
from `ecomrl.raw.orders`
group by utm_medium
order by orders desc;

-- Result: organic and (none) carry no campaign on any order, as unpaid traffic does. Referral
-- is missing one on 67.3 percent, because one content partner sends its traffic as
-- referral with a campaign while the real referral sites send none. Every paid and
-- tagged medium is missing a campaign on 1.7 to 2.2 percent of orders: 775 paid orders,
-- 136 email and 119 affiliate. Those are clicks whose tag got lost.
--   cpc 286 of 15,357, paid_social 270 of 12,093, email 136 of 7,517,
--   affiliate 119 of 5,955, CPC 114 of 5,433, shopping 61 of 2,832,
--   paid-social 44 of 2,521, referral 2,767 of 4,114


select
  (select countif(email is null) from `ecomrl.raw.customers`) as customer_email_empty,
  (select countif(market is null or country is null) from `ecomrl.raw.customers`) as customer_market_empty,
  (select countif(order_id is null or refund_amount_usd is null) from `ecomrl.raw.refunds`)
    as refund_fields_empty,
  (select countif(order_id is null or commission_usd is null or status is null) from `ecomrl.raw.affiliates`)
    as affiliate_fields_empty,
  (select countif(user_id is not null) from `ecomrl.raw.events`) as events_with_user_id,
  (select countif(event_name = 'purchase' and ecommerce.transaction_id is null) from `ecomrl.raw.events`)
    as purchases_with_no_order_id;

-- Result: 0 empty on every one of these. 389,167 events carry a logged in user_id.


-- ---------------------------------------------------------------------------
-- 5. Do the money columns hold together
-- ---------------------------------------------------------------------------

select
  countif(net_revenue_usd <= 0) as non_positive_revenue,
  countif(net_revenue_usd > gross_revenue_usd) as net_above_gross,
  countif(abs(gross_revenue_usd - discount_usd - net_revenue_usd) > 0.005)
    as gross_less_discount_off_by_a_cent,
  countif(abs(gross_revenue_usd - discount_usd - net_revenue_usd) > 0.011) as gross_less_discount_off_by_more,
  countif(discount_usd > 0 and abs(gross_revenue_usd - discount_usd - net_revenue_usd) > 0.005)
    as of_those_discounted,
  countif(abs(net_revenue_local * fx_rate_used - net_revenue_usd) > 0.011)
    as local_times_rate_off_by_more_than_a_cent,
  countif(discount_usd < 0 or product_cost_usd < 0 or shipping_cost_usd < 0
          or payment_fee_usd < 0 or tax_usd < 0) as negative_amounts,
  min(net_revenue_usd) as smallest_order_usd,
  max(net_revenue_usd) as largest_order_usd
from `ecomrl.raw.orders`;

-- Result: no zero or negative revenue, no net above gross, no negative amounts.
-- Gross less discount comes out a cent away from net on 322 orders, all of them
-- discounted, and never more than a cent, which points to the discount being rounded
-- separately from the order total. Local
-- amount times the rate matches the USD amount to within a cent on every order. Orders
-- run from $0.01 to $1,008.60. The $0.01 orders are looked at in 02_data_audit.sql.


-- The rate used on each order against the finance rate table for that day.

select
  o.local_currency,
  count(*) as orders,
  countif(f.rate_to_usd is null) as no_rate_that_day,
  countif(abs(o.fx_rate_used - f.rate_to_usd) > 0.000001) as rate_differs
from `ecomrl.raw.orders` o
left join `ecomrl.raw.fx` f
  on f.rate_date = date(o.order_ts_utc)
 and f.currency = o.local_currency
group by o.local_currency
order by o.local_currency;

-- Result: EUR 15,094, GBP 19,152, USD 41,812 orders, and every one used exactly the
-- finance rate for that day.


-- Order lines against the order total.

with line_totals as (
  select order_id, sum(line_total_usd) as lines_total, count(*) as lines
  from `ecomrl.raw.order_items`
  group by order_id
)
select
  count(*) as orders_with_lines,
  countif(abs(o.net_revenue_usd - l.lines_total) > 0.05) as lines_off_by_more_than_5_cents,
  countif(o.item_count != l.lines) as item_count_not_lines
from `ecomrl.raw.orders` o
join line_totals l on l.order_id = o.order_id;

-- Result: all 75,918 orders that have lines match their total to within five cents, and
-- item_count always equals the number of lines. The cent level differences are in
-- 02_data_audit.sql.


-- ---------------------------------------------------------------------------
-- 6. Ad platforms, exchange rates and promotions are complete
-- ---------------------------------------------------------------------------
-- Does every campaign or ad set have a row on every day, and every currency a rate on
-- every day?

select 'google_ads' as source, count(distinct report_date) as days,
       count(distinct campaign_id) as campaigns_or_ad_sets, count(*) as row_count
from `ecomrl.raw.google_ads`
union all
select 'meta_ads', count(distinct report_date),
       count(distinct concat(campaign_name, adset_name)), count(*)
from `ecomrl.raw.meta_ads`
union all
select 'fx', count(distinct rate_date), count(distinct currency), count(*)
from `ecomrl.raw.fx`;

-- Result: complete. Google 9 campaigns on all 1,096 days (9,864 rows), Meta 18 ad sets
-- on all 1,096 days (19,728), fx 3 currencies on all 1,096 days (3,288).


select 'google' as platform, market, currency, reporting_timezone, count(*) as row_count
from `ecomrl.raw.google_ads`
group by market, currency, reporting_timezone
union all
select 'meta', market, currency, reporting_timezone, count(*)
from `ecomrl.raw.meta_ads`
group by market, currency, reporting_timezone
order by platform, market;

-- Result: Google bills US and ROW in USD and UK in GBP, all on UTC. Meta bills US in
-- USD, UK in GBP and ROW in EUR, all on America/Los_Angeles. So spend has to be
-- converted before it means anything, and the two platforms' days don't start at the
-- same moment.


select
  currency,
  min(rate_to_usd) as lowest_rate,
  max(rate_to_usd) as highest_rate
from `ecomrl.raw.fx`
group by currency
order by currency;

-- Result: EUR 1.00337 to 1.06350, GBP 1.21999 to 1.32991, USD always 1.


select promo_name, promo_code, start_date, end_date, discount_pct
from `ecomrl.raw.promos`
order by start_date;

-- Result: four sales, run every year on the same dates.
--   black_friday      20 November to 2 December     30 percent
--   new_year           3 January to 18 January      15 percent
--   mid_year          20 May to 10 June             15 percent
--   back_to_college    8 August to 24 September     20 percent


select count(*) as overlapping_sale_windows
from `ecomrl.raw.promos` a
join `ecomrl.raw.promos` b
  on a.promo_id < b.promo_id
 and a.start_date <= b.end_date
 and b.start_date <= a.end_date;

-- Result: 0. No two sales run at the same time.
