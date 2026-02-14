# Chat Commands

## chat send <message>

Send a message to the AI assistant.

**Arguments:**
- `message` - The message text to send

**Examples:**
```bash
ziggystarspider chat send "Hello!"
ziggystarspider chat send "What's the status of the project?"
```

**Interactive mode:**
```
ZiggyStarSpider> send Hello!
ZiggyStarSpider> send What's next?
```

## chat history

Show recent chat history for the current session.

**Examples:**
```bash
ziggystarspider chat history
ziggystarspider chat history --limit 20
```

**Notes:**
- History is maintained for the current chat session
- Use `/new` in interactive mode to start a fresh chat (saves current to memory)
