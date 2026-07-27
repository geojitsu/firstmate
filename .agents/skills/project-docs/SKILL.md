---
name: project-docs
description: >-
  Fleet-wide documentation standards for crewmates.
  Covers docstring requirements for every public function and Nuxt Docus format for feature and API documentation.
  Loaded automatically via the ship brief when a task has a public-surface change.
icon: 'i-heroicons-document-text'
user-invocable: false
metadata:
  internal: true
---

# project-docs

Load this when your task adds or modifies a public function, class, module, integration point, or feature, or changes an existing public API signature or behavior.
It defines two documentation requirements: docstrings on every touched public symbol, and Nuxt Docus pages for feature-level changes.

## Requirement A: Docstrings on every public symbol

Add or update a language-appropriate docstring when you create or modify any public function, method, class, or module.

**TypeScript / JavaScript:** JSDoc format with `@param`, `@returns`, and `@throws` tags where applicable.

```typescript
/**
 * Computes the Levenshtein distance between two strings.
 * @param a - First input string.
 * @param b - Second input string.
 * @returns The edit distance as a non-negative integer.
 */
function levenshtein(a: string, b: string): number { ... }
```

**Python:** Google-style docstrings with Args, Returns, and Raises sections.

```python
def connect(host: str, port: int) -> Connection:
    """Open a TCP connection to host:port.

    Args:
        host: Hostname or IP address to connect to.
        port: TCP port number.

    Returns:
        An active Connection object.

    Raises:
        ConnectionError: If the connection attempt fails.
    """
```

**Swift:** DocC format using `///` summary line plus `- Parameters:`, `- Returns:`, and `- Throws:` items.

```swift
/// Encodes the payload as a Base64 string.
/// - Parameters:
///   - data: Raw bytes to encode.
/// - Returns: A Base64-encoded string representation.
/// - Throws: `EncodingError` if the data contains invalid bytes.
func encode(_ data: Data) throws -> String { ... }
```

**Go:** Go doc comments using `// FunctionName does ...` immediately above the declaration.

```go
// ParseConfig reads a TOML file at path and returns a Config.
// It returns an error if the file cannot be read or parsed.
func ParseConfig(path string) (*Config, error) { ... }
```

**Rust:** Rustdoc line comments using `///` with `# Examples`, `# Errors`, and `# Panics` sections where applicable.

```rust
/// Splits `input` at the first occurrence of `delimiter`.
///
/// # Examples
/// ```
/// assert_eq!(split_once("a:b", ':'), Some(("a", "b")));
/// ```
///
/// # Returns
/// Returns `None` if `delimiter` is not found in `input`.
pub fn split_once(input: &str, delimiter: char) -> Option<(&str, &str)> { ... }
```

**Other languages:** use the idiomatic doc-comment style for that language.

**Trigger:** any new or modified public function, method, class, or module.
**Skip:** private and internal helpers, test helpers, and generated code.

## Requirement B: Technical documentation in Nuxt Docus format

When the task adds a new feature, new public API, new integration point, or architectural change, create or update documentation files in `/docs` at the project root using Nuxt Docus format.

**Before writing a single doc:** read `doc-routing.json` in this skill directory.
The `directories` array defines the canonical `docs/` structure and which folders sync to the public docs site vs. remain internal.
The `rules` array maps your change to the correct target path — match against it and write to every path that matches, in the same change.

### Docus file format

Every `.md` file in `/docs` must begin with YAML frontmatter:

```markdown
---
title: Page Title
description: One-sentence description shown in navigation and meta.
icon: 'i-heroicons-bolt'
tags: ['tag-one', 'tag-two']
---
```

Each subdirectory must include a `_dir.yml` with `title` and `icon` to control sidebar display:

```yaml
title: Section Name
icon: i-heroicons-cpu-chip
```

The body uses standard Markdown plus MDC (Markdown Components) syntax for Vue components.

```markdown
::callout
A tip or note for readers.
::

::callout{type="warning"}
A warning callout.
::

::code-group
```bash [npm]
npm install package-name
```
```bash [yarn]
yarn add package-name
```
::

::tabs
  ::tab{label="Option A"}
  Content for option A.
  ::
  ::tab{label="Option B"}
  Content for option B.
  ::
::
```

### Naming convention

Files and directories must be numerically prefixed and kebab-cased: `N.kebab-name`.
The number controls Docus sidebar order.

### Four-section template for every doc page

Name the file using the numeric prefix pattern (e.g. `3.feature-name.md`).

```markdown
---
title: Feature Name
description: One sentence.
---

## Overview

What this is and why it exists.
Two to four sentences, no more.

## Usage

How to use it.
Include concrete code examples.

::code-group
```typescript [Example]
// code here
```
::

## API Reference

Public functions, classes, options, and their signatures.
One subsection per exported symbol.

### `functionName(param: Type): ReturnType`

What it does.

**Parameters:**
- `param` - description.

**Returns:** description.

## Notes

Edge cases, known limitations, migration guidance, or anything that would surprise a reader.
Omit this section if there is nothing worth noting.
```

### Central Docus server

The docs feed via git clone; the crewmate's only obligation is to maintain correct Docus-format files in `/docs`.
No special push or publish step is needed.
