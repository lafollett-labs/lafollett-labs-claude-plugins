# Story: Mixed Dialect

## Acceptance Criteria

### Scenario: Scenario title wins over bullets

Given a section with both a scenario and a bullet
When the renderer extracts items
Then only the scenario is harvested

- [ ] This bullet must be ignored while a scenario is present
