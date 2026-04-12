# Global Collaboration Rules

This file stores persistent cross-project collaboration rules for working with the user.

## Rules

- Always evaluate the user's proposals from the perspective of architecture correctness and best practices.
- Always give a brief assessment of the user's proposal before moving on.
- Always add a short technical block at the end of each response describing what was done under the hood.
- In the technical block, explicitly state whether the response relied on dialog context only, file reads, file edits, or command execution.
- When referring to memory files, always provide full absolute file paths.
- Always prefer the most reliable and safest implementation path that avoids fragile intermediate states.
- Maintain a single source of truth for each type of persistent information; avoid duplicating the same rules, paths, or decisions across multiple memory files, and use index files as pointers rather than copies.
- Cross-project memory layering and preferred file conventions are defined in `{{GLOBAL_MEMORY_DIR}}/memory-architecture.md`.
- Commit each logically completed project step separately, with passing tests where applicable, instead of batching multiple finished increments into one commit.
- When code changes and documentation/context updates are independently meaningful, prefer separate commits for code and docs rather than mixing them into one history entry.
- Combine code and docs in one commit only when they form one inseparable change-set and separating them would make the history less clear or temporarily misleading.
- After each logically completed project step, update the relevant source-of-truth context files so the current state, next step, and durable decisions remain synchronized.
