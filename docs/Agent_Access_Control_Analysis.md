# Architecture Analysis: Agent Access Control & Memory Isolation

This document analyzes the design trade-offs of Localmem's memory isolation strategy, comparing the current manual denylist approach with visual-only folders, automatic directory-based routing, and removing access controls entirely.

---

## Executive Summary

Localmem's current V1 implementation relies on manual, per-memory agent exclusions. While secure, this pattern does not scale: developers will not manually configure agent permissions as their memory database grows. 

To resolve this, we are evaluating three architectural paths to simplify the UX while maintaining Localmem's core value proposition of privacy and security.

---

## Comparison Matrix

| Capability / Dimension | Current System (Manual Denylist) | Option A (Visual-only Spaces) | Option B (Directory-Based Routing) | Option C (No Access Control) |
| :--- | :--- | :--- | :--- | :--- |
| **User Configuration Overhead** | 🔴 High (per-memory/agent) | 🟢 None | 🟢 None (Implicit via CWD) | 🟢 None |
| **Work vs. Personal Isolation** | 🟡 Partial (if configured) | 🔴 None | 🟢 High (Automatic) | 🔴 None |
| **Context Pollution Protection** | 🟡 Low (manual only) | 🔴 None | 🟢 High (Projects isolated) | 🔴 None |
| **Security/Leakage Protection** | 🟢 High (Strict denylist) | 🔴 None | 🟢 High (Scope-based) | 🔴 None |
| **Product Differentiation (USP)** | 🟢 High | 🔴 Low (Generic DB wrapper) | 👑 Highest (Smart isolation) | 🔴 Low (Generic DB wrapper) |
| **Implementation Complexity** | Medium | Low | Medium-High | Low (Deletes code) |

---

## Architectural Deep Dive

### Current System: Manual Agent Denylists
*   **How it works**: Every memory has an optional list of `excludedAgents`. The database checks these exclusions during search/recent calls.
*   **The Problem**: Developers must manually check boxes in the GUI to hide specific memories from specific agents. Over months of use, this friction guarantees the feature goes unused.

---

### Option A: Spaces as Pure Visual Folders
*   **How it works**: Memories are grouped into "Spaces" (`Work`, `Personal`, etc.) solely for organization in the SwiftUI app sidebar. Agents have full access to search and read all memories globally.
*   **Pros**:
    *   Simple to build and maintain.
    *   Clean UX for reviewing memories in the app.
*   **Cons**:
    *   Zero privacy isolation. If you use a corporate Claude Code instance at work, a search query can pull your personal health, finance, or side-project memories.
    *   Context pollution: A coding assistant in a React repo gets search results containing unrelated Python design choices.

---

### Option B: Spaces with Directory-Based Routing (CWD)
*   **How it works**: Spaces serve as isolation boundaries. When an agent calls the MCP server, `localmem-mcp` detects the current working directory (`cwd`) of the shell/editor process.
    1.  It maps the directory path against directory rules (e.g., `/Users/dev/work/*` $\rightarrow$ `Work` Space, `/Users/dev/personal/*` $\rightarrow$ `Personal` Space).
    2.  It filters the search/recent queries to *only* return memories belonging to that resolved Space (plus untagged general memories).
*   **Pros**:
    *   **Zero-Touch Privacy**: Work agents never see personal memories, and vice-versa, without the user ever managing manual lists.
    *   **Strong Relevance**: Filters out noise from unrelated projects, preventing context pollution.
    *   **Strong USP**: Solves the core privacy/security problem of local-first LLM memory tools.
*   **Cons**:
    *   Requires mapping directories to Spaces (can be automated on first run by asking the user to confirm).

---

### Option C: Drop Access Control Entirely
*   **How it works**: We delete `memory_agent_exclusions` table, clean up agent identities from the storage engine, and remove access-control logic from the CLI and MCP server. The vault is single-tenant, flat, and open.
*   **Pros**:
    *   Massively simplifies the codebase.
    *   Focuses purely on search speed, imports, and GUI organization.
*   **Cons**:
    *   **No differentiation**: Localmem behaves like a basic local SQLite wrapper.
    *   **Security risks**: Any rogue open-source agent you run locally has full read access to your entire lifelong memory vault.

---

## Recommendation

> [!TIP]
> **Option B (Directory-Based Routing)** provides the strongest balance of **security** and **frictionless UX**. 
> By routing context automatically via the developer's workspace path, we retain the privacy guarantees of a secure local vault while eliminating the manual configuration overhead that ruins traditional access-control systems.
