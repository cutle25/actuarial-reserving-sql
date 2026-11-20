# Paid loss reserving in SQL: chain-ladder, a new data drop, and actual vs expected

A reserving workflow in SQLite on a **synthetic** personal auto book (3,000 policies, 2023–2024 written, no new business after 2024-12-31). It estimates unpaid claims at 2025-06-30 with the chain-ladder method, then takes a second extract at 2025-12-31, finds and fixes the data problems in it, rolls the triangle forward and tests the June projection against what was actually paid.

**Main finding:** chain-ladder overstated the latest accident year. Six months later, AY 2025 paid about half of what the June projection expected (actual / expected 0.52), which supports the reason identified in June: the book stopped writing, so the second half of 2025 had far fewer policies in force than the years the development factor came from.

## Questions
1. At 2025-06-30, how much is still to be paid on claims that have already happened, by accident year?
2. When a new extract arrives at 2025-12-31, can it be trusted? What is wrong with it, and how is it fixed?
3. How good was the June projection?

## Data
Synthetic data, not real policyholders. The data and its planted errors were generated for this exercise with an AI assistant; the problems in the December extract were not disclosed to me in advance and had to be found by profiling. All SQL in `sql/02`–`sql/04` and the issues log are my own work.

| Extract | policies | claims | payments | notes |
|---|---|---|---|---|
| 2025-06-30 | 3,012 rows | 251 | 391 | duplicate policies, lower-case states, orphan and negative claims |
| 2025-12-31 | 3,012 rows | 275 | 517 | plus control totals from the source system; undisclosed errors |

Column definitions: `data/2025-06-30/data_dictionary.txt`, `data/2025-12-31/extract_notes.txt`.

## Method
1. **Clean (views, raw tables untouched):** deduplicate policies, upper-case states, keep claims that have a policy and a non-negative paid amount.
2. **Paid triangle:** each payment gets a development age in months from the start of its accident year; cumulative paid by accident year (AY) at ages 6, 12, 18, 24, 30.
3. **Chain-ladder:** age-to-age factors, volume-weighted averages, tail factor 1.000, cumulative development factors, ultimate = paid to date × CDF, reserve = ultimate − paid.
4. **New extract:** compare row counts and keys, profile date layouts, reconcile to the source system's control totals, compare old and new versions of the same rows, and log each issue (`issues_log.md`).
5. **Fix and roll forward:** apply the treatments in views, confirm the control totals tie, confirm the June cells are reproduced unchanged, add the new diagonal.
6. **Actual vs expected (A vs E):** expected Jul–Dec 2025 paid from the June factors vs actual paid in the cleaned data.

## Results

**Chain-ladder at 2025-06-30** (tail 1.000)

| AY | age (months) | paid to date | CDF | ultimate | reserve |
|---|---|---|---|---|---|
| 2023 | 30 | 450,333 | 1.000 | 450,333 | 0 |
| 2024 | 18 | 918,967 | 1.167 | 1,072,425 | 153,458 |
| 2025 | 6 | 203,937 | 6.607 | 1,347,341 | 1,143,405 |
| **Total** | | **1,573,237** | | **2,870,099** | **1,296,863** |

AY 2025 is 88% of the reserve, and it rests on a single 6→12 factor (3.46). Using a 1.02 tail instead raises the total reserve by about 57,000.

**Data issues in the 2025-12-31 extract** (full log: `issues_log.md`, or `issues_log.xlsx` with the control reconciliation before and after treatment)

| Issue | Size | Effect if not fixed |
|---|---|---|
| October payments loaded twice with new ids | 20 rows, 64,073 | Jul–Dec paid overstated |
| December payment dates in MM/DD/YYYY | 20 rows, 79,060 | payments silently drop out of the triangle |
| Historical payment restated (digits swapped) | 1 row, +6,300 | every AY 2024 cell moves |
| Claim moved to a policy that started after the loss | 1 claim, 18,428 | TX/GA state results shift |

The first two nearly cancel: with neither fixed, the 2025 payment **count** ties to the control total exactly (+20 and −20) while the amount is still 15,000 off. Count checks alone would have passed.

After treatment, every control total ties (count and amount), and the cleaned December data reproduces all nine June triangle cells to the cent.

**Actual vs expected, July–December 2025**

| AY | ages | expected | actual | A − E | A / E |
|---|---|---|---|---|---|
| 2023 | 30 → 36 | 0 | 5,093 | +5,093 | n/a |
| 2024 | 18 → 24 | 108,374 | 100,108 | −8,266 | 0.92 |
| 2025 | 6 → 12 | 502,087 | 262,643 | −239,444 | 0.52 |

## What the results mean
- **AY 2025:** the June chain-ladder ultimate of 1.35M is very likely too high. The 6→12 factor came from AY 2023 and 2024, when the second half of the year had at least as many policies in force as the first. In AY 2025 no new policies were written, so July–December had only the run-off of the 695 policies written in late 2024. 
- **AY 2024:** 8,000 short on 108,000 expected. The development pattern is roughly holding; the 153,000 reserve looks reasonable, perhaps slightly high.
- **AY 2023:** 5,093 was paid after age 30, the 1.000 tail expected 0, but the amount is small (about 1% of paid) enough to be consistent with the 1.02 tail sensitivity.

## Limitations
- Each age-to-age factor comes from one or two accident years, so the selected factors are not reliable; in practice they would be judged against industry or prior-year patterns.
- Paid data only (no case reserves or reported counts), so no incurred triangle or claim-count checks.
- Tail factor chosen, not estimated.
- Synthetic data: useful for the method, not for any conclusion about real auto business.

## How to run
Requires SQLite 3.35 or later (uses `ln` and `exp`). I used DBeaver; any SQLite client works. Run the scripts in order on an empty database:

| Script | What it does |
|---|---|
| `sql/00_load_2025-06-30.sql` | loads the June extract as raw tables |
| `sql/01_load_2025-12-31.sql` | loads the December extract and control totals |
| `sql/02_june_reserving.sql` | cleaning views, paid triangle, chain-ladder projection |
| `sql/03_dec_profile_reconcile.sql` | profiling and reconciliation of the December extract |
| `sql/04_dec_clean_rollforward.sql` | treatments, roll-forward, triangle check, actual vs expected |

Command line: `sqlite3 reserving.db < sql/00_load_2025-06-30.sql` and so on for each file.
