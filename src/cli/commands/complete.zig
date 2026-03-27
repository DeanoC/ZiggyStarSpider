// complete.zig — Shell completion script generation.
// Usage: spider complete bash|zsh|fish

const std = @import("std");
const args = @import("../args.zig");

pub fn executeComplete(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    _ = options;
    const stdout = std.fs.File.stdout().deprecatedWriter();

    const shell = if (cmd.args.len > 0) cmd.args[0] else {
        try stdout.writeAll("Usage: spider complete <bash|zsh|fish>\n");
        return;
    };

    if (std.mem.eql(u8, shell, "bash")) {
        try stdout.writeAll(bash_completion);
    } else if (std.mem.eql(u8, shell, "zsh")) {
        try stdout.writeAll(zsh_completion);
    } else if (std.mem.eql(u8, shell, "fish")) {
        try stdout.writeAll(fish_completion);
    } else {
        try stdout.print("Unknown shell '{s}'. Supported: bash, zsh, fish\n", .{shell});
        try stdout.writeAll("Install instructions:\n");
        try stdout.writeAll("  bash: spider complete bash >> ~/.bashrc\n");
        try stdout.writeAll("  zsh:  spider complete zsh  >> ~/.zshrc\n");
        try stdout.writeAll("  fish: spider complete fish > ~/.config/fish/completions/spider.fish\n");
    }

    _ = allocator;
}

// ── Bash completion ──────────────────────────────────────────────────────────

const bash_completion =
    \\# Spider bash completion
    \\# Add to ~/.bashrc:  spider complete bash >> ~/.bashrc
    \\# Or source directly: source <(spider complete bash)
    \\
    \\_spider_completions() {
    \\  local cur prev words
    \\  cur="${COMP_WORDS[COMP_CWORD]}"
    \\  prev="${COMP_WORDS[COMP_CWORD-1]}"
    \\  words=("${COMP_WORDS[@]}")
    \\
    \\  # Top-level nouns
    \\  local nouns="chat fs agent session node workspace auth connect disconnect status help complete"
    \\
    \\  if [[ ${COMP_CWORD} -eq 1 ]]; then
    \\    COMPREPLY=( $(compgen -W "${nouns}" -- "${cur}") )
    \\    return
    \\  fi
    \\
    \\  local noun="${words[1]}"
    \\
    \\  # Global flags always available
    \\  local global_flags="--url --workspace --token --operator-token --role --verbose --json --help --version --interactive"
    \\
    \\  if [[ ${COMP_CWORD} -eq 2 ]]; then
    \\    case "${noun}" in
    \\      chat)       COMPREPLY=( $(compgen -W "send history resume ${global_flags}" -- "${cur}") ) ;;
    \\      fs)         COMPREPLY=( $(compgen -W "ls read write stat tree ${global_flags}" -- "${cur}") ) ;;
    \\      agent)      COMPREPLY=( $(compgen -W "list info ${global_flags}" -- "${cur}") ) ;;
    \\      session)    COMPREPLY=( $(compgen -W "list status attach resume close history restore ${global_flags}" -- "${cur}") ) ;;
    \\      node)       COMPREPLY=( $(compgen -W "list info pending approve deny join-request service-get service-upsert service-runtime watch ${global_flags}" -- "${cur}") ) ;;
    \\      workspace)  COMPREPLY=( $(compgen -W "list use create up doctor info status template bind mount handoff ${global_flags}" -- "${cur}") ) ;;
    \\      auth)       COMPREPLY=( $(compgen -W "status rotate ${global_flags}" -- "${cur}") ) ;;
    \\      complete)   COMPREPLY=( $(compgen -W "bash zsh fish" -- "${cur}") ) ;;
    \\      *)          COMPREPLY=( $(compgen -W "${global_flags}" -- "${cur}") ) ;;
    \\    esac
    \\    return
    \\  fi
    \\
    \\  local verb="${words[2]}"
    \\
    \\  # Workspace sub-verbs
    \\  if [[ "${noun}" == "workspace" ]]; then
    \\    case "${verb}" in
    \\      up)       COMPREPLY=( $(compgen -W "--interactive --template --mount --bind --no-activate --workspace-id ${global_flags}" -- "${cur}") ) ;;
    \\      bind)     COMPREPLY=( $(compgen -W "add remove list" -- "${cur}") ) ;;
    \\      mount)    COMPREPLY=( $(compgen -W "add remove list" -- "${cur}") ) ;;
    \\      template) COMPREPLY=( $(compgen -W "list info" -- "${cur}") ) ;;
    \\      *)        COMPREPLY=( $(compgen -W "${global_flags}" -- "${cur}") ) ;;
    \\    esac
    \\    return
    \\  fi
    \\
    \\  # Node service sub-verbs
    \\  if [[ "${noun}" == "node" ]]; then
    \\    case "${verb}" in
    \\      service-get|service-upsert|service-runtime) COMPREPLY=( $(compgen -W "--node-id ${global_flags}" -- "${cur}") ) ;;
    \\      *)  COMPREPLY=( $(compgen -W "${global_flags}" -- "${cur}") ) ;;
    \\    esac
    \\    return
    \\  fi
    \\
    \\  COMPREPLY=( $(compgen -W "${global_flags}" -- "${cur}") )
    \\}
    \\
    \\complete -F _spider_completions spider
    \\
;

// ── Zsh completion ───────────────────────────────────────────────────────────

const zsh_completion =
    \\#compdef spider
    \\# Spider zsh completion
    \\# Add to ~/.zshrc: spider complete zsh >> ~/.zshrc
    \\# Or add to fpath: spider complete zsh > "${fpath[1]}/_spider"
    \\
    \\_spider() {
    \\  local state
    \\
    \\  _arguments \
    \\    '(--url)--url[Server URL]:url:' \
    \\    '(-w --workspace)'{-w,--workspace}'[Workspace ID]:workspace:' \
    \\    '--token[Auth token]:token:' \
    \\    '--operator-token[Operator token]:token:' \
    \\    '--role[Role]:role:(admin user)' \
    \\    '(-v --verbose)'{-v,--verbose}'[Verbose output]' \
    \\    '--json[JSON output]' \
    \\    '(-i --interactive)'{-i,--interactive}'[Interactive mode]' \
    \\    '(-h --help)'{-h,--help}'[Show help]' \
    \\    '--version[Show version]' \
    \\    '1: :_spider_nouns' \
    \\    '*:: :->args'
    \\
    \\  case $state in
    \\    args)
    \\      case $words[1] in
    \\        chat)       _arguments '1: :(send history resume)' ;;
    \\        fs)         _arguments '1: :(ls read write stat tree)' ;;
    \\        agent)      _arguments '1: :(list info)' ;;
    \\        session)    _arguments '1: :(list status attach resume close history restore)' ;;
    \\        node)       _arguments '1: :(list info pending approve deny join-request service-get service-upsert service-runtime watch)' ;;
    \\        workspace)  _spider_workspace ;;
    \\        auth)       _arguments '1: :(status rotate)' ;;
    \\        complete)   _arguments '1: :(bash zsh fish)' ;;
    \\      esac
    \\      ;;
    \\  esac
    \\}
    \\
    \\_spider_nouns() {
    \\  local nouns
    \\  nouns=(
    \\    'chat:Send and receive chat messages'
    \\    'fs:Filesystem operations'
    \\    'agent:Agent management'
    \\    'session:Session management'
    \\    'node:Node management'
    \\    'workspace:Workspace management'
    \\    'auth:Authentication'
    \\    'connect:Connect to server'
    \\    'disconnect:Disconnect from server'
    \\    'status:Show connection status'
    \\    'complete:Generate shell completions'
    \\    'help:Show help'
    \\  )
    \\  _describe 'command' nouns
    \\}
    \\
    \\_spider_workspace() {
    \\  local verbs
    \\  verbs=(
    \\    'list:List workspaces'
    \\    'use:Select a workspace'
    \\    'create:Create a workspace'
    \\    'up:Create or update a workspace'
    \\    'doctor:Check workspace health'
    \\    'info:Show workspace info'
    \\    'status:Show workspace status'
    \\    'template:Manage workspace templates'
    \\    'bind:Manage workspace binds'
    \\    'mount:Manage workspace mounts'
    \\    'handoff:Workspace handoff'
    \\  )
    \\  _describe 'workspace verb' verbs
    \\}
    \\
    \\_spider "$@"
    \\
;

// ── Fish completion ──────────────────────────────────────────────────────────

const fish_completion =
    \\# Spider fish completion
    \\# Install: spider complete fish > ~/.config/fish/completions/spider.fish
    \\
    \\# Disable file completion for spider
    \\complete -c spider -f
    \\
    \\# Global flags
    \\complete -c spider -l url           -d 'Server URL' -r
    \\complete -c spider -l workspace     -d 'Workspace ID' -r
    \\complete -c spider -l token         -d 'Auth token' -r
    \\complete -c spider -l operator-token -d 'Operator token' -r
    \\complete -c spider -l role          -d 'Role (admin|user)' -r -a 'admin user'
    \\complete -c spider -l verbose       -d 'Verbose output'
    \\complete -c spider -l json          -d 'JSON output'
    \\complete -c spider -l interactive   -d 'Interactive mode'
    \\complete -c spider -l help          -d 'Show help'
    \\complete -c spider -l version       -d 'Show version'
    \\
    \\# Top-level subcommands
    \\complete -c spider -n '__fish_use_subcommand' -a chat       -d 'Send and receive chat messages'
    \\complete -c spider -n '__fish_use_subcommand' -a fs         -d 'Filesystem operations'
    \\complete -c spider -n '__fish_use_subcommand' -a agent      -d 'Agent management'
    \\complete -c spider -n '__fish_use_subcommand' -a session    -d 'Session management'
    \\complete -c spider -n '__fish_use_subcommand' -a node       -d 'Node management'
    \\complete -c spider -n '__fish_use_subcommand' -a workspace  -d 'Workspace management'
    \\complete -c spider -n '__fish_use_subcommand' -a auth       -d 'Authentication'
    \\complete -c spider -n '__fish_use_subcommand' -a connect    -d 'Connect to server'
    \\complete -c spider -n '__fish_use_subcommand' -a disconnect -d 'Disconnect from server'
    \\complete -c spider -n '__fish_use_subcommand' -a status     -d 'Show connection status'
    \\complete -c spider -n '__fish_use_subcommand' -a complete   -d 'Generate shell completions'
    \\complete -c spider -n '__fish_use_subcommand' -a help       -d 'Show help'
    \\
    \\# chat verbs
    \\complete -c spider -n '__fish_seen_subcommand_from chat' -a send    -d 'Send a message'
    \\complete -c spider -n '__fish_seen_subcommand_from chat' -a history -d 'Show chat history'
    \\complete -c spider -n '__fish_seen_subcommand_from chat' -a resume  -d 'Resume a job'
    \\
    \\# fs verbs
    \\complete -c spider -n '__fish_seen_subcommand_from fs' -a ls    -d 'List directory'
    \\complete -c spider -n '__fish_seen_subcommand_from fs' -a read  -d 'Read a file'
    \\complete -c spider -n '__fish_seen_subcommand_from fs' -a write -d 'Write a file'
    \\complete -c spider -n '__fish_seen_subcommand_from fs' -a stat  -d 'Stat a path'
    \\complete -c spider -n '__fish_seen_subcommand_from fs' -a tree  -d 'Print directory tree'
    \\
    \\# agent verbs
    \\complete -c spider -n '__fish_seen_subcommand_from agent' -a list -d 'List agents'
    \\complete -c spider -n '__fish_seen_subcommand_from agent' -a info -d 'Show agent info'
    \\
    \\# session verbs
    \\complete -c spider -n '__fish_seen_subcommand_from session' -a list    -d 'List sessions'
    \\complete -c spider -n '__fish_seen_subcommand_from session' -a status  -d 'Show session status'
    \\complete -c spider -n '__fish_seen_subcommand_from session' -a attach  -d 'Attach to session'
    \\complete -c spider -n '__fish_seen_subcommand_from session' -a resume  -d 'Resume session'
    \\complete -c spider -n '__fish_seen_subcommand_from session' -a close   -d 'Close session'
    \\complete -c spider -n '__fish_seen_subcommand_from session' -a history -d 'Session history'
    \\complete -c spider -n '__fish_seen_subcommand_from session' -a restore -d 'Restore session'
    \\
    \\# node verbs
    \\complete -c spider -n '__fish_seen_subcommand_from node' -a list             -d 'List nodes'
    \\complete -c spider -n '__fish_seen_subcommand_from node' -a info             -d 'Node info'
    \\complete -c spider -n '__fish_seen_subcommand_from node' -a pending          -d 'List pending join requests'
    \\complete -c spider -n '__fish_seen_subcommand_from node' -a approve          -d 'Approve join request'
    \\complete -c spider -n '__fish_seen_subcommand_from node' -a deny             -d 'Deny join request'
    \\complete -c spider -n '__fish_seen_subcommand_from node' -a join-request     -d 'Show join request'
    \\complete -c spider -n '__fish_seen_subcommand_from node' -a service-get      -d 'Get node service'
    \\complete -c spider -n '__fish_seen_subcommand_from node' -a service-upsert   -d 'Upsert node service'
    \\complete -c spider -n '__fish_seen_subcommand_from node' -a service-runtime  -d 'Node service runtime'
    \\complete -c spider -n '__fish_seen_subcommand_from node' -a watch            -d 'Watch node events'
    \\
    \\# workspace verbs
    \\complete -c spider -n '__fish_seen_subcommand_from workspace' -a list     -d 'List workspaces'
    \\complete -c spider -n '__fish_seen_subcommand_from workspace' -a use      -d 'Select workspace'
    \\complete -c spider -n '__fish_seen_subcommand_from workspace' -a create   -d 'Create workspace'
    \\complete -c spider -n '__fish_seen_subcommand_from workspace' -a up       -d 'Create/update workspace'
    \\complete -c spider -n '__fish_seen_subcommand_from workspace' -a doctor   -d 'Check workspace health'
    \\complete -c spider -n '__fish_seen_subcommand_from workspace' -a info     -d 'Workspace info'
    \\complete -c spider -n '__fish_seen_subcommand_from workspace' -a status   -d 'Workspace status'
    \\complete -c spider -n '__fish_seen_subcommand_from workspace' -a template -d 'Manage templates'
    \\complete -c spider -n '__fish_seen_subcommand_from workspace' -a bind     -d 'Manage binds'
    \\complete -c spider -n '__fish_seen_subcommand_from workspace' -a mount    -d 'Manage mounts'
    \\complete -c spider -n '__fish_seen_subcommand_from workspace' -a handoff  -d 'Workspace handoff'
    \\
    \\# workspace up flags
    \\complete -c spider -n '__fish_seen_subcommand_from workspace; and __fish_seen_subcommand_from up' -l interactive -d 'Interactive wizard'
    \\complete -c spider -n '__fish_seen_subcommand_from workspace; and __fish_seen_subcommand_from up' -l template    -d 'Template ID' -r
    \\complete -c spider -n '__fish_seen_subcommand_from workspace; and __fish_seen_subcommand_from up' -l mount       -d 'Mount spec' -r
    \\complete -c spider -n '__fish_seen_subcommand_from workspace; and __fish_seen_subcommand_from up' -l bind        -d 'Bind spec' -r
    \\
    \\# auth verbs
    \\complete -c spider -n '__fish_seen_subcommand_from auth' -a status -d 'Auth status'
    \\complete -c spider -n '__fish_seen_subcommand_from auth' -a rotate -d 'Rotate token'
    \\
    \\# complete shells
    \\complete -c spider -n '__fish_seen_subcommand_from complete' -a bash -d 'Bash completion script'
    \\complete -c spider -n '__fish_seen_subcommand_from complete' -a zsh  -d 'Zsh completion script'
    \\complete -c spider -n '__fish_seen_subcommand_from complete' -a fish -d 'Fish completion script'
    \\
;
