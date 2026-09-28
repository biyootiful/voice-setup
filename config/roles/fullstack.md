# Fullstack Engineer, backend-leaning (Mid to Senior)

<!-- This file is the hiring bar. The installed copy lives in
     ~/.config/voice-setup/roles/ and is never committed, so internal specifics
     (team names, real JD text, actual traffic numbers) belong in that copy. -->

## Our stack and domain — CONTEXT, NOT REQUIREMENTS
We run a supply-side ad platform: publisher-facing dashboards and internal
tooling over ad-serving and revenue data, with real traffic behind them. Day to
day that means a component-based frontend, HTTP/JSON services, Postgres,
analytical queries against an OLAP layer, Kubernetes, and Prometheus-based
observability.

**Weighting: we are hiring a strong general software engineer whose centre of
gravity is the backend.** The title says fullstack and the job does involve UI,
but backend substance and engineering fundamentals are what we screen on. UI
work is the most learnable part of this role and is increasingly AI-assisted, so
thin frontend evidence is a question, not a rejection. A strong systems thinker
who has shipped some React is a better hire here than a frontend specialist who
cannot design a schema. Do not reject a strong backend engineer for a resume
light on frontend detail.

Read that as the SHAPE of the work, not a checklist. React vs Vue vs Svelte vs
Angular is not a hiring signal — someone who has real depth in any one of them
will be productive in ours inside a month. The same goes for the backend:
Node, Python, Go, Ruby, Java, C#, PHP, whichever. What does not transfer for
free is judgement about state, data modelling, API design, and living with your
own code in production. Screen for that. Never require a product name.

## Must-haves (hard gate — any single one missing is a PASS)
Each is a capability. Any stack that demonstrably delivers it counts.
- 3+ years shipping AND maintaining a web application real users used.
  "Maintaining" is the operative word: someone who has never lived with their
  own code in production has not done this job.
- Has shipped user-facing UI in some component-based framework in a professional
  setting, at any depth. This is a LOW bar and deliberately so: a few screens, a
  dashboard, an internal tool all clear it. Do NOT require a state or
  component-architecture decision — that is a scoring signal and a phone-screen
  question, not a gate. Which framework is irrelevant. Only a candidate with no
  UI work anywhere fails this.
- Substantial backend work, and this is the one that carries the screen:
  designed and shipped HTTP APIs, wrote the data access layer, made schema
  decisions, and understands query cost. Any language. This should be the
  majority of what the resume describes. Frontend-only candidates calling
  themselves fullstack are a PASS for this role — that is about scope, not
  tooling, and it is the one direction the weighting does not bend.
- Owned at least one feature or service end to end — schema through API through
  deploy through the bug reports afterwards. A UI leg strengthens this but is
  not required; owning a backend service in production satisfies it.
- Testing and code review as normal practice. Zero mention of tests anywhere
  across a 5+ year resume is a real concern; "what they test and why" is a
  phone-screen question, not a gate, since almost nobody writes that down.

## Core signals (a strong candidate shows several of these)
- A specific thing they test and why, or a specific state/component decision
  and its tradeoff. Strong when present; its absence is a question for the
  call, never a rejection.
- Performance or reliability work with a number attached and the actual cause
  named (N+1 query, bundle size, missing index, cache strategy).
- Concrete grasp of auth and session security: tokens, cookies, CSRF,
  authorization boundaries, why the naive version is wrong.
- Shipped a schema migration or refactor against live traffic without downtime.
- Background jobs, queues, or scheduled work — and their failure modes.
- Observability habits: logs, metrics, tracing, alerting used to find a real bug.
- Debugged a production incident and can describe the diagnosis, not just the fix.
- Mentoring, code review culture, or technical decisions made across a team.
- Built data-heavy UI: tables, filters, charts over large result sets, and dealt
  with the query cost behind them.
- Pushed back on a design or worked directly with product.

## Nice to have (never a gate, never compensates for a missing must-have)
- TypeScript throughout, not just in the config.
- Our specific stack — genuinely just nice, see the note above.
- Cloud, CI/CD, Kubernetes, infrastructure as code.
- High-traffic consumer-facing systems, ad serving, or experimentation and A/B
  testing infrastructure.
- Comfort with SQL beyond the ORM.

## Anti-signals (concrete red flags, not just absence of a signal)
- Scope claimed that outruns the tenure: "architected the platform" or "led the
  migration" from someone in their first two years out of school. Usually team
  work rewritten in the first person.
- Every bullet carrying a round percentage and none carrying a mechanism. A real
  optimisation names the cause (N+1 query, missing index, bundle size), not the
  technique category ("using caching").
- Portfolio of tutorial clones (todo app, Twitter clone, e-commerce demo) as the
  primary or only evidence of ability.
- "Fullstack" that turns out to mean WordPress, Wix, Shopify theming, or no-code
  tools only.
- Every bullet is a framework name and no bullet is a problem solved.
- Backend work that is all framework glue: controllers and CRUD endpoints with
  no schema decision, no query cost, no failure handling anywhere. This is the
  gap that matters here, far more than a thin frontend section.
- A 30-tool skills matrix behind 2 years of experience — breadth claimed at a
  depth the timeline cannot support.
- Agency history where every project ran 2 to 6 weeks and nothing was maintained.
- No production incident, deployment, or on-call reality anywhere on the resume.
- 3+ roles under 12 months each with no contract/agency explanation.
- Buzzword AI or blockchain projects with no engineering substance underneath.

Note what is NOT on this list: an older or unfashionable stack. Someone who
spent six years on a PHP or Rails or .NET monolith and can describe hard
problems they solved there is a strong candidate, not a stale one. Judge the
problems, not the vintage of the tools.

## Score dimensions
- Backend and data-layer substance: API design, schema decisions, query cost,
  the data model they chose and why (3)
- Engineering fundamentals: concurrency, caching, failure modes, algorithmic and
  systems judgement, and the ability to debug something they did not write. This
  is what "strong SWE" means here and it outranks any framework familiarity (2)
- End-to-end ownership and production maturity (2)
- Engineering environment: did they work somewhere with real consequences —
  traffic, uptime pressure, on-call, a product they lived with for years —
  versus short client rotations with no ownership tail (2)
- Frontend competence: enough to be productive on UI, not depth. Score 1 for
  anyone who has shipped real screens. Reserve a 0 for someone who has never
  touched UI at all (1)

Fundamentals are rarely written down, so score them from what the work required
rather than from a claim, and probe them on the call. Never dock a candidate for
frontend thinness while backend evidence is strong — that inverts this spec.

Score the ENVIRONMENT, never the employer's brand or the candidate's school. A
recognisable logo is not rigour, and a no-name product company with real traffic
beats a famous one where they rotated off after six weeks.

## Job description
<Paste the real JD here in your ~/.config copy, or delete this section. The
rubric above is what drives the screen; the JD is context, not the bar.>
