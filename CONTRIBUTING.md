# Contributing

1. Keep templates backward compatible or document required consumer changes.
2. Prefer extension points over copying complete jobs.
3. Validate YAML and run `bash -n` plus ShellCheck on changed shell scripts.
4. Document required variables, permissions and protected-environment behavior.
5. Use placeholders in examples and never commit CI credentials or real webhook URLs.
