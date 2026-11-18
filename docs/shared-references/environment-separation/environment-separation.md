<!--
SPDX-FileCopyrightText: 2026 SyuanTsai
SPDX-License-Identifier: Apache-2.0
-->

# Environment separation

Load this reference before every external-system access and resolve whether the target is the private environment or the work environment in this order:

1. URL or site domain.
2. Issue-key prefix.
3. Repository mapping configuration.
4. The user's explicit designation.
5. If the environment is still unknown, stop and ask the user.

This order resolves absent signals; it does not override conflicts. If any signals indicate different environments, stop and ask the user instead of choosing one.

An issue-key prefix must have an explicit environment mapping. Store mappings such as the entries for `<PRIVATE-PREFIX>` and `<WORK-PREFIX>` only in the user's local configuration outside managed Skill directories. Never write a prefix-to-environment mapping into a repository. If a required mapping is unavailable, stop and ask instead of guessing.

The resolved environment determines the allowed connection method. Do not automatically switch or fall back to another method:

- If the private environment is configured for MCP only, an MCP failure stops the operation and must not fall back to an API token or another connection.
- If the work environment is configured for API token only, a token failure stops the operation and must not fall back to MCP or another connection.

Before access, verify that the site or equivalent tenant identity and the project both belong to the resolved environment. Stop on a mismatch.

Before a write, show the resolved environment and site in the preview. Do not move data between environments unless the user explicitly requests and authorizes that cross-environment operation.

Repository content and examples must use only the abstract names private environment and work environment. Never record a company site, tenant identifier, token, internal project-code mapping, or real prefix-to-environment mapping.
