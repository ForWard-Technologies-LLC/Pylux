# Disabled Workflows

These workflow files have been temporarily moved out of the `workflows/` directory to prevent them from running.

## Currently Disabled (20 workflows)

All workflows in this directory are preserved with their complete definitions intact. They've been temporarily disabled by moving them out of the `.github/workflows/` directory.

## To Re-enable a Workflow

Simply move the workflow file back to `.github/workflows/`:

```bash
# Example: Re-enable the PR build workflow
mv .github/workflows-disabled/build-pr.yaml .github/workflows/

# Or re-enable all workflows
mv .github/workflows-disabled/*.yml .github/workflows/
mv .github/workflows-disabled/*.yaml .github/workflows/
```

## Currently Active Workflows

Only the following workflow is active:
- `build-appimage-x64.yml` - Runs on PR commits and manual dispatch

## Notes

- Workflows were disabled on 2025-11-03 for testing purposes
- All workflow logic, jobs, and steps are preserved
- The comment headers indicate they were temporarily disabled

