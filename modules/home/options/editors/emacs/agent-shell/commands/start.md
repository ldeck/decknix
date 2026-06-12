---
description: Create a new session and rename it, optionally from a Jira ticket key
argument-hint: [session name or JIRA-KEY]
---

Create a new Augment session and rename it in one step.

**Instructions:**

1. **Parse the argument:** The user provides `$ARGUMENTS` which can be:
   - A **Jira ticket key** (e.g., `ALR-4268`, `ARC-10308`) — detected by matching the pattern `[A-Z]+-\d+`
   - A **plain session name** (e.g., "proptrack pubsub fix")
   - **Empty** — prompt the user for a name

2. **If a Jira ticket key is detected:**
   - Fetch the ticket summary from Jira using the Jira API tool: `GET /issue/{key}` with fields `summary,status,assignee,parent`
   - If the ticket has a parent, also fetch the parent summary
   - Construct the session name as: `{KEY}: {parent summary or ticket summary}`
   - Display the ticket details briefly:
     ```
     📋 {KEY}: {summary}
     📌 Status: {status} | Assignee: {assignee or "Unassigned"}
     🏷️ Session: {constructed name}
     ```

3. **Inform the user** that `/new` and `/rename` are built-in commands that cannot be invoked programmatically from within a session. Instead, provide the exact commands to run:

   ```
   To start this session, run these commands:

   /new
   /rename {session name}
   ```

   If the session name contains special characters, wrap it in quotes.

4. **Offer to set up context** for the new session:
   - Ask if they'd like a brief summary of the current session to carry forward
   - If yes, generate a 3-5 bullet summary of key decisions, findings, and next steps from the current conversation
