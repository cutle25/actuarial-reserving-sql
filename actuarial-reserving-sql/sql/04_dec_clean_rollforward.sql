-- ============================================================
-- 04  Clean the 2025-12-31 extract, roll the triangle forward, actual vs expected
-- Run after 02 and 03. New objects use the suffix _dec; the June views stay as they are
-- because the actual-vs-expected comparison needs the June projection.
-- ============================================================

-- 1. payments_dec_clean: apply the payment treatments from the issues log

drop view if exists payments_dec_clean;
create view payments_dec_clean as
with formatted_payments as(
	Select
		n.payment_id, 
		n.claim_id, 
		case when n.payment_date like '__/__/____' 
		     then substr(n.payment_date, 7, 4) || '-' || substr(n.payment_date, 1, 2) || '-' || substr(n.payment_date, 4, 2)
		     else n.payment_date end as payment_date,	--treatment from issue: payment dates stored as MM/DD/YYYY
		coalesce(o.amount, n.amount) as amount --treatment from issue: payment T00099's amount changed from june to dec data
	from payments_dec25 as n
	left join payments as o on o.payment_id = n.payment_id
),
--treatment from issue: 20 payments were entered twice with different payment_id but matching (claim_id, payment_date, amount)
marked_dups as (
    select
        *,
        row_number() over (partition by claim_id, payment_date, amount order by payment_id) as rn
    from formatted_payments
)
	select
	    payment_id,
	    claim_id,
	    payment_date,
	    amount
	from marked_dups
	where rn = 1;

select *
from payments_dec_clean;

-- re-run the payment control reconciliation on the clean view: every diff should be 0
drop view if exists reconcile_check_dec;
CREATE view reconcile_check_dec as
with pay as (                                   -- payments by payment year
    select
        substr(payment_date, 1, 4) as period,                        
        count(*) as n,
        sum(amount) as amt
    from payments_dec_clean
    group by period
)
	select p.period,
	       p.n as n_extract, 
	       round(p.amt, 2) as amt_extract,
	       c.n_records as n_control, 
	       c.total_amount as amt_control,
	       p.n - c.n_records as n_diff,
	       round(p.amt - c.total_amount, 2) as amt_diff
	from pay as p
	join control_totals_dec25 as c on c.table_name = 'payments' and c.period = p.period;

select * 
from reconcile_check_dec;


-- 2. Views clean_policies_dec, claims_dec_clean, valid_claims_dec
drop view if exists clean_policies_dec;
CREATE view clean_policies_dec as
--Policy rows repeated. 12 policy_id duplicates
	SELECT DISTINCT 
		policy_id,
		upper(state) as state, --treatment from issue: State values in lower case in policies
		exposure,
		annual_premium
	from policies_dec25;
select 
	count(*)
from clean_policies_dec;


drop view if exists claims_dec_clean;
create view claims_dec_clean as -- treatment from issue:Claim moved to another policy
	SELECT 
		v.claim_id,
		coalesce(c.policy_id, v.policy_id) as policy_id,
		coalesce(c.loss_date, v.loss_date) as loss_date,
		v.paid_amount
	from claims_dec25 as v
	left join claims as c on v.claim_id = c.claim_id;  
select count(*) from claims_dec_clean;

--clean claims table and calculate accident year
drop view if exists valid_claims_dec;
create view valid_claims_dec as
	Select
		c.claim_id,
		c.policy_id,
		p.state,
		c.loss_date,
		cast(substr(c.loss_date, -4) as integer) as AY,
		c.paid_amount
	FROM claims_dec_clean as c 
	JOIN clean_policies_dec as p on c.policy_id = p.policy_id -- treatment from issue: claims have policy_id not in the policy table
	where c.paid_amount >= 0;    -- treatment from issue: Claims with negative paid_amount

select * from valid_claims_dec;
select 
	state,
	count(claim_id) as n_claims,
	round(sum(paid_amount), 2) as total_paid
from valid_claims_dec
group by state;



-- 3. Roll the triangle forward one diagonal
--   Table dev_ages_dec (age): 6, 12, 18, 24, 30, 36.
drop table if exists dev_ages_dec;
create table dev_ages_dec (age integer primary key);
	insert into dev_ages_dec (age) values (6), (12), (18), (24), (30), (36);

--   View payment_ages_dec: same columns as payment_ages, evaluation date 2025-12-31, built on valid_claims_dec and payments_dec_clean.
drop view if exists payment_ages_dec;
create view payment_ages_dec as
	select
		p.payment_id,
		c.claim_id,
		c.AY,
        (cast(strftime('%Y', p.payment_date) as integer) - c.AY) * 12 + cast(strftime('%m', p.payment_date) as integer) as age,
        p.amount
	from valid_claims_dec as c
	join  payments_dec_clean as p on c.claim_id = p.claim_id
	where p.payment_date <= '2025-12-31';

select 
	count(*)
from payment_ages_dec;

--   View cum_paid_dec (ay, age, cum_paid): observed cells only at 2025-12-31: AY 2023 ages 6-36, AY 2024 ages 6-24, AY 2025 ages 6-12 (12 rows), unrounded.
drop view if exists cum_paid_dec;
create view cum_paid_dec as
	select
		p.AY,
		a.age,
		sum(case when p.age <= a.age then p.amount else 0 end) as cum_paid
	from payment_ages_dec as p
	cross join dev_ages_dec as a
	where a.age <= (2025 - p.AY) * 12 + 12
	group by p.AY, a.age;

select *
from cum_paid_dec;

-- 4. Did the June cells move? (cleaned December data should reproduce every June cell)
--   9 rows, one per cell of the June triangle (cum_paid): ay, age, june_cum, dec_cum, diff (dec - june), money 2 dp, sorted by ay, age.
drop view if exists move_check;
create view move_check as
	select 
		   o.ay, 
		   o.age,
	       round(o.cum_paid, 2) as june_cum,
	       round(n.cum_paid, 2) as dec_cum,
	       round(n.cum_paid - o.cum_paid, 2) as diff
	from cum_paid as o
	join cum_paid_dec as n on n.ay = o.ay and n.age = o.age;

select * from move_check order by ay, age;
SELECT 
	sum(abs(diff)) as diff_sum
from move_check;

-- 5. Actual vs expected, July-December 2025
--   One query, 3 rows, one per AY. Columns: ay, june_age, dec_age
--     paid_june      paid to date at 2025-06-30
--     expected       paid expected in Jul-Dec 2025 by the June chain-ladder projection (tail 1.000)
--     actual         paid in Jul-Dec 2025 per the cleaned December data
--     a_minus_e      actual - expected
--     a_to_e         actual / expected, 3 dp (NULL where expected is 0)

with e as (
  select 
  		p.ay, 
  		p.age as old_age, 
  		p.paid_to_date,
        p.paid_to_date * (s.selected - 1) as expected
  from cl_projection as p
  join selected_factors as s on s.from_age = p.age
)
select 
	e.ay, 
	e.old_age as june_age, 
	n.age as dec_age, 
	e.paid_to_date as paid_june,
    round(e.expected, 2) as expected,
    round(n.cum_paid - e.paid_to_date, 2) as actual, 
    round(n.cum_paid - e.paid_to_date - e.expected, 2) as a_minus_e,
    round((n.cum_paid - e.paid_to_date) /NULLIF(e.expected, 0), 3) as a_to_e
from e
join cum_paid_dec as n
  on n.ay = e.ay and n.age = e.old_age + 6;

