# Story: Book Search

## User Story

As a member
I want to search books by title
So that I can quickly find something to borrow

## Acceptance Criteria

### Scenario: Search returns matching books

Given a book titled "The Lighthouse" is in the catalogue
When I search for "Lighthouse"
Then the results include "The Lighthouse"

### Scenario: Search with no matches shows empty state

Given no book matches the query
When I search for "zzzz"
Then an empty-state message is shown

## Definition of Done

- [ ] Code reviewed
- [ ] Tests pass
- [ ] Deployed to staging
