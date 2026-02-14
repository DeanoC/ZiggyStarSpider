# Project Commands

Projects are the top-level organization for work in Spiderweb.

## project list

List all projects.

**Examples:**
```bash
ziggystarspider project list
```

**Output:**
```
Projects:
  spiderweb   | Active | AI gateway development
  mygame      | Active | Game project
  website     | Paused | Personal website
```

## project use <name>

Switch to a different project.

**Arguments:**
- `name` - Project name

**Examples:**
```bash
ziggystarspider project use spiderweb
ziggystarspider project use mygame
```

## project create <name>

Create a new project.

**Arguments:**
- `name` - Project name (unique)

**Options:**
- `--description <text>` - Project description

**Examples:**
```bash
ziggystarspider project create mynewproject --description "A new project"
```

## project info

Show information about the current project.

**Examples:**
```bash
ziggystarspider project info
```

**Output:**
```
Project: spiderweb
Status: Active
Description: AI gateway development
Goals: 3 (2 open, 1 completed)
Active Tasks: 2
```
