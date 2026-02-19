# ZiggyStarSpider TUI Help

The Terminal User Interface (TUI) provides an interactive way to communicate with ZiggyStarSpider.

## Navigation & Controls

- **Enter**: Send the current message in the input field.
- **Tab**: Cycle focus between different UI elements (if applicable).
- **Esc**: Go back to previous screen or clear input.
- **Ctrl+D**: Disconnect from the current server.
- **Ctrl+C**: Quit the application immediately.
- **F1** or **?**: Show this help screen.

## Screens

### Connection Screen
The initial screen where you specify the Spiderweb server URL.
- Use the input field to enter the WebSocket URL.
- Press **Enter** to initiate the connection.

### Chat Screen
The main interface for interacting with the AI.
- Messages from you are shown in **green**.
- Messages from the AI are shown in **cyan**.
- Type your message at the bottom and press **Enter** to send.

## Configuration

The TUI uses the same configuration as the CLI, typically loaded from `~/.config/zss/config.json`.
You can override the connection URL using the `--url` command-line flag when starting the TUI.
