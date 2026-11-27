# Story: Renew a loan online

## User Story

As a member I want to renew a loan online so that I avoid an overdue fine

## Business Value

Members renew by phone today; online renewal cuts call volume and overdue fines.

## Acceptance Criteria

### Scenario: Renewal succeeds

Given a loan with no holds against it
When I renew it
Then the due date moves out by two weeks

### Scenario: Renewal blocked by a hold

Given another member has a hold on the book
When I try to renew it
Then I am told the book is on hold

## Definition of Done

- [ ] Code implemented and peer reviewed
- [ ] Tests written and passing
- [ ] Documentation updated

## Effort Estimate

2 story points
