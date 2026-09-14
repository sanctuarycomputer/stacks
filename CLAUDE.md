# Stacks

## Worktrees

When creating a new git worktree, always copy the gitignored `config/master.key` from the main checkout into the worktree's `config/` directory. Rails cannot decrypt credentials without it, so the app (and test suite) won't boot:

```bash
cp <main-checkout>/config/master.key <worktree>/config/master.key
```
