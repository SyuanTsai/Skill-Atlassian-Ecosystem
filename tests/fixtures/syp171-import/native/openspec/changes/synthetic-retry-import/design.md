## Context

The fixture mentions exponential backoff and cancellation tokens as a technical idea. This is a design candidate rather than an approved retry-count expectation. Source: BLOCK-dc5b40139a2c731e4417, page 101 version 3.

The unresolved retry-count behavior and operator command remain in [the retained source reference](../../../references/retry-source.md).

## Decision candidate

Consider cancellation-aware exponential backoff if a later approved retry-count behavior needs it. No implementation decision is made for the unresolved maximum or failure result.
