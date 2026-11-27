# Story: Allow members to update their contact email

## User Story

As a member
I want to update my contact email address
So that the library can reach me about holds and overdue loans

## Business Value

Stale email addresses cause missed hold and overdue notices; self-service updates keep contact details current.

## Acceptance Criteria

### Scenario: Member updates a valid email address

Given I am signed in to my account
When I save a valid email address
Then my contact email is updated

### Scenario: Member enters an invalid email address

Given I am signed in to my account
When I save an invalid email address
Then a validation message is shown and nothing is saved

### Scenario: Member clears their email address

Given I have an email address on file
When I clear the field and save
Then my contact email is removed

## Definition of Done

- [ ] Code implemented and peer reviewed
- [ ] Unit tests written and passing
- [ ] Documentation updated

## Effort Estimate

2 story points
