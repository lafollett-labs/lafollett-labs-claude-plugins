# Story: Notify librarians when a loan is overdue

## User Story

As a librarian
I want a notification when a loan passes its due date
So that I can follow up before the next member is kept waiting

## Business Value

Overdue loans currently slip unnoticed; proactive alerts shorten hold queues measurably.

## Acceptance Criteria

### Scenario: Overdue loan raises an alert

Given a loan past its due date
When I POST /api/notifications
Then the librarian receives an overdue alert

### Scenario: On-time loan raises no alert

Given a loan within its due date
When the scheduler runs
Then no alert is sent

## Definition of Done

- [ ] Code implemented and peer reviewed
- [ ] Tests written and passing
- [ ] Documentation updated
