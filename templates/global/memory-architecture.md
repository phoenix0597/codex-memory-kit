# Memory Architecture

This file defines the preferred cross-project memory architecture for agent collaboration.

## Summary

Use a layered memory model:

1. Global cross-project memory in `{{GLOBAL_MEMORY_DIR}}/`
2. Repo-local bootstrap and durable memory in the project root
3. Repo-local chronological and thematic working memory in `memory/`

## Global Layer

Use the global memory directory only for information that should apply across projects.

- `{{GLOBAL_MEMORY_DIR}}/global-collaboration-rules.md` - cross-project collaboration rules
- `{{GLOBAL_MEMORY_DIR}}/memory-architecture.md` - shared memory structure and naming convention
- `{{HOME_DIR}}/AGENTS.md` - optional global startup index for all work under the home directory

Do not store project-specific architecture or implementation history here.

## Project Layer

Preferred project-local convention:

- `AGENTS.md` - repo-local startup order and memory protocol
- `START-HERE.md` - bootstrap index
- `assistant-memory.md` - durable project architecture decisions and process agreements
- `memory/current-work-queue.md` - current decomposed implementation queue and preferred next steps
- `memory/YYYY-MM-DD.md` - daily chronological notes
- `memory/topic-<slug>.md` - recurring topics, rationale, and evolving thematic notes

## Rules

- Keep one source of truth per information type.
- Use global files only for cross-project durable rules.
- Use `assistant-memory.md` for durable project rules and architecture, not daily logs.
- Use `memory/current-work-queue.md` for the live decomposed implementation queue, not for durable architecture rules.
- Use daily files for short chronological notes.
- Use topic files for recurring themes, deeper rationale, or evolving design discussions.
- Prefer linking between layers instead of copying large text blocks.
- Keep names and structure consistent across projects so a new session can navigate any repository predictably.

## Scaffolding

To bootstrap the project memory files in a new repository, use the memory kit's `init-project.sh`.
