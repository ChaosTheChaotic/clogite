# Clogite
A command history viewer built in zig inspired by atuin (but without storing it in some server somewhere and using zstd for compression)

It records commands that would be parsed identically by the shell (e.g double spaces etc) and stores data about multiple commands of the same instance (e.g how many times has the command failed)

As of now it sadly only supports zsh since I cant figure out how to get bash to work and I dont know much about other shells. For zsh you just add `eval $(clogite init)` to your zshrc and source it for it to appear on up arrow.

## Keybinds
- ctrl+c or escape to quit when on the history page or go back to the history page when on the info page
- ctrl+d to delete a command
- ctrl+o to view more info about a command
- enter to run the command
- tab to place the command into the next shell prompt (for editing)
- Prepend \c to use case sensitive search
- Prepend \f to use plain text search
- \c used before \f if both
