# Story: Add book search to the catalogue

## User Story

As a member
I want to search books by title and author
So that I can place a hold without browsing long shelf lists

## Business Value

Members currently browse long shelf lists by hand; search cuts the time to a first hold and reduces abandoned visits.

## Acceptance Criteria

### Scenario: Search returns matching books

Given the catalogue has books on the shelf
When I search for a book by title
Then the matching books are listed

### Scenario: No book matches the query

Given no book matches the search text
When I search for an unknown title
Then an empty-state message is shown

## Definition of Done

- [ ] Code implemented and peer reviewed
- [ ] Tests written and passing
- [ ] Documentation updated

## Effort Estimate

3 story points
