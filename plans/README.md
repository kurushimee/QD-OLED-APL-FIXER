# implementation plans

plans for feature and tool work on the project, the shaders, DwmBoost, measurement scripts and the calibration data, so any task can be picked back up at any point and checked against what's already done

## layout

the folder is the status

| folder | meaning |
|---|---|
| `backlog/` | accepted plans, work not started |
| `in_progress/` | being worked on right now |
| `finished/` | done, kept as an archive with the finish date in the frontmatter |

## plan file

named `NNN_<slug>.md`, where `NNN` is a running three-digit number that never gets reused. it starts with this frontmatter

```markdown
---
id: 001
title: short name
status: backlog | in_progress | finished
created: YYYY-MM-DD
updated: YYYY-MM-DD
finished: YYYY-MM-DD   (finished plans only)
---
```

tasks are `- [ ]` / `- [x]` checkboxes grouped into phases, each phase with its done criterion. a facts section keeps the research behind the plan, measurements, panel behavior and decisions with why, so any session can pick it up without redoing it

## workflow

1. before new work, check `in_progress/` and `backlog/` for a plan that overlaps
2. when work starts, move the file to `in_progress/` and update `status` and `updated`
3. while working, tick the checkboxes and update `updated`
4. when it's done, move the file to `finished/`, set `finished` and update `status`
