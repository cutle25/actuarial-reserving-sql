-- ============================================================
-- 02  Reserving at 2025-06-30: clean data -> paid triangle -> chain-ladder
-- Run after 00_load_2025-06-30.sql. Every fix is a view; raw tables are untouched.
-- ============================================================

--Clean policies table
drop view if exists clean_policies;
create view clean_policies as
	SELECT DISTINCT
		policy_id,
		upper(state) as state,
		exposure,
		annual_premium
	from policies;
select
	count(*)
from clean_policies;

--clean claims table and calculate accident year
drop view if exists valid_claims;
create view valid_claims as
	SELECT
		c.claim_id,
		c.policy_id,
		p.state,
		c.loss_date,
		cast(substr(c.loss_date, -4) as integer) as AY,
		c.paid_amount
	FROM claims as c
	JOIN clean_policies as p on c.policy_id = p.policy_id
	where c.paid_amount >= 0;

select
	count(*)
from valid_claims;

--calculate payment ages based on dates from payments and accident year
drop view if exists payment_ages;
create view payment_ages as
	select
		p.payment_id,
		c.claim_id,
		c.AY,
        (cast(strftime('%Y', p.payment_date) as integer) - c.AY) * 12 + cast(strftime('%m', p.payment_date) as integer) as age,
        p.amount
	from valid_claims as c
	join payments as p on c.claim_id = p.claim_id
	where p.payment_date <= '2025-06-30';

select
	count(*)
from payment_ages;

-- create table for age comparison
drop table if exists dev_ages;
create table dev_ages (age integer primary key);
	insert into dev_ages (age) values (6), (12), (18), (24), (30);

SELECT
	count(*)
from dev_ages;

--for all claims in an accident year, sum payments made on or before comparison age
drop view if exists cum_paid;
create view cum_paid as
	select
		p.AY,
		a.age,
		sum(case when p.age <= a.age then p.amount else 0 end) as cum_paid
	from payment_ages as p
	cross join dev_ages as a
	where a.age <= (2025 - p.AY) * 12 + 6
	group by p.AY, a.age;

select *
from cum_paid;


--calculate the change in cumulative amount paid as age increases for each accident year
drop view if exists ata_factors;
create view ata_factors as
	select
		AY,
		from_age,
		to_age,
		prev_cum,
		cum_paid,
		1.0 * cum_paid / prev_cum as factor
--inner query so prev_cum can be referenced
	from (
		select
			AY,
			lag(age) over (partition by AY order by age) as from_age,
			age as to_age,
			lag(cum_paid) over (partition by AY order by age) as prev_cum,
			cum_paid
		from cum_paid
	) as w
	where prev_cum is not null;

select *
from ata_factors;


--calculate volume weighted average factor or how much of the pool is represented by the band
drop view if exists selected_factors;
create view selected_factors as
	select
		from_age,
		to_age,
		sum(cum_paid) * 1.0 / sum(prev_cum) as selected
	from ata_factors
	group by from_age, to_age
	union all
	select 30, 'ult', 1.0;

select *
from selected_factors
order by from_age;

--calculate CDF which is the product of the factors from the row to the end row.
drop view if exists cdf_by_age;
create view cdf_by_age as
	SELECT
		from_age as age,
		exp(sum(ln(selected)) over (order by from_age desc rows between unbounded preceding and current row)) as cdf,
		1/(exp(sum(ln(selected)) over (order by from_age desc rows between unbounded preceding and current row))) as pct_paid

	from selected_factors;

SELECT *
from cdf_by_age
order by age;

-- projection table takes a date, then groups by accident year, then calculate (as of date):age, cumulative paid as of. then projects CDF, %paid, ultimate, and reserve
drop view if exists cl_projection;
create view cl_projection as
--cte to calculate and save age relative to comparison date
with latest as (
	select
		AY,
		age,
		cum_paid as paid_to_date
	from cum_paid
	where age = (2025 - AY) * 12 + 6
)
	SELECT
		l.AY,
		l.age,
		l.paid_to_date as paid_to_date,
		round(c.cdf, 4) as cdf,
		round(c.pct_paid, 4) as percentage_paid,
		round(l.paid_to_date * c.cdf, 2) as ultimate,
		round(l.paid_to_date * c.cdf - l.paid_to_date, 2) as reserve

	FROM latest as l
	join cdf_by_age as c on c.age = l.age;


select *
from cl_projection
order by AY;


-- sum projections for the portfolio
SELECT
	round(sum(paid_to_date), 2) as total_paid,
	round(sum(ultimate), 2) as total_ultimate,
	round(sum(reserve), 2) as total_reserve
from cl_projection;

--calculate the number of policies that began in each 6 month period
WITH formatted_policies AS (
    SELECT
        policy_id,
        CAST(strftime('%Y', start_date) AS INTEGER) AS start_year,
        CASE WHEN CAST(strftime('%m', start_date) AS INTEGER) <= 6 THEN 'H1' ELSE 'H2' END AS half
    FROM policies
)
SELECT
    start_year,
    half,
    COUNT(DISTINCT policy_id) AS n_policies
FROM formatted_policies
GROUP BY start_year, half
ORDER BY start_year, half;
