---
name: grill-with-docs
description: A relentless interview to sharpen a research plan, design or question, recording each resolved outcome in the project's research records (research/decisions/ and the Protocol) as it happens.
disable-model-invocation: true
---

Invoke the `grilling` and `domain-modeling` skills before starting the interview, then run the interview by their rules.

Project-local rules override the upstream document destinations:

- Record each important research decision in `research/decisions/` as soon as it is resolved, using the `record-decision` skill.
- Record scientific semantics in the relevant `Protocol`, normally `research/PROTOCOL.md`.
- Do not create `GLOSSARY.md`, `docs/adr/`, or any other parallel ADR or status system unless the user explicitly asks for that upstream artifact.
