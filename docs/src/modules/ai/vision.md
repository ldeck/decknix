# Vision: The Future of AI Tooling in Decknix

The current agent shell is Layer 5 of a broader vision. Here's where it's heading.

## Literate Session Export (Next)

> *Issue: [decknix#55](https://github.com/ldeck/decknix/issues/55)*

Every AI session becomes publishable knowledge:

```
C-c E o    → Export to Org-mode
C-c E m    → Export to Markdown
C-c E h    → Export to HTML
C-c E c    → Export to Confluence (ADF)
```

**Why this matters:** An investigation session becomes a post-mortem. An architecture discussion becomes a design doc. A bug hunt becomes a runbook. The AI conversation *is* the documentation — export makes it shareable.

## Role-Based Workflow Profiles

The agent shell currently serves a single persona: the developer writing code. But AI-assisted workflows extend far beyond coding.

### Engineering Workflows

| Workflow | What the Agent Does |
|----------|-------------------|
| **Investigation** | Query logs (GCP MCP), search knowledge base, correlate errors, produce root cause analysis |
| **Architecture Review** | Analyse codebase structure, identify coupling, suggest decomposition, generate ADRs |
| **Incident Response** | Real-time log tailing, alert correlation, runbook execution, post-mortem drafting |
| **Code Review** | Automated review on commit, PR summary generation, review thread resolution |
| **Onboarding** | Guided codebase exploration, convention explanation, first-task scaffolding |

### Transformative Engineering

Beyond individual developer productivity, the tooling enables **transformative engineering** — systematic, AI-assisted modernisation of large codebases:

| Capability | Description |
|-----------|-------------|
| **Migration planning** | Analyse a legacy codebase, identify migration paths, estimate effort, generate step-by-step plans |
| **Pattern extraction** | Detect repeated patterns across services, propose shared libraries, generate extraction PRs |
| **Observability gap analysis** | Compare metric/alert coverage against error hierarchies, identify blind spots |
| **Test coverage expansion** | Analyse untested paths, generate test scaffolds, prioritise by risk |
| **Cross-service coherence** | Validate that API contracts, event schemas, and alert definitions stay consistent across services |

### Beyond Engineering

The same session-as-first-class-object model applies to non-engineering roles:

| Role | Workflow |
|------|----------|
| **Product** | Spec refinement sessions, user story generation, acceptance criteria drafting |
| **QA** | Test plan generation, exploratory testing guidance, regression analysis |
| **Support** | Ticket investigation with knowledge base search, escalation drafting |
| **Leadership** | Sprint retrospective analysis, technical debt quantification, roadmap impact assessment |

## Workflow Templates

Future slash commands and templates will be **role-aware**:

```
/investigate <property-id>     → Full NC property sync investigation
/incident <alert-name>         → Incident response runbook
/review-pr <PR-number>         → Structured code review
/onboard <repo-name>           → Guided codebase tour
/migrate <from> <to>           → Migration planning session
```

These would combine MCP server access, knowledge base search, and structured output into repeatable workflows.

## Multi-Agent Orchestration

The session manager and attention tracker already support multiple concurrent sessions. The next step is **coordinated multi-agent workflows**:

- **Parallel investigation** — spawn multiple agents to investigate different aspects of an incident simultaneously
- **Review pipeline** — one agent reviews code, another checks test coverage, a third validates observability
- **Continuous monitoring** — background agents that watch CI, alert channels, or deployment status and inject findings into active sessions

## Declarative Workflow Definitions

Workflows as Nix configuration:

```nix
{ ... }: {
  decknix.ai.workflows = {
    investigate = {
      description = "Full property sync investigation";
      mcpServers = [ "gcp-monitoring" "org-knowledge-base" ];
      template = "investigate";
      context.autoPin = [ "jira" ];  # Auto-pin Jira tickets mentioned
    };
    incident = {
      description = "Incident response runbook";
      mcpServers = [ "gcp-monitoring" "pagerduty" ];
      template = "incident";
      attention.priority = "high";  # Always show in attention tracker
    };
  };
}
```

## The Endgame

The vision is an environment where:

1. **Every AI conversation produces artefacts** — not just code changes, but documentation, decisions, and knowledge
2. **Workflows are reproducible** — a new team member gets the same investigation tools, templates, and MCP access as a senior engineer
3. **Context is continuous** — switching between sessions preserves the full picture of what you're working on
4. **The tooling adapts to the role** — engineers, product managers, and support staff each get workflows tailored to their needs
5. **The environment is declarative** — `decknix switch` reproduces the entire AI-assisted workflow on any machine

