# Chat Commands

## chat send <message>

Send a message to the AI assistant.

**Arguments:**
- `message` - The message text to send

**Flags:**
- `--no-thoughts` - Suppress live thought progress lines while waiting
- `--quiet-progress` - Suppress live state/thought progress lines while waiting

**Examples:**
```bash
spider chat send "Hello!"
spider chat send "What's the status of the project?"
spider chat send --no-thoughts "Summarize the latest changes"
```

**Interactive mode:**
```
SpiderApp> send Hello!
SpiderApp> send What's next?
```

## chat history

Show recent chat history for the current session.

**Examples:**
```bash
spider chat history
spider chat history --limit 20
```

**Notes:**
- History is maintained for the current chat session
- Use `/new` in interactive mode to start a fresh chat (saves current to memory)

## chat resume [job_id]

Inspect queued/running/done chat jobs and resume by job id.

**Flags:**
- `--no-thoughts` - Suppress thought progress while waiting on a running job
- `--quiet-progress` - Suppress live state/thought progress while waiting

**Examples:**
```bash
spider chat resume
spider chat resume job-12
spider chat resume --quiet-progress job-12
```
