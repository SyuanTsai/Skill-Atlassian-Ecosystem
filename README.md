# Skill-Atlassian-Management

Independent Agent Skills repository for Atlassian work-management workflows.

Stable source ID: `atlassian-work-management`

## Included skills

| Skill | Purpose |
| --- | --- |
| `work-with-jira` | Safely route and perform Jira Cloud issue operations through an approved connector or REST access path. |
| `configure-jira-api-access` | Guide secure Jira Cloud API configuration and read-only validation when REST access is required. |
| `publish-requirements-to-confluence` | Structure analyzed requirements and publish them to a confirmed Confluence destination. |

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
    work-with-jira/
      SKILL.md
      agents/openai.yaml
catalog/
  source.json
tests/
  validate-repository.ps1
.github/
  workflows/
    validate.yml
```

## Dependency behavior

`work-with-jira` treats `configure-jira-api-access` as a conditional fallback, not a hard dependency. Connector-only Jira workflows remain valid and must not force API-token setup when an approved Jira connector already satisfies the request.

## Source metadata

`catalog/source.json` identifies this repository as the stable source `atlassian-work-management` and enumerates the skills owned by this repository. Consumers may pin this repository by tag or commit SHA independently of other skill repositories.

## Validation

Run the repository validation from the repository root:

```powershell
pwsh -NoProfile -File ./tests/validate-repository.ps1
```

The validation checks that:

- the stable source metadata is present and valid;
- exactly the expected three Atlassian skills are declared;
- every declared skill directory exists;
- every skill contains `SKILL.md` and `agents/openai.yaml`;
- skill front matter declares the matching stable skill ID;
- required reference files are present for skills that depend on them;
- `work-with-jira` retains the Jira connector/API fallback contract.

The same validation runs in GitHub Actions on pushes and pull requests.
