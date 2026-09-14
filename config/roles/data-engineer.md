# Data Engineer (Mid to Senior)

<!-- This file is the hiring bar. The installed copy lives in
     ~/.config/voice-setup/roles/ and is never committed, so internal specifics
     (team names, real JD text, actual volumes) belong in that copy, not here. -->

## Our stack and domain — CONTEXT, NOT REQUIREMENTS
We run a supply-side ad platform: high-volume bid/impression/revenue event data,
publisher-facing reporting, and analytics that finance and partners rely on.
Day to day that means an OLAP layer (Druid, Trino) over object storage, Postgres
for operational data, OpenSearch for logs, Kubernetes, Prometheus, and Python
services with scheduled/orchestrated pipelines.

Read that as the SHAPE of the work, not a checklist. Someone who did the same
job on Snowflake + dbt + Dagster, or BigQuery + Beam, or Redshift + Spark +
Airflow, or Kafka + Flink + ClickHouse, is equally qualified. We hire for the
underlying capability and expect a competent engineer to pick up our specific
tools in a few weeks. Never require a product name.

## Must-haves (hard gate — any single one missing is a PASS)
Each is a capability. Any tool that demonstrably delivers it counts.
- 3+ years building AND operating production data pipelines other people
  depended on. Querying a warehouse, or building dashboards on someone else's
  pipeline, does not count.
- SQL as a working tool, not a listed one: the resume shows them building or
  transforming data with it, in any dialect. A described tuning problem is a
  strong signal but is NOT required here — ask about it on the call instead.
- Production code in a general-purpose language for data work — tested,
  deployed, running on a schedule. Python, Scala, Java, Go, Kotlin all count
  equally. Notebook-only or ad-hoc-script-only does not.
- Owned an orchestrated pipeline end to end, including the unglamorous half:
  failures, retries, backfills, late-arriving data, being the person paged when
  it broke. Any orchestrator, or a hand-rolled scheduler they can defend.
- Worked on some analytical or distributed engine where volume was actually a
  constraint — the work described has to be the kind that only exists at scale
  (partitioning, distributed joins, incremental processing, cost control), not
  a single-box job. Which engine does not matter, and a stated number is NOT
  required: most engineers never put one on a resume. Judge the work.

## Core signals (a strong candidate shows several of these)
- A stated scale anywhere — rows/day, TB, events/sec, cluster size. Genuinely
  valuable when present, and a strong differentiator. Its ABSENCE is a question
  for the phone screen, never a rejection.
- A SQL or data-modelling problem described concretely: window functions,
  incremental models, a query plan they had to reason about, a join that was
  wrong.
- Made a schema or data-modelling decision and can articulate the tradeoff
  (partitioning, sort/cluster keys, rollup vs raw, wide vs narrow, SCD).
- Reasoned about correctness: idempotency, exactly-once vs at-least-once,
  dedupe, reconciliation against a source of truth, data quality checks.
- Improved cost or latency with a number attached, and can say what the change
  actually was.
- Streaming or near-real-time work, with the operational reality (lag, replay,
  ordering, backpressure) rather than just the logo.
- Engineering hygiene applied to data: CI, tests on transformations, code
  review, infrastructure as code, staged environments.
- Debugged a pipeline producing plausible-but-wrong numbers, and found it.
- Owned a freshness or availability SLA a business actually ran on.
- Money-adjacent or billing-grade data, where being wrong has consequences.

## Nice to have (never a gate, never compensates for a missing must-have)
- Advertising, martech, or clickstream-scale event data.
- Druid, Trino, or dbt specifically — genuinely just nice, see the note above.
- Kubernetes, Terraform, cloud cost management.
- Comfort talking directly to the analysts and stakeholders consuming the data.

## Anti-signals (concrete red flags, not just absence of a signal)
- Scope claimed that outruns the tenure: a platform re-architecture, a
  multi-source migration, or a framework "built" by someone in their first two
  years out of school. Usually team work rewritten in the first person.
- Every bullet carrying a round percentage and none carrying a mechanism. A real
  optimisation names the cause (skewed join, missing index, driver collecting to
  one node), not the technique category ("using parallel processing").
- Title says Data Engineer but every bullet is Tableau, Power BI, Looker, or
  Excel reporting. The most common false positive: read the bullets, not the
  title.
- A wall of 25+ tools with no project attached to any of them.
- Bootcamp, course, or personal projects given the same visual weight as
  employment, or padding a thin work history.
- Certifications standing in for experience.
- ETL GUI tools only (Informatica, SSIS, Talend drag-and-drop) with no code.
- 3+ roles under 12 months each with no contract/agency explanation.
- Date ranges given as years only in a way that hides short stints.
- Total years inflated by counting unrelated roles.
- ML coursework or model training offered as pipeline engineering.

## Score dimensions
- Pipeline ownership and operational depth (3)
- Engineering environment: did they work somewhere with real consequences —
  traffic, uptime pressure, on-call, money-grade data, a system they lived with
  for years — versus short client rotations with no ownership tail (2)
- SQL and data modelling substance (2)
- Software engineering quality: code, tests, deployment (2)
- Scale and systems reasoning (1)

Score the ENVIRONMENT, never the employer's brand or the candidate's school. A
recognisable logo is not rigour, and a no-name product company with real traffic
beats a famous one where they rotated off after six weeks.

## Job description
<Paste the real JD here in your ~/.config copy, or delete this section. The
rubric above is what drives the screen; the JD is context, not the bar.>
