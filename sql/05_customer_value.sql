-- 05_customer_value.sql
--
-- Builds ecomrl.clean.customer_value: one row per person, holding everything the
-- customer analysis needs, so nothing later has to piece a customer together from
-- orders again.
--
--   who they are         market, opt in, accounts held
--   how they arrived     first order, its channel (the acquisition channel), device,
--                        and whether it fell in a sale and used the code
--   what they are worth  lifetime orders, revenue and gross profit, and the same for
--                        the twelve months after their own first order
--   where they are now   recency, RFM scores, RFM group and lifecycle stage, measured
--                        to 30 September 2025, the last day of the data
--
-- Twelve month value is measured from each person's own first order, so everyone gets
-- the same length of time to come back. People whose first order was after 30 September
-- 2024 haven't had twelve months yet, so they are flagged with has_full_12m = false
-- rather than dropped. Any twelve month average should use has_full_12m people only.
--
-- Revenue is net revenue after discounts and refunds. Gross profit is after the books,
-- delivery, payment fees, refunds and affiliate commission, but before ad spend.
--
-- Reads clean.orders, clean.customers and raw.promos, and clean.channel_daily in one
-- check, so run 04_reporting_tables.sql first. Run from top to bottom.


-- ---------------------------------------------------------------------------
-- 1. customer_value
-- ---------------------------------------------------------------------------
-- The first order is found by numbering each person's orders by time, with order_id
-- breaking a tie on the same timestamp. channel_daily and campaign_weekly count new
-- customers the same way, so the three tables agree on who was acquired where.
--
-- The sale a first order fell in comes straight from raw.promos. The four sales never
-- overlap, so an order matches one sale at most.
--
-- RFM scores, each from 1 to 5:
--   R  days since the last order. Cut into fifths, the most recent fifth scores 5
--   F  orders placed. Fixed bands: 1 order, 2, 3, 4 or 5, 6 or more. Fifths don't work
--      here, because most people have one order and a fifth would split them
--   M  lifetime gross profit. Cut into fifths, the highest fifth scores 5
--
-- Cutting into fifths has to keep ties together, or two people with the same value
-- could land in different scores just because of row order. So each person gets the
-- average rank of everyone sharing their value (rank() plus half the extra ties), that
-- is turned into a share of all people, and the score is the fifth the share falls in.
--
-- The ten RFM groups come from R and F, checked in the order written, first match wins.
-- M ranks people within a group rather than defining one, because it moves almost in
-- step with F. The groups roll up into four lifecycle stages for CRM.

create or replace table `ecomrl.clean.customer_value` as

with orders_numbered as (
  select
    o.*,
    row_number() over (partition by o.person_id order by o.order_ts_utc, o.order_id) as order_number
  from `ecomrl.clean.orders` o
),

first_order as (
  select
    f.person_id,
    f.order_id as first_order_id,
    f.order_ts_utc as first_order_ts,
    f.order_date as first_order_date,
    f.channel as acquisition_channel,
    f.channel_group as acquisition_channel_group,
    f.market,
    f.device as first_order_device,
    f.used_promo as acquired_on_promo,
    p.promo_name is not null as first_order_in_sale_window,
    p.promo_name as first_order_sale_name,
    f.net_revenue_after_refund_usd as first_order_net_revenue_usd,
    f.gross_profit_usd as first_order_gross_profit_usd,
    f.discount_usd as first_order_discount_usd,
    -- an affiliate is paid per sale, so for the two affiliate channels this is what the
    -- customer cost to win
    f.affiliate_commission_usd as first_order_commission_usd
  from orders_numbered f
  left join `ecomrl.raw.promos` p
    on f.order_date between p.start_date and p.end_date
  where f.order_number = 1
),

totals as (
  select
    o.person_id,
    count(*) as orders,
    countif(o.used_promo) as orders_with_promo,
    max(o.order_date) as last_order_date,
    sum(o.net_revenue_after_refund_usd) as revenue_usd,
    sum(o.gross_profit_usd) as gross_profit_usd,

    -- the same, counting only the 365 days from the first order
    countif(o.order_ts_utc < timestamp_add(f.first_order_ts, interval 365 day)) as orders_12m,
    sum(if(o.order_ts_utc < timestamp_add(f.first_order_ts, interval 365 day),
           o.net_revenue_after_refund_usd, 0)) as revenue_12m_usd,
    sum(if(o.order_ts_utc < timestamp_add(f.first_order_ts, interval 365 day),
           o.gross_profit_usd, 0)) as gross_profit_12m_usd
  from `ecomrl.clean.orders` o
  join first_order f on f.person_id = o.person_id
  group by o.person_id
),

people as (
  select
    f.person_id,
    f.first_order_date,
    date_trunc(f.first_order_date, month) as cohort_month,
    f.acquisition_channel,
    f.acquisition_channel_group,
    f.market,
    f.first_order_device,
    f.acquired_on_promo,

    t.orders,
    t.orders_12m,
    t.orders_with_promo,
    t.last_order_date,
    round(t.revenue_usd, 2) as revenue_usd,
    round(t.gross_profit_usd, 2) as gross_profit_usd,
    round(t.revenue_12m_usd, 2) as revenue_12m_usd,
    round(t.gross_profit_12m_usd, 2) as gross_profit_12m_usd,

    t.orders > 1 as is_repeat_customer,
    t.orders_12m > 1 as repeated_within_12m,
    f.first_order_date <= date '2024-09-30' as has_full_12m,

    c.marketing_opt_in,
    c.accounts_held,

    f.first_order_id,
    f.first_order_in_sale_window,
    f.first_order_sale_name,
    case
      when f.acquired_on_promo then 'sale, used the code'
      when f.first_order_in_sale_window then 'sale period, full price'
      else 'outside any sale'
    end as first_order_price_group,
    round(f.first_order_net_revenue_usd, 2) as first_order_net_revenue_usd,
    round(f.first_order_gross_profit_usd, 2) as first_order_gross_profit_usd,
    round(f.first_order_discount_usd, 2) as first_order_discount_usd,
    round(f.first_order_commission_usd, 2) as first_order_commission_usd,

    date_diff(date '2025-09-30', t.last_order_date, day) as recency_days
  from first_order f
  join totals t on t.person_id = f.person_id
  join `ecomrl.clean.customers` c on c.person_id = f.person_id
),

scored as (
  select
    p.*,
    -- fewer days since the last order is better, so recency is ranked from most days
    -- to fewest
    cast(ceil(
      (rank() over (order by p.recency_days desc)
        + (count(*) over (partition by p.recency_days) - 1) / 2)
      / count(*) over () * 5) as int64) as r_score,
    case
      when p.orders = 1 then 1
      when p.orders = 2 then 2
      when p.orders = 3 then 3
      when p.orders <= 5 then 4
      else 5
    end as f_score,
    -- BigQuery can't partition by a decimal column, so ties on gross profit are found
    -- on the same value in whole cents
    cast(ceil(
      (rank() over (order by p.gross_profit_usd)
        + (count(*) over (partition by cast(round(p.gross_profit_usd * 100) as int64)) - 1) / 2)
      / count(*) over () * 5) as int64) as m_score
  from people p
),

grouped as (
  select
    s.*,
    concat(cast(s.r_score as string), cast(s.f_score as string), cast(s.m_score as string))
      as rfm_score,
    case
      when s.r_score >= 4 and s.f_score >= 4 then 'Champions'
      when s.r_score >= 3 and s.f_score >= 3 then 'Loyal'
      when s.r_score >= 4 and s.f_score = 2 then 'Potential loyalists'
      when s.r_score = 5 and s.f_score = 1 then 'New customers'
      when s.r_score = 4 and s.f_score = 1 then 'Promising'
      when s.r_score = 3 and s.f_score = 2 then 'Needs attention'
      when s.r_score = 3 and s.f_score = 1 then 'About to sleep'
      when s.r_score <= 2 and s.f_score >= 3 then 'At risk'
      when s.r_score <= 2 and s.f_score = 2 then 'Hibernating'
      when s.r_score <= 2 and s.f_score = 1 then 'Lost'
    end as rfm_group
  from scored s
)

select
  g.*,
  case
    when g.rfm_group in ('New customers', 'Promising') then 'New'
    when g.rfm_group in ('Champions', 'Loyal', 'Potential loyalists') then 'Active repeat'
    when g.rfm_group in ('Needs attention', 'About to sleep') then 'Cooling'
    when g.rfm_group in ('At risk', 'Hibernating', 'Lost') then 'Lapsed'
  end as lifecycle_stage
from grouped g;


-- ---------------------------------------------------------------------------
-- 2. Does it add up?
-- ---------------------------------------------------------------------------
-- One row per person, nobody lost in the joins, and the money back to clean.orders.

select
  count(*) as rows_built,
  count(distinct person_id) as people,
  (select count(*) from `ecomrl.clean.customers`) as people_in_customers,
  sum(orders) as orders,
  round(sum(revenue_usd), 2) as net_revenue_after_refunds,
  round(sum(gross_profit_usd), 2) as gross_profit_usd,
  countif(has_full_12m) as mature_customers,
  countif(has_full_12m and repeated_within_12m) as mature_repeaters,
  round(100 * countif(has_full_12m and repeated_within_12m) / countif(has_full_12m), 1)
    as repeat_rate_12m_pct,
  countif(is_repeat_customer) as ever_ordered_twice,
  round(100 * countif(is_repeat_customer) / count(*), 1) as ever_ordered_twice_pct,
  countif(marketing_opt_in) as opted_in,
  round(100 * countif(marketing_opt_in) / count(*), 1) as opted_in_pct
from `ecomrl.clean.customer_value`;

-- Result: 58,101 rows, one per person, the same as clean.customers. 75,918 orders,
-- $11,907,875.43 of net revenue and $7,421,060.08 of gross profit, equal to clean.orders
-- to the cent. 36,569 people have had a full twelve months, and 7,175 of them ordered
-- again inside it: a twelve month repeat rate of 19.6 percent. 13,035 people (22.4
-- percent) have ever ordered twice, but that figure has no fixed window, so 19.6 is the
-- repeat rate to quote. 37,183 people (64.0 percent) are opted in to marketing email.


-- The first order checked a second way: against each person's earliest order time,
-- and against the new customers channel_daily counts by channel.

with earliest as (
  select person_id, min(order_ts_utc) as earliest_ts
  from `ecomrl.clean.orders`
  group by person_id
),

people_by_channel as (
  select acquisition_channel as channel, count(*) as people
  from `ecomrl.clean.customer_value`
  group by acquisition_channel
),

daily_by_channel as (
  select channel, sum(new_customers) as new_customers
  from `ecomrl.clean.channel_daily`
  group by channel
),

by_channel as (
  select
    coalesce(p.channel, d.channel) as channel,
    coalesce(p.people, 0) as people,
    coalesce(d.new_customers, 0) as new_customers_in_channel_daily
  from people_by_channel p
  full outer join daily_by_channel d on d.channel = p.channel
)

select
  (select count(*) from `ecomrl.clean.customer_value` cv
   join `ecomrl.clean.orders` o on o.order_id = cv.first_order_id
   join earliest e on e.person_id = cv.person_id
   where o.order_ts_utc != e.earliest_ts or o.person_id != cv.person_id)
    as first_orders_not_the_earliest,
  (select count(*) from by_channel where people != new_customers_in_channel_daily)
    as channels_disagreeing_with_channel_daily,
  (select sum(people) from by_channel) as people;

-- Result: 0 and 0 across 58,101 people. Every first order is the person's earliest, and
-- new customers by channel match channel_daily on all 13 channels.


-- ---------------------------------------------------------------------------
-- 3. Value by acquisition channel
-- ---------------------------------------------------------------------------
-- Twelve months of value from the first order, mature customers only, by the channel
-- that brought each person in. Split into the first order and everything after it,
-- because that split shows where the gap between channels comes from.

select
  acquisition_channel,
  count(*) as customers,
  round(100 * countif(repeated_within_12m) / count(*), 1) as repeat_rate_12m_pct,
  round(avg(orders_12m), 2) as orders_per_customer_12m,
  round(avg(revenue_12m_usd), 2) as revenue_per_customer_12m,
  round(avg(gross_profit_12m_usd), 2) as gross_profit_per_customer_12m,
  round(avg(first_order_gross_profit_usd), 2) as first_order_gross_profit,
  round(avg(gross_profit_12m_usd) - avg(first_order_gross_profit_usd), 2) as later_orders_gross_profit
from `ecomrl.clean.customer_value`
where has_full_12m
group by acquisition_channel
order by gross_profit_per_customer_12m desc;

-- Result (customers, repeat rate, 12 month gross profit, of which first order and later
-- orders):
--   referral              1,407   29.8%   $140.44   $100.96   $39.48
--   organic_search        6,418   28.9%   $134.75    $97.90   $36.85
--   google_nonbrand       6,204   26.6%   $134.66   $102.22   $32.44
--   google_brand          3,187   26.5%   $131.65    $99.72   $31.93
--   google_paid_untagged    261   23.0%   $131.12   $104.24   $26.88
--   direct                2,470   26.6%   $129.32    $96.79   $32.53
--   affiliate_content     1,749   26.5%   $121.39    $86.88   $34.52
--   email                 1,388   20.3%   $118.95    $94.03   $24.92
--   google_shopping       3,289   14.9%   $112.19    $95.24   $16.95
--   meta_retargeting      1,823    6.9%    $97.26    $91.29    $5.97
--   meta_prospecting      5,779    4.5%    $92.94    $87.99    $4.95
--   meta_untagged           156    5.8%    $87.36    $83.21    $4.15
--   affiliate_coupon      2,438    2.5%    $81.95    $79.19    $2.76
-- First orders run from $79.19 to $104.24 a customer, later orders from $2.76 to $39.48,
-- so more of the gap between channels opens after the first order than on it. Customers
-- won through Meta or coupon sites rarely come back.


-- ---------------------------------------------------------------------------
-- 4. Customers first acquired in a sale
-- ---------------------------------------------------------------------------
-- Three groups by how the first order was priced: it used a sale code, it fell on a
-- sale day but paid full price, or it was on an ordinary day. People counted across
-- the whole base, value on mature customers only.

select
  first_order_price_group,
  count(*) as people,
  round(100 * count(*) / sum(count(*)) over (), 1) as pct_of_people,
  countif(has_full_12m) as mature,
  round(100 * countif(has_full_12m) / sum(countif(has_full_12m)) over (), 1) as pct_of_mature,
  round(avg(if(has_full_12m, first_order_net_revenue_usd, null)), 2) as first_order_aov_after_refunds,
  round(avg(if(has_full_12m, first_order_discount_usd, null)), 2) as first_order_discount,
  round(avg(if(has_full_12m, first_order_gross_profit_usd, null)), 2) as first_order_gross_profit,
  round(100 * countif(has_full_12m and repeated_within_12m) / countif(has_full_12m), 1)
    as repeat_rate_12m_pct,
  round(avg(if(has_full_12m, gross_profit_12m_usd, null)), 2) as gross_profit_12m
from `ecomrl.clean.customer_value`
group by first_order_price_group
order by people desc;

-- Result (people, share, mature, share; then on mature customers: first order value after
-- refunds, discount, first order gross profit, repeat rate, 12 month gross profit):
--   outside any sale          36,263  62.4%  22,996  62.9%  $159.59   $0.00  $102.47  19.3%  $126.01
--   sale, used the code       15,247  26.2%   9,447  25.8%  $124.32  $32.12   $71.06  18.0%   $92.54
--   sale period, full price    6,591  11.3%   4,126  11.3%  $167.37   $0.00  $106.06  24.9%  $138.97
-- Customers whose first order used a code are worth less over twelve months, $92.54
-- against $126.01, and most of the gap is that first order: smaller, discounted, and
-- $71.06 of gross profit against $102.47. After it they come back nearly as often, 18.0
-- against 19.3 percent. People who bought on a sale day without the code are worth the
-- most of the three.


-- The groups only make sense if a sale code is never used outside a sale.

select
  countif(acquired_on_promo and not first_order_in_sale_window) as first_orders_code_outside_sale,
  (select count(*)
   from `ecomrl.clean.orders` o
   left join `ecomrl.raw.promos` p
     on o.order_date between p.start_date and p.end_date
   where o.used_promo and p.promo_name is null) as orders_code_outside_sale
from `ecomrl.clean.customer_value`;

-- Result: 0 and 0. A code was never used outside a sale, so the three groups cover
-- everyone.


-- ---------------------------------------------------------------------------
-- 5. RFM
-- ---------------------------------------------------------------------------
-- What each score means in days, orders and dollars, and how many people hold it.

select 'R, days since last order' as measure, r_score as score, count(*) as people,
  round(100 * count(*) / sum(count(*)) over (), 1) as pct_of_people,
  cast(min(recency_days) as float64) as lowest, cast(max(recency_days) as float64) as highest
from `ecomrl.clean.customer_value`
group by r_score

union all

select 'F, orders placed', f_score, count(*),
  round(100 * count(*) / sum(count(*)) over (), 1),
  cast(min(orders) as float64), cast(max(orders) as float64)
from `ecomrl.clean.customer_value`
group by f_score

union all

select 'M, lifetime gross profit', m_score, count(*),
  round(100 * count(*) / sum(count(*)) over (), 1),
  min(gross_profit_usd), max(gross_profit_usd)
from `ecomrl.clean.customer_value`
group by m_score

order by measure, score desc;

-- Result:
--   R  5: 0 to 123 days, 4: 124 to 284, 3: 285 to 469, 2: 470 to 733, 1: 734 to 1,095.
--      Each score holds 20.0 percent of people (11,604 to 11,634).
--   F  1 order 45,066 people (77.6 percent), 2 orders 9,519, 3 orders 2,547, 4 or 5
--      orders 923, 6 or more 46. Nobody has more than 7.
--   M  5: $195.16 to $1,030.55, 4: $115.45 to $195.15, 3: $71.69 to $115.44,
--      2: $46.68 to $71.68, 1: -$378.16 to $46.67. Each score holds 20.0 percent.
-- More than three quarters of customers have bought once, which is why F uses fixed
-- bands. A second order alone puts someone in the top 22.4 percent.


-- Ties kept together: each column is the most scores that any single value of that
-- measure received.

select
  (select max(n) from (select count(distinct r_score) as n from `ecomrl.clean.customer_value`
                       group by recency_days)) as most_r_scores_per_value,
  (select max(n) from (select count(distinct f_score) as n from `ecomrl.clean.customer_value`
                       group by orders)) as most_f_scores_per_value,
  (select max(n) from (select count(distinct m_score) as n from `ecomrl.clean.customer_value`
                       group by cast(round(gross_profit_usd * 100) as int64)))
    as most_m_scores_per_value;

-- Result: 1, 1 and 1. No value of any measure was split across two scores.


-- The ten groups: how many people, what they are worth over their lifetime, and how
-- many CRM is allowed to email.

select
  lifecycle_stage,
  rfm_group,
  count(*) as people,
  round(100 * count(*) / sum(count(*)) over (), 1) as pct_of_people,
  round(avg(orders), 2) as avg_orders,
  round(avg(gross_profit_usd), 2) as gross_profit_per_person,
  round(100 * sum(gross_profit_usd) / sum(sum(gross_profit_usd)) over (), 1) as pct_of_gross_profit,
  countif(marketing_opt_in) as opted_in,
  round(100 * countif(marketing_opt_in) / count(*), 1) as opted_in_pct
from `ecomrl.clean.customer_value`
group by lifecycle_stage, rfm_group
order by
  case lifecycle_stage
    when 'Active repeat' then 1 when 'New' then 2 when 'Cooling' then 3 else 4 end,
  gross_profit_per_person desc;

-- Result (people, share of people, average orders, lifetime gross profit per person,
-- share of gross profit, opted in, opt in rate):
--   Active repeat  Champions              772   1.3%  4.33  $490.96   5.1%     509  65.9%
--   Active repeat  Loyal                2,355   4.1%  3.08  $338.23  10.7%   1,540  65.4%
--   Active repeat  Potential loyalists  4,898   8.4%  2.00  $208.12  13.7%   3,071  62.7%
--   New            Promising            7,910  13.6%  1.00   $99.65  10.6%   5,099  64.5%
--   New            New customers        7,941  13.7%  1.00   $88.95   9.5%   5,063  63.8%
--   Cooling        Needs attention      2,078   3.6%  2.00  $199.16   5.6%   1,344  64.7%
--   Cooling        About to sleep       8,913  15.3%  1.00   $89.07  10.7%   5,656  63.5%
--   Lapsed         At risk                389   0.7%  3.13  $344.89   1.8%     246  63.2%
--   Lapsed         Hibernating          2,543   4.4%  2.00  $209.83   7.2%   1,603  63.0%
--   Lapsed         Lost                20,302  34.9%  1.00   $91.42  25.0%  13,052  64.3%
-- Champions and Loyal together are 5.4 percent of people and 15.8 percent of gross
-- profit. Lost is the largest group, people whose one order was 470 or more days ago, and
-- still holds a quarter of gross profit because there are so many of them. A second
-- order roughly doubles what a customer is worth: Potential loyalists $208.12 against
-- $88.95 to $99.65 for the one order groups. Opt in barely moves between groups, 62.7 to
-- 65.9 percent.


-- The four lifecycle stages, which is the level the CRM plan works at.

select
  lifecycle_stage,
  count(*) as people,
  round(100 * count(*) / sum(count(*)) over (), 1) as pct_of_people,
  countif(marketing_opt_in) as opted_in,
  round(avg(gross_profit_usd), 2) as gross_profit_per_person,
  round(100 * sum(gross_profit_usd) / sum(sum(gross_profit_usd)) over (), 1) as pct_of_gross_profit
from `ecomrl.clean.customer_value`
group by lifecycle_stage
order by
  case lifecycle_stage
    when 'New' then 1 when 'Active repeat' then 2 when 'Cooling' then 3 else 4 end;

-- Result (people, share, opted in, gross profit per person, share of gross profit):
--   New             15,851  27.3%  10,162   $94.29  20.1%
--   Active repeat    8,025  13.8%   5,120  $273.51  29.6%
--   Cooling         10,991  18.9%   7,000  $109.89  16.3%
--   Lapsed          23,234  40.0%  14,901  $108.63  34.0%
-- 37,183 people CRM can email in all. The 15,851 in New have one order, placed in the
-- last 284 days. Lapsed is the largest stage, 40.0 percent of people.


-- ---------------------------------------------------------------------------
-- 6. Retention by month since the first order
-- ---------------------------------------------------------------------------
-- The share of people who order in each month after their first. Month 0 is the month
-- of the first order. A person only counts towards a month once they have lived
-- through it (September 2025 is the last month in the data), so recent customers
-- don't drag the later months down. Built per person, so a month in which nobody from
-- a cohort ordered still counts its people as eligible.

with months as (
  select m
  from unnest(generate_array(0, 12)) as m
),

eligible as (
  select
    mo.m as month_index,
    count(*) as people_eligible
  from `ecomrl.clean.customer_value` cv
  cross join months mo
  where date_add(cv.cohort_month, interval mo.m month) <= date '2025-09-01'
  group by mo.m
),

active as (
  select
    date_diff(o.order_month, cv.cohort_month, month) as month_index,
    count(distinct o.person_id) as people_active
  from `ecomrl.clean.orders` o
  join `ecomrl.clean.customer_value` cv on cv.person_id = o.person_id
  where date_diff(o.order_month, cv.cohort_month, month) between 0 and 12
  group by date_diff(o.order_month, cv.cohort_month, month)
)

select
  e.month_index,
  coalesce(a.people_active, 0) as people_active,
  e.people_eligible,
  round(100 * coalesce(a.people_active, 0) / e.people_eligible, 2) as active_pct
from eligible e
left join active a on a.month_index = e.month_index
order by e.month_index;

-- Result (percent of people ordering in each month since their first order):
--   month    0       1     2     3     4     5     6     7     8     9    10    11    12
--   active   100.00  0.63  1.18  1.66  1.95  2.06  2.25  2.28  2.35  2.30  2.19  2.19  2.14
-- Month 1 is 347 of 55,195 people and month 12 is 784 of 36,569, which is exactly the
-- number of people with a full twelve months. The month straight after a first order is
-- the quietest. The share climbs to a peak in month 8 and eases off, which fits the
-- academic year: people come back for a later term, not the next month.
