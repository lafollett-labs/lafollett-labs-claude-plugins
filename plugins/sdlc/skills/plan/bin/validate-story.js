#!/usr/bin/env node
/**
 * BDD Story Validator
 *
 * Validates user story markdown files for:
 * - Proper user story format (As a... I want... So that...)
 * - Gherkin scenario structure (Given-When-Then)
 * - Required sections
 * - Common anti-patterns
 *
 * Usage:
 *   node validate-story.js --file story.md
 *
 * Line endings are normalised on read, so a CRLF story (an issue body edited on GitHub) validates
 * like its LF twin.
 *
 * Exit codes:
 *   0 — passed, with or without ⚠ warnings
 *   1 — failed a ✗ check, file not found, or --file missing
 */

const fs = require('fs');
const path = require('path');

// Parse CLI arguments
function parseArgs() {
    const args = process.argv.slice(2);
    const options = {};

    for (let i = 0; i < args.length; i++) {
        if (args[i].startsWith('--')) {
            const key = args[i].substring(2);
            const value = args[i + 1];
            options[key] = value;
            i++;
        }
    }

    if (!options.file) {
        console.error('Error: --file is required');
        console.log('\nUsage: node validate-story.js --file story.md');
        process.exit(1);
    }

    return options;
}

// Validation checks
const checks = {
    hasTitle: (content) => {
        const match = content.match(/^# .*$/m);
        return {
            pass: !!match,
            message: match ? `✓ Title found: ${match[0]}` : '✗ Missing story title (# Story Title)'
        };
    },

    hasUserStory: (content) => {
        const hasSection = /## User Story/i.test(content);
        const hasFormat = /As a .+\nI want .+\nSo that .+/i.test(content);

        if (!hasSection) {
            return { pass: false, message: '✗ Missing "## User Story" section' };
        }
        if (!hasFormat) {
            return { pass: false, message: '✗ User story not in "As a... I want... So that..." format' };
        }
        return { pass: true, message: '✓ User story format correct' };
    },

    hasBusinessValue: (content) => {
        const match = content.match(/## Business Value\s+(.+)/i);
        if (!match) {
            return { pass: false, message: '✗ Missing "## Business Value" section' };
        }
        const value = match[1].trim();
        if (value.length < 20) {
            return { pass: false, message: '✗ Business value too short (should be 1-2 meaningful sentences)' };
        }
        return { pass: true, message: '✓ Business value provided' };
    },

    hasAcceptanceCriteria: (content) => {
        const hasSection = /## Acceptance Criteria/i.test(content);
        if (!hasSection) {
            return { pass: false, message: '✗ Missing "## Acceptance Criteria" section' };
        }
        return { pass: true, message: '✓ Acceptance criteria section present' };
    },

    hasGherkinScenarios: (content) => {
        const scenarioCount = (content.match(/### Scenario:/g) || []).length;

        if (scenarioCount === 0) {
            return { pass: false, message: '✗ No Gherkin scenarios found (use ### Scenario:)' };
        }
        if (scenarioCount < 2) {
            return { pass: false, message: `✗ Only ${scenarioCount} scenario found (recommend at least 2: happy path + error case)` };
        }
        return { pass: true, message: `✓ ${scenarioCount} Gherkin scenarios found` };
    },

    hasGivenWhenThen: (content) => {
        const scenarios = content.split(/### Scenario:/);
        const errors = [];
        let validScenarios = 0;

        scenarios.slice(1).forEach((scenario, index) => {
            const hasGiven = /\bGiven\b/i.test(scenario);
            const hasWhen = /\bWhen\b/i.test(scenario);
            const hasThen = /\bThen\b/i.test(scenario);

            if (!hasGiven) errors.push(`Scenario ${index + 1}: Missing "Given"`);
            if (!hasWhen) errors.push(`Scenario ${index + 1}: Missing "When"`);
            if (!hasThen) errors.push(`Scenario ${index + 1}: Missing "Then"`);

            if (hasGiven && hasWhen && hasThen) validScenarios++;
        });

        if (errors.length > 0) {
            return { pass: false, message: `✗ Incomplete Gherkin scenarios:\n    ${errors.join('\n    ')}` };
        }
        return { pass: true, message: `✓ All ${validScenarios} scenarios have Given-When-Then` };
    },

    hasDefinitionOfDone: (content) => {
        const hasSection = /## Definition of Done/i.test(content);
        if (!hasSection) {
            return { pass: false, message: '✗ Missing "## Definition of Done" section' };
        }

        const checkboxCount = (content.match(/- \[ \]/g) || []).length;
        if (checkboxCount < 3) {
            return { pass: false, message: `✗ Definition of Done has only ${checkboxCount} items (recommend at least 3)` };
        }
        return { pass: true, message: `✓ Definition of Done with ${checkboxCount} items` };
    },

    noImplementationDetails: (content) => {
        const antiPatterns = [
            { pattern: /\b(POST|GET|PUT|DELETE|PATCH)\s+\/api\//i, name: 'HTTP method in scenario' },
            { pattern: /\bSELECT\s+.*\s+FROM\s+/i, name: 'SQL query in scenario' },
            { pattern: /\b(database|table|column)\b.*\bshould\s+(have|contain)/i, name: 'Database reference in Then' },
            { pattern: /\b(click|button|element|CSS|XPath)\s+["'].+["']/i, name: 'UI implementation detail' }
        ];

        const found = [];
        antiPatterns.forEach(({ pattern, name }) => {
            if (pattern.test(content)) {
                found.push(name);
            }
        });

        if (found.length > 0) {
            return { pass: false, message: `⚠ Warning: Implementation details found:\n    ${found.join('\n    ')}` };
        }
        return { pass: true, message: '✓ No obvious implementation details in scenarios' };
    },

    hasEffortEstimate: (content) => {
        const hasSection = /## Effort Estimate/i.test(content);
        if (!hasSection) {
            return { pass: false, message: '⚠ Warning: Missing "## Effort Estimate" section' };
        }
        return { pass: true, message: '✓ Effort estimate provided' };
    }
};

// Main validation
function validateStory(filePath) {
    console.log('='.repeat(60));
    console.log('BDD Story Validator');
    console.log('='.repeat(60));
    console.log(`File: ${filePath}\n`);

    if (!fs.existsSync(filePath)) {
        console.error(`✗ File not found: ${filePath}`);
        process.exit(1);
    }

    const content = fs.readFileSync(filePath, 'utf-8').replace(/\r\n?/g, '\n');

    let passCount = 0;
    let failCount = 0;
    let warnCount = 0;

    console.log('Running validation checks...\n');

    // Run all checks
    Object.entries(checks).forEach(([checkName, checkFn]) => {
        const result = checkFn(content);
        console.log(result.message);

        if (result.pass) {
            passCount++;
        } else if (result.message.startsWith('⚠')) {
            warnCount++;
        } else {
            failCount++;
        }
    });

    // Summary
    console.log('\n' + '='.repeat(60));
    console.log('Summary');
    console.log('='.repeat(60));
    console.log(`✓ Passed: ${passCount}`);
    console.log(`✗ Failed: ${failCount}`);
    console.log(`⚠ Warnings: ${warnCount}`);

    if (failCount === 0 && warnCount === 0) {
        console.log('\n🎉 Story validation passed! Ready to publish.');
        process.exit(0);
    } else if (failCount === 0) {
        console.log('\n⚠ Story validation passed with warnings. Review before publishing.');
        process.exit(0);
    } else {
        console.log('\n✗ Story validation failed. Fix errors before publishing.');
        process.exit(1);
    }
}

// Run
const options = parseArgs();
validateStory(path.resolve(options.file));
