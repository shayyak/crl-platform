# ADR-0001: Record architecture decisions

- Status: accepted
- Date: 2026-10-11

## Context

The project compares several distribution designs (S3 plus sidecar, S3 plus caching
proxy, improved IIS/DFS). Choices must be justifiable and revisitable.

## Decision

Every significant choice gets a short ADR in `docs/adr/`, written from
`0000-template.md`. A decision is only "accepted" with evidence attached
(measurement, test result or cited source).

## Consequences

Slightly more writing up front; far less guessing later.
