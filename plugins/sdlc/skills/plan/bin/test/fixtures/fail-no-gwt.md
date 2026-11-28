# Story: Export the loan history to CSV

## User Story

As a librarian
I want to export the loan history to CSV
So that I can share it with the branch coordinator

## Business Value

Coordinators ask for loan histories over email; a one-click export removes a recurring manual copy-paste chore.

## Acceptance Criteria

### Scenario: Export produces a CSV file

Given the catalogue has loans on record
When I click export
Then a CSV file downloads

### Scenario: Empty history export

Given there are no loans on record
When I click export
(this scenario deliberately omits its outcome line, so the check must fail)

## Definition of Done

- [ ] Code implemented and peer reviewed
- [ ] Tests written and passing
- [ ] Documentation updated

## Effort Estimate

2 story points
