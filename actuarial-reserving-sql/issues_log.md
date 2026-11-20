# Issues log: extract at 2025-12-31

Each issue is a cause, not a symptom. Every treatment lives in a view (see `sql/04_dec_clean_rollforward.sql`); the raw tables are never edited, so the same fixes re-apply to the next extract.

## Carried over from the 2025-06-30 extract

| # | Issue | How found | Rows / $ affected | Evidence | Treatment | Impact if untreated | Status |
|---|---|---|---|---|---|---|---|
| 1 | Policy rows repeated | June check rerun on December: 3,012 rows vs 3,000 distinct policy_id | 12 rows | Same 12 policies as June. Control total: 3,000 unique policies. | `clean_policies_dec`: `select distinct` with `upper(state)`, as in June | Claims on these policies join twice | Fixed |
| 2 | State values in lower case | June check rerun on December: `state <> upper(state)` | 15 rows | Same count as June | `clean_policies_dec`: `upper(state)` | Repeated policies look distinct; grouping by state gives a separate lower-case group | Fixed |
| 3 | Claims whose policy_id is not in the policy table (orphans) | June check rerun on December: C00111, C00113, C00162, C00193, C00247 | 5 claims, 15,431.01 paid | Same 5 claims as June. C00162 is both an orphan and negative. | `valid_claims_dec`: inner join to `clean_policies_dec` drops them | Paid total overstated by claims with no policy | Fixed |
| 4 | Claims with negative paid_amount | June check rerun on December: C00060, C00118, C00132, C00135, C00162, C00190 | 6 claims, -48,955.66 | Same 6 claims as June | `valid_claims_dec`: `paid_amount >= 0` | Paid total understated | Fixed |

## New in the 2025-12-31 extract

| # | Issue | How found | Rows / $ affected | Evidence | Treatment | Impact if untreated | Status |
|---|---|---|---|---|---|---|---|
| 5 | Payment dates stored as MM/DD/YYYY | Date layout profile: 20 rows match `__/__/____` | 20 rows, 79,060.15 | The extract notes promise YYYY-MM-DD; the other 497 rows comply. All 20 are dated 12/01–12/31/2025. | `payments_dec_clean`: rewrite to YYYY-MM-DD | `strftime` returns NULL, so the age is NULL and these 20 payments drop out of the triangle with no error. December 2025 paid, and the Jul–Dec actual, understated by 79,060.15. | Fixed |
| 6 | 20 payments loaded twice with new payment_ids | Control reconciliation: 2025 row off by +20 rows, +64,072.83. Grouping on (claim_id, payment_date, amount): 20 groups with n = 2. | 20 rows, 64,072.83 | Extra rows and amount equal the 2025 control difference exactly. All in October 2025; copies appended at the end of the file. | `payments_dec_clean`: `row_number()` over (claim_id, payment_date, amount) ordered by payment_id, keep the first. Expected: 2025 control ties in count and amount. | Jul–Dec actual overstated by 64,072.83; 19 claims' payments no longer add up to their paid_amount | Fixed |
| 7 | Historical payment restated (T00099) | Comparing payments present in both extracts: 2,958.53 in June, 9,258.53 in December | 1 payment, +6,300.00 | Claim C00182: December payments are 6,300.00 more than its paid_amount in the claims table. The 2024 control total agrees with the June value. | `payments_dec_clean`: left join June payments on payment_id, `coalesce(june.amount, dec.amount)`. Expected: 2024 control ties. | AY 2024 is +6,300 at every age from 6 on, so the June triangle cells appear to move and the AY 2024 actual is inflated | Fixed |
| 8 | Claim moved to another policy (C00053) | Comparing claims present in both extracts: policy P00745 in June, P00475 in December | 1 claim, 18,427.97 paid | Loss date 2/14/2024. P00745 (TX) started 2023-11-22, before the loss; P00475 (GA) started 2024-06-05, after it, so it cannot have covered the loss. | `claims_dec_clean`: left join June claims on claim_id, `coalesce(june.policy_id, dec.policy_id)`, applied before any view uses policy_id | TX understated and GA overstated by 18,427.97. No effect on the triangle, which has no state dimension. | Fixed |

## Checked, no action needed

| # | Observation | How found | Rows | Evidence | Treatment | Impact |
|---|---|---|---|---|---|---|
| 9 | Two claims with no payments (C00257, C00274) | Claims left-joined to payments | 2 claims, 0.00 | Both new since June with paid_amount 0; claims and payments agree. Reported, not yet paid. | None | None |
| 10 | Claim loss_date is M/D/YYYY | Date layout profile: all 275 rows | 275 rows | Documented in the extract notes; same as June | AY taken from `substr(loss_date, -4)` | None, as long as loss dates are never compared or sorted as text |

## Result after treatment
Payments reconcile to the source system's control totals in every payment year (count and amount differences all 0), claims tie at 275 / 1,928,942.81, and the cleaned December data reproduces every cell of the June triangle exactly.
