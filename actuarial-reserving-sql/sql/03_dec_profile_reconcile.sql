-- ============================================================
-- 03  New extract at 2025-12-31: profile it and reconcile to control totals
-- Run after 01_load_2025-12-31.sql. Findings are written up in issues_log.md.
-- ============================================================

-- 1. One row per raw table: June rows, December rows, rows added, distinct keys in December.
DROP VIEW IF EXISTS data_count;
CREATE VIEW data_count AS
	-- policies: policies vs policies_dec25
	SELECT
	    'policies' AS table_name,
	    (SELECT COUNT(*) FROM policies) AS june_rows,
	    (SELECT COUNT(*) FROM policies_dec25) AS dec_rows,
	    (SELECT COUNT(*) FROM policies_dec25) - (SELECT COUNT(*) FROM policies) AS new_rows,
	    (SELECT COUNT(DISTINCT policy_id) FROM policies_dec25) AS dec_distinct_keys

	UNION ALL
	-- claims: claims vs claims_dec25
	SELECT
	    'claims' AS table_name,
	    (SELECT COUNT(*) FROM claims) AS june_rows,
	    (SELECT COUNT(*) FROM claims_dec25) AS dec_rows,
	    (SELECT COUNT(*) FROM claims_dec25) - (SELECT COUNT(*) FROM claims) AS new_rows,
	    (SELECT COUNT(DISTINCT claim_id) FROM claims_dec25) AS dec_distinct_keys

	UNION ALL
	-- payments: payments vs payments_dec25
	SELECT
	    'payments' AS table_name,
	    (SELECT COUNT(*) FROM payments) AS june_rows,
	    (SELECT COUNT(*) FROM payments_dec25) AS dec_rows,
	    (SELECT COUNT(*) FROM payments_dec25) - (SELECT COUNT(*) FROM payments) AS new_rows,
	    (SELECT COUNT(DISTINCT payment_id) FROM payments_dec25) AS dec_distinct_keys;

SELECT *
from data_count;


-- 2. Date layouts
-- Query 1: one row per payment_date layout in payments_dec25, plus 'other' for anything unexpected.
drop view if exists dec_payment_layouts;
create view dec_payment_layouts as
	select
		case when payment_date like '____-__-__' then 'YYYY-MM-DD'
			 when payment_date like '__/__/____' then 'MM/DD/YYYY'   
			 else 'other' end as layout,
		count(*) as n_rows,
		min(payment_id) as first_payment_id,
		max(payment_id) as last_payment_id,
		min(payment_date) as min_value,
		max(payment_date) as max_value
	from payments_dec25
	group by layout;

select *
from dec_payment_layouts;

-- Query 2: all 275 rows are M/D/YYYY, as in June and as the README says. Not an issue.
drop view if exists dec_claim_layouts;
create view dec_claim_layouts as
	select
		case when loss_date like '____-__-__' then 'YYYY-MM-DD'
			 when loss_date like '%/%/____' then 'M/D/YYYY'   
			 else 'other' end as layout,
		count(*) as n_rows,
		min(loss_date) as min_value,
		max(loss_date) as max_value
	from claims_dec25
	group by layout;

select *
from dec_claim_layouts;


-- 3. Reconcile to the control totals. One row per control line: payment years 2023-2025, then claims, then policies.

drop view if exists control_compare;
create view control_compare as
with pay as (                                   -- payments by payment year
    select
        case when payment_date like '__/__/____' then substr(payment_date, 7, 4)  
             else substr(payment_date, 1, 4) end as period,                        
        count(*) as n,
        sum(amount) as amt
    from payments_dec25
    group by period
),
clm as (                                        -- all claims: count and paid to date
    select 'claims' as period, count(*) as n, sum(paid_amount) as amt
    from claims_dec25
),
pol as (                                        -- distinct policies (no amount on the control line)
    select 'policies' as period, count(distinct policy_id) as n
    from policies_dec25
)
-- Payments
select p.period,
       p.n as n_extract, round(p.amt, 2) as amt_extract,
       c.n_records as n_control, c.total_amount as amt_control,
       p.n - c.n_records as n_diff,
       round(p.amt - c.total_amount, 2) as amt_diff
from pay as p
join control_totals_dec25 as c
  on c.table_name = 'payments' and c.period = p.period  

union all
-- Claims
select m.period,
       m.n, round(m.amt, 2),
       c.n_records, c.total_amount,
       m.n - c.n_records,
       round(m.amt - c.total_amount, 2)
from clm as m
join control_totals_dec25 as c on c.table_name = 'claims'

union all
-- Policies (amount columns NULL: the control has a count only)
select o.period,
       o.n, null,
       c.n_records, null,
       o.n - c.n_records,
       null
from pol as o
join control_totals_dec25 as c on c.table_name = 'policies';

select *
from control_compare;


-- 4. Repeated payments
-- Query 1: payments_dec25 rows that match on claim_id, payment_date and amount and occur more than once.
-- Result: 20 groups, all dated October 2025; copies are T00498-T00517 at the end of the file.
drop view if exists repeat_payments_check;
create view repeat_payments_check as
	select
	   claim_id, payment_date, amount,
	   count(*) as n,
       min(payment_id) as first_id,
       max(payment_id) as last_id
	from payments_dec25
	group by claim_id, payment_date, amount
	having count(*) > 1;

select *
from repeat_payments_check;

-- Query 2: number of extra rows (beyond one per group) and their total amount.
-- Result: 20 rows, 64,072.83 = the 2025 n_diff and amt_diff in section 3 exactly.
SELECT
    SUM(n - 1) AS extra_rows,
    round(SUM((n - 1) * amount), 2) AS extra_amount
FROM repeat_payments_check;


-- 5. Did history change?
-- Query 1: payments in both payments and payments_dec25 whose claim_id, payment_date or amount changed.
-- Result: T00099 (C00182, 2024-04-01) 2,958.53 in June -> 9,258.53 in December (+6,300.00 = the 2024 amt_diff in section 3).
drop view if exists history_1;
create view history_1 as
	select
		o.payment_id,
		o.claim_id as june_claim_id, n.claim_id as dec_claim_id,
		o.payment_date as june_date, n.payment_date as dec_date,
		o.amount as june_amount, n.amount as dec_amount,
		round(n.amount - o.amount, 2) as amount_change
	from payments as o
	join payments_dec25 as n on n.payment_id = o.payment_id
	where o.claim_id is not n.claim_id
   		or o.payment_date is not n.payment_date
   		or o.amount is not n.amount;

select *
from history_1;

-- Query 2: claims in both claims and claims_dec25 whose policy_id or loss_date changed.
-- Result: C00053 (loss 2/14/2024) moved from P00745 to P00475.
drop view if exists history_2;
create view history_2 as
	select
		o.claim_id,
		o.policy_id as june_policy_id, n.policy_id as dec_policy_id,
		o.loss_date as june_loss_date, n.loss_date as dec_loss_date
	from claims as o
	join claims_dec25 as n on n.claim_id = o.claim_id
	where o.policy_id is not n.policy_id      
   		or o.loss_date is not n.loss_date;

select *
from history_2;

-- Query 3: June payments missing from payments_dec25. Result: 0.
select
	count(o.payment_id)
from payments as o
left join payments_dec25 as n on n.payment_id = o.payment_id
where n.payment_id is null;

-- Query 4: June claims missing from claims_dec25. Result: 0.
select
	count(o.claim_id)
from claims as o
left join claims_dec25 as n on n.claim_id = o.claim_id
where n.claim_id is null;

-- Query 5: state and start_date of every policy in query 2.
-- Result: P00745 TX starts 2023-11-22 (before the 2/14/2024 loss); P00475 GA starts 2024-06-05 (after it).
-- June policy, looked up in policies
select
	o.june_policy_id as policy_id,
	p.state as state,
	p.start_date as start_date
from history_2 as o
join policies as p on o.june_policy_id = p.policy_id

UNION ALL
-- December policy, looked up in policies_dec25   
select
	o.dec_policy_id as policy_id,
	p.state as state,
	p.start_date as start_date
from history_2 as o
join policies_dec25 as p on o.dec_policy_id = p.policy_id;


-- 6. Do claims and payments agree?
-- Query 1: claims in claims_dec25 whose payments in payments_dec25 do not add up to paid_amount
--          (a claim with no payments counts as 0 paid).
-- Result: 20 claims: the 19 claims in the repeated October rows (C00269 twice) + C00182 (+6,300.00).
--         claims_dec25 agrees with the control totals, so the payments table is the one that is off.
with p as (             -- payment total per claim in payments_dec25
	select
		claim_id,
		sum(amount) as pmt_total              
	from payments_dec25
	group by claim_id
)
select
	c.claim_id,
	c.paid_amount,
	round(coalesce(p.pmt_total, 0), 2) as payments_total,
	round(coalesce(p.pmt_total, 0) - c.paid_amount, 2) as diff
from claims_dec25 as c                          
left join p on p.claim_id = c.claim_id           
where abs(coalesce(p.pmt_total, 0) - c.paid_amount) > 0.005 
order by c.claim_id;

-- Query 2: payments_dec25 rows whose claim_id is not in claims_dec25. Result: 0.
select
	count(*)                                   
from payments_dec25 as o
left join claims_dec25 as n on n.claim_id = o.claim_id
where n.claim_id is null;

-- Query 3: claims_dec25 rows with no payment in payments_dec25. Result: 2 (C00257, C00274).
select
	count(*)                                  
from claims_dec25 as o
left join payments_dec25 as n on n.claim_id = o.claim_id
where n.claim_id is null;

