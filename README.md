# Skill Atlassian Ecosystem

Independent Agent Skills repository for Jira, Confluence, and Bitbucket Cloud workflows that share an Atlassian integration and credential boundary.

Stable source ID: `atlassian-ecosystem`

## Included skills

| Skill | Purpose |
| --- | --- |
| `work-with-jira` | Safely route and perform Jira Cloud issue operations through an approved connector or REST access path. |
| `configure-jira-api-access` | Guide secure Jira Cloud API configuration and read-only validation when REST access is required. |
| `publish-requirements-to-confluence` | Structure analyzed requirements and publish them to a confirmed Confluence destination. |
| `review-bitbucket-pull-request` | Review Bitbucket Cloud PRs from verified local Git diffs and optionally publish explicitly authorized feedback. |

## Repository layout

```text
.agents/
  skills/
    configure-jira-api-access/
      SKILL.md
      agents/openai.yaml
      references/
    publish-requirements-to-confluence/
      SKILL.md
      agents/openai.yaml
      references/
    review-bitbucket-pull-request/
      SKILL.md
      agents/openai.yaml
      references/bitbucket-cloud-api.md
    work-with-jira/
      SKILL.md
      agents/openai.yaml
catalog/
  source.json
tests/
  validate-repository.ps1
```

## Integration and credential boundaries

`work-with-jira` treats `configure-jira-api-access` as a conditional fallback, not a hard dependency. Connector-only Jira workflows remain valid and must not force API-token setup when an approved Jira connector already satisfies the request.

The Repository owns Atlassian product workflows together, but credentials remain separately scoped. Jira, Confluence, and Bitbucket tokens or keys must be read only from approved environment variables or secret stores, validated without disclosure, and used only for the product and operation authorized by the user. `review-bitbucket-pull-request` additionally requires an approved Git credential path for the complete local diff.

## Source metadata

`catalog/source.json` identifies this repository as the stable source `atlassian-ecosystem` and enumerates the skills owned by this repository. Consumers may pin this repository by tag or commit SHA independently of other Skill repositories.

## Validation

Run the repository validation from the repository root:

```powershell
pwsh -NoProfile -File ./tests/validate-repository.ps1
```

The validation checks that:

- the stable source metadata is present and valid;
- exactly the expected four Atlassian ecosystem Skills are declared;
- every declared skill directory exists;
- every skill contains `SKILL.md` and `agents/openai.yaml`;
- skill front matter declares the matching stable skill ID;
- required reference files are present for skills that depend on them;
- `work-with-jira` retains the Jira connector/API fallback contract.
- `review-bitbucket-pull-request` retains its local Git evidence and explicit comment-authorization boundaries.

The validation script is intentionally self-contained so CI or release automation can invoke the same command without depending on another repository.
